"""Tracked source survives cache-name discovery and previously saved cleanup plans."""
import contextlib
import importlib.util
import io
import pathlib
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'lib'))
spec = importlib.util.spec_from_file_location('inventory', ROOT / 'lib/inventory.py')
inventory = importlib.util.module_from_spec(spec)
spec.loader.exec_module(inventory)


class TrackedSourceTests(unittest.TestCase):
    def test_saved_plan_cannot_delete_newly_tracked_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            target = root / 'build'
            target.mkdir()
            source = target / 'source.txt'
            source.write_text('preserve source\n')
            plan = root / 'approved.json'
            subprocess.run([
                str(ROOT / 'bin/clear-dev-caches'), 'scan', '--projects', '--root', str(root),
                '--include-recent', '--permanent', '--save-plan', str(plan),
            ], check=True, capture_output=True)
            subprocess.run(['git', '-C', str(root), 'add', '--', str(source)], check=True)
            result = subprocess.run([
                str(ROOT / 'bin/clear-dev-caches'), 'clean', '--plan', str(plan), '--user-approved',
            ], capture_output=True, text=True)
            self.assertEqual(source.read_text(), 'preserve source\n')
            self.assertIn('0 succeeded, 1 skipped, 0 failed', result.stdout)

    def test_nested_markers_and_cache_names_preserve_source(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            project = root / 'engine'
            project.mkdir()
            (project / 'pubspec.yaml').write_text('name: fixture\n')
            for name in ('build', 'dist', '.dart_tool'):
                target = project / name
                target.mkdir()
                (target / 'source.txt').write_text('preserve source\n')
                subprocess.run(['git', '-C', str(root), 'add', '--', str(target)], check=True)
                self.assertTrue(inventory.tracked_source(target))
                check = subprocess.run([
                    'python3', '-B', str(ROOT / 'lib/inventory.py'), 'project-check',
                    str(target), str(root), '7', 'recent',
                ], capture_output=True)
                self.assertNotEqual(check.returncode, 0)
            cache = project / 'node_modules'
            cache.mkdir()
            (cache / 'cache.txt').write_text('rebuildable\n')
            self.assertFalse(inventory.tracked_source(cache))
            output = io.StringIO()
            with contextlib.redirect_stdout(output), contextlib.redirect_stderr(io.StringIO()):
                inventory.projects(root, 6, 7)
            rows = [line.split('\t')[3] for line in output.getvalue().splitlines()]
            self.assertEqual(rows, [str(cache)])

    def test_unreadable_git_index_fails_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            (root / '.git').write_text('gitdir: missing-repository\n')
            target = root / 'build'
            target.mkdir()
            self.assertTrue(inventory.tracked_source(target))


if __name__ == '__main__':
    unittest.main()
