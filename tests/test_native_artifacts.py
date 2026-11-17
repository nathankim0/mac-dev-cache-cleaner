import contextlib
import io
import json
import os
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'lib'))
import extra_artifacts as extra
import inventory
import simulators


class NativeArtifacts(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = pathlib.Path(self.tmp.name).resolve()
        self.module = self.root / 'android/app'
        self.module.mkdir(parents=True)
        (self.root / 'package.json').write_text('{}')
        (self.root / 'android/settings.gradle').write_text('')
        (self.module / 'build.gradle').write_text('')

    def discover(self, released=False):
        stream = io.StringIO()
        with contextlib.redirect_stdout(stream):
            inventory.projects(self.root, 8, 7, released)
        return [line.split('\t') for line in stream.getvalue().splitlines()]

    def test_native_resources_are_caches_but_release_outputs_require_opt_in(self):
        cache = self.module / 'build/intermediates/res'
        cache.mkdir(parents=True)
        (cache / 'generated.png').write_bytes(b'generated resource')
        outputs = self.module / 'build/outputs'
        outputs.mkdir()
        (outputs / 'app.aab').write_bytes(b'release')
        native = self.module / '.cxx'
        native.mkdir()
        (native / 'object.o').write_bytes(b'cache')
        rows = {r[3]: r for r in self.discover()}
        self.assertEqual(rows[str(cache.parent)][0], 'native-cache')
        self.assertEqual(rows[str(native)][0], 'native-cache')
        self.assertEqual(rows[str(outputs)][1], 'release-review')
        self.assertEqual({r[3]: r for r in self.discover(True)}[str(outputs)][1], 'recent')

    def test_secrets_tracked_source_and_unmarked_lookalikes_survive(self):
        subprocess.run(['git', 'init', '-q', str(self.root)], check=True)
        source = self.module / 'build/generated'
        source.mkdir(parents=True)
        (source / 'source.txt').write_text('original')
        subprocess.run(['git', '-C', str(self.root), 'add', str(source)], check=True)
        keys = self.module / 'build/intermediates'
        keys.mkdir()
        (keys / 'upload.jks').write_text('private fixture')
        lookalike = self.root / 'unknown/build/intermediates'
        lookalike.mkdir(parents=True)
        self.assertIsNone(extra.kind(lookalike))
        rows = [r[3] for r in self.discover()]
        self.assertNotIn(str(source), rows)
        self.assertNotIn(str(keys), rows)

    def test_custom_derived_data_requires_metadata_and_preserves_checkout(self):
        derived = self.root / 'arbitrary-dd'
        build = derived / 'Build'
        (build / 'Intermediates.noindex').mkdir(parents=True)
        (build / 'Intermediates.noindex/object.o').write_bytes(b'object')
        self.assertIsNone(extra.kind(build))
        (derived / 'info.plist').write_bytes(plistlib.dumps({'WorkspacePath': str(self.root / 'ios/App.xcworkspace')}))
        checkout = derived / 'SourcePackages/checkouts/dependency'
        checkout.mkdir(parents=True)
        (checkout / 'source.swift').write_text('preserve')
        self.assertEqual(extra.kind(build), 'native-cache')
        rows = [r[3] for r in self.discover()]
        self.assertIn(str(build), rows)
        self.assertNotIn(str(checkout), rows)

    def test_owned_scratch_root_does_not_admit_neighbors_or_symlinks(self):
        root = self.root / 'owned-agent'
        root.mkdir()
        child = root / 'session'
        child.mkdir()
        neighbor = self.root / 'another-user'
        neighbor.mkdir()
        link = root / 'link'
        link.symlink_to(neighbor, target_is_directory=True)
        with patch.object(extra, 'agent_temp_root', return_value=root):
            self.assertTrue(extra.private_project_root(child))
            self.assertFalse(extra.private_project_root(neighbor))
            self.assertFalse(extra.private_project_root(link))

    def test_overridden_home_never_auto_discovers_real_user_scratch(self):
        actual = extra.agent_temp_root()
        with patch.object(extra, 'owned_directory', return_value=True):
            self.assertNotIn(actual, list(extra.scratch_roots(self.root)))

    def test_fixture_guard_rejects_mutation_outside_fixture(self):
        source = self.root / 'unselected'
        source.mkdir()
        (source / 'keep').write_text('preserve')
        sandbox = self.root / 'fixture'
        sandbox.mkdir()
        code = 'source "$1/lib/core.zsh"; devclean_validate_delete_target "$2" "$3"'
        result = subprocess.run(['zsh', '-c', code, 'zsh', str(ROOT), str(source), str(self.root)],
                                env={**os.environ, 'DEVCLEAN_TEST_MUTATION_ROOT': str(sandbox)})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((source / 'keep').read_text(), 'preserve')

    def test_active_source_project_protects_unopened_caches(self):
        subprocess.run(['git', 'init', '-q', str(self.root)], check=True)
        source = self.root / 'source.ts'
        source.write_text('active')
        target = self.root / 'node_modules'
        target.mkdir()
        (target / 'cache').write_text('preserve')
        with source.open() as handle:
            result = subprocess.run([str(ROOT / 'bin/clear-dev-caches'), 'scan', '--projects', '--root', str(self.root), '--include-recent'], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('in-use (skip)', result.stdout)
        self.assertTrue(target.exists())

    def test_native_plan_is_rechecked_after_key_is_added(self):
        target = self.module / 'build/intermediates'
        target.mkdir(parents=True)
        (target / 'data').write_bytes(b'object')
        plan = self.root / 'plan.json'
        subprocess.run([str(ROOT / 'bin/clear-dev-caches'), 'scan', '--projects', '--root', str(self.root), '--include-recent', '--permanent', '--save-plan', str(plan)], check=True, capture_output=True)
        (target / 'signing.p12').write_bytes(b'private fixture')
        result = subprocess.run([str(ROOT / 'bin/clear-dev-caches'), 'clean', '--plan', str(plan), '--user-approved'], capture_output=True, text=True)
        self.assertTrue((target / 'signing.p12').exists())
        self.assertIn('1 skipped', result.stdout)


class SimulatorSafety(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = pathlib.Path(self.tmp.name).resolve()
        self.uid = '11111111-2222-3333-4444-555555555555'
        self.path = self.root / self.uid
        (self.path / 'data').mkdir(parents=True)
        self.row = {'udid': self.uid, 'state': 'Shutdown', 'isAvailable': True}

    def test_no_selection_and_booted_devices_cannot_enter_plan(self):
        for selected, state in (([], 'Shutdown'), ([self.uid], 'Booted')):
            row = {**self.row, 'state': state}
            with patch.object(simulators, 'root', return_value=self.root), patch.object(simulators, 'devices', return_value={self.uid: row}), contextlib.redirect_stdout(io.StringIO()) as output:
                simulators.plan(selected)
            self.assertIn('\tskip\t', output.getvalue())

    def test_selected_device_becoming_active_cannot_be_erased(self):
        expected = simulators.fingerprint(self.path, self.row)
        with patch.object(simulators, 'root', return_value=self.root), patch.object(simulators, 'devices', return_value={self.uid: {**self.row, 'state': 'Booted'}}), patch.object(simulators.subprocess, 'run') as command:
            self.assertEqual(simulators.erase(self.uid, expected), 2)
        command.assert_not_called()

    def test_exact_selected_device_erasure_preserves_definition(self):
        expected = simulators.fingerprint(self.path, self.row)
        with patch.object(simulators, 'root', return_value=self.root), patch.object(simulators, 'devices', return_value={self.uid: self.row}), patch.object(simulators.subprocess, 'run') as command:
            self.assertEqual(simulators.erase(self.uid, expected), 0)
        command.assert_called_once_with(['xcrun', 'simctl', 'erase', self.uid], check=True)
        self.assertTrue(self.path.exists())


if __name__ == '__main__':
    unittest.main()
