import contextlib
import io
import pathlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / 'lib'))
import colima


class ColimaSafety(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = pathlib.Path(self.directory.name) / '.colima' / 'builder'
        self.root.mkdir(parents=True)
        self.socket = self.root / 'docker.sock'
        self.report = {'fingerprint': 'a' * 64, 'images': 1, 'stopped': 1, 'build_cache': 0,
                       'estimated_kib': 4096, 'volumes': ['database'], 'active_ids': ['running']}
        self.profile = {'builder': {'name': 'builder', 'status': 'Stopped'}}

    def test_usage_comes_from_daemon_summary_and_never_counts_volumes(self):
        df = {'Images': [{'Id': 'live', 'Size': 16384, 'SharedSize': 4096},
                         {'Id': 'build', 'Size': 8192, 'SharedSize': 2048}],
              'Containers': [{'Id': 'running', 'ImageID': 'live', 'State': 'running', 'SizeRw': 1024},
                             {'Id': 'finished', 'ImageID': 'build', 'State': 'exited', 'SizeRw': 2048}],
              'Volumes': [{'Name': 'database', 'UsageData': {'Size': 10**9}}],
              'BuildCache': [{'ID': 'busy', 'Size': 10**9, 'InUse': True, 'Shared': False}]}
        with patch.object(colima, 'api', side_effect=[df, {'ID': 'daemon'}]):
            report = colima.snapshot(self.socket)
        self.assertEqual((report['images'], report['stopped'], report['build_cache']), (1, 1, 0))
        self.assertEqual(report['estimated_kib'], 8)
        self.assertEqual(report['volumes'], ['database'])

    def test_default_scan_never_starts_stopped_vm(self):
        with patch.object(colima, 'profiles', return_value=self.profile), \
             patch.object(colima, 'profile_root', return_value=self.root), \
             patch.object(colima, 'allocated_kib', return_value=17 * 1048576), \
             patch.object(colima.subprocess, 'run') as command, contextlib.redirect_stdout(io.StringIO()) as output:
            colima.plan([], False)
        command.assert_not_called()
        self.assertIn('17.00 GiB on Mac; inspect to estimate', output.getvalue())
        self.assertIn('\t0\t', output.getvalue())
        self.assertIn('\tskip\n', output.getvalue())

    def test_prune_uses_profile_socket_keeps_volumes_and_restores_stopped_state(self):
        with patch.object(colima, 'profiles', return_value=self.profile), \
             patch.object(colima, 'daemon_socket', return_value=self.socket), \
             patch.object(colima, 'allocated_kib', return_value=17 * 1048576), \
             patch.object(colima, 'snapshot', side_effect=[self.report, self.report]), \
             patch.object(colima.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)) as command, \
             contextlib.redirect_stdout(io.StringIO()) as output:
            result = colima.prune('builder', {'status': 'Stopped', 'fingerprint': self.report['fingerprint']})
        self.assertEqual(result, 0)
        commands = [call.args[0] for call in command.call_args_list]
        self.assertEqual(commands[0], ['colima', 'start', 'builder', '--activate=false', '--save-config=false'])
        self.assertEqual(commands[1], ['docker', '--host', f'unix://{self.socket}', 'system', 'prune', '--all', '--force'])
        self.assertEqual(commands[-1], ['colima', 'stop', 'builder'])
        self.assertIn('no reduction in Mac disk allocation measured', output.getvalue())

    def test_changed_inventory_does_not_prune(self):
        with patch.object(colima, 'profiles', return_value=self.profile), \
             patch.object(colima, 'daemon_socket', return_value=self.socket), \
             patch.object(colima, 'allocated_kib', return_value=0), \
             patch.object(colima, 'snapshot', return_value=self.report), \
             patch.object(colima.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)) as command, \
             contextlib.redirect_stderr(io.StringIO()):
            result = colima.prune('builder', {'status': 'Stopped', 'fingerprint': 'b' * 64})
        self.assertEqual(result, 2)
        self.assertEqual([call.args[0][1] for call in command.call_args_list], ['start', 'stop'])

    def test_partial_start_failure_still_stops_owned_profile(self):
        failure = subprocess.CalledProcessError(1, ['colima', 'start', 'builder'])
        with patch.object(colima.subprocess, 'run', side_effect=[failure, subprocess.CompletedProcess([], 0)]) as command:
            with self.assertRaises(subprocess.CalledProcessError):
                with colima.running('builder', 'Stopped'):
                    self.fail('failed startup must not enter the Docker operation')
        self.assertEqual(command.call_args_list[-1].args[0], ['colima', 'stop', 'builder'])


if __name__ == '__main__':
    unittest.main()
