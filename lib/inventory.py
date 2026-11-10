"""Read-only, bounded filesystem inventory for the shell entry point."""

import functools
import hashlib
import json
import os
import pathlib
import re
import stat
import subprocess
import sys
import time

ARTIFACTS = frozenset('node_modules build .dart_tool .next dist target .turbo .pytest_cache .parcel-cache Pods'.split())
BROAD_OUTPUTS = frozenset(('build', 'dist', 'target'))
MARKERS = ('.git', 'package.json', 'pnpm-workspace.yaml', 'yarn.lock', 'pubspec.yaml', 'Cargo.toml',
           'go.mod', 'pyproject.toml', 'requirements.txt', 'Podfile', 'settings.gradle', 'settings.gradle.kts')
RETAINED = frozenset(('retained-build-cache', 'worktree-build-cache', 'preserved-dev-cache', 'local-build-cache',
                      'retained-build-artifacts', 'preserved-cache', 'preserved-caches', 'build-artifacts', 'worktree-artifacts'))
AVD_STATE = ('userdata-qemu.img.qcow2', 'snapshots', 'sdcard.img', 'encryptionkey.img.qcow2',
             'cache.img.qcow2', 'cache.img', 'bootcompleted.ini', 'read-snapshot.txt')
CODEX_ROOTS = ('artifacts', 'task-artifacts', 'task-backups', 'backups', 'worktree-backups', 'tmp')
PROTECTED_NAMES = frozenset(('.git', '.ssh', '.aws', '.gnupg', '.Trash', '.env'))
SHARED_PATHS = ('.gradle/caches/build-cache-1', '.gradle/caches/modules-2', '.gradle/caches/jars-9',
                '.gradle/.tmp', '.npm/_cacache', '.yarn/cache', '.pnpm-store', '.bun/install/cache',
                '.dartServer/.analysis-driver', '.dartServer/.plugin_manager', 'Library/Caches/CocoaPods',
                'Library/Caches/ms-playwright', 'Library/Caches/node-gyp', 'Library/Caches/Homebrew')


@functools.lru_cache(maxsize=1)
def home():
    return pathlib.Path(os.environ['HOME']).resolve()


def within(path, root):
    return path == root or root in path.parents


def recordable(path):
    return not any(char in str(path) for char in '\r\n\t\0')


def identity(info):
    return f'{info.st_dev}:{info.st_ino}:{int(info.st_mtime)}'


def real_owned(path):
    try:
        info = path.lstat()
        if path != path.resolve() or info.st_uid != os.getuid():
            return None
        return info if stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode) else None
    except OSError:
        return None


def allowed_temp_root(root):
    current = pathlib.Path(os.environ.get('TMPDIR', '/tmp')).resolve()
    return root.name in ('T', 'tmp') and bool(real_owned(root)) and root.is_dir() and (
        (root == current and str(root).startswith('/private/var/folders/'))
        or (root != home() and within(root, home()) and not protected(root))
    )


def protected(path):
    h = home()
    return bool(PROTECTED_NAMES.intersection(path.parts)) or any(part.startswith('.env.') for part in path.parts) or any(
        within(path, h / directory) for directory in ('Documents', 'Desktop', 'Pictures', 'Movies', 'Music')
    )


def retained_root(path):
    return any(within(path, home() / '.codex' / name) for name in CODEX_ROOTS)


def project_marker(path):
    return (path.name in RETAINED and retained_root(path)) or any((path / marker).exists() for marker in MARKERS)


def find_project(path, root):
    for parent in path.parents:
        if not within(parent, root):
            break
        if project_marker(parent):
            return parent
    return None


def children(path):
    with os.scandir(path) as iterator:
        return list(iterator)


def recent_below(path, cutoff, depth, ignore=()):
    try:
        for entry in children(path):
            if entry.name in ignore or entry.is_symlink():
                continue
            if entry.stat(follow_symlinks=False).st_mtime >= cutoff:
                return True
            if depth > 0 and entry.is_dir(follow_symlinks=False) and recent_below(entry.path, cutoff, depth - 1, ignore):
                return True
    except OSError:
        return True  # Unknown activity is protected.
    return False


def recent_project(path, cutoff):
    if (path / '.git').exists():  # Includes linked Git worktrees (.git file).
        try:
            for args in (['log', '-1', '--format=%ct'], ['status', '--porcelain', '--untracked-files=normal']):
                result = subprocess.run(['git', '-C', str(path), *args], capture_output=True, text=True)
                if result.returncode:
                    return True
                value = result.stdout.strip()
                if (args[0] == 'log' and value.isdigit() and int(value) >= cutoff) or (args[0] == 'status' and value):
                    return True
        except OSError:
            return True
    return recent_below(path, cutoff, 2, ARTIFACTS | {'.git'})


def measured(paths):
    """Use one du per batch, not one subprocess for every directory or file."""
    sizes = {}
    dirs = []
    for path, info in paths:
        if stat.S_ISREG(info.st_mode):
            sizes[path] = (info.st_blocks + 1) // 2
        else:
            try:
                with os.scandir(path) as iterator:
                    empty = next(iterator, None) is None
                if empty:
                    sizes[path] = 0
                else:
                    dirs.append(path)
            except OSError:
                pass
    for offset in range(0, len(dirs), 64):
        batch = dirs[offset:offset + 64]
        result = subprocess.run(['/usr/bin/du', '-skP', *map(str, batch)], capture_output=True, text=True, errors='replace')
        if result.returncode:
            print(f'warning: {len(batch)} paths have incomplete size measurements; skipped', file=sys.stderr)
            continue
        for line in result.stdout.splitlines():
            size, sep, name = line.partition('\t')
            if sep and size.isdigit():
                sizes[pathlib.Path(name)] = int(size)
    return sizes


def emit(category, root, candidates, skip_empty=False):
    sizes = measured([(path, info) for path, info, _ in candidates])
    empty = 0
    for path, info, state in candidates:
        if skip_empty and sizes.get(path) == 0:
            empty += 1
            continue
        size = sizes.get(path)
        if size is None:
            state = 'unmeasured'
        print(category, state, size or 0, path, root, identity(info), 'path', sep='\t')
    if empty:
        print(f'info: left {empty} zero-allocation temporary entries untouched', file=sys.stderr)


def mixed_output(path):
    if path.name not in BROAD_OUTPUTS:
        return False
    try:
        stack = [path]
        while stack:
            for entry in children(stack.pop()):
                name = entry.name.lower()
                if (sensitive_name(name) or name in ('screenshots', 'evidence')
                        or name.endswith(('.pdf', '.xlsx', '.docx', '.png', '.jpg', '.webp', '.mp4', '.ipa', '.aab', '.xcarchive'))):
                    return True
                if entry.name not in ARTIFACTS - BROAD_OUTPUTS and entry.is_dir(follow_symlinks=False):
                    stack.append(entry.path)
    except OSError:
        return True
    return False


def projects(root, depth, age):
    cutoff = time.time() - age * 86400
    stack = [(root, 0, None)]
    candidates, recency = [], {}
    unavailable = 0
    while stack:
        directory, level, project = stack.pop()
        if level >= depth:
            continue
        try:
            entries = children(directory)
        except OSError:
            unavailable += 1
            continue
        if (directory.name in RETAINED and retained_root(directory)) or {entry.name for entry in entries}.intersection(MARKERS):
            project = directory
        for entry in entries:
            path = pathlib.Path(entry.path)
            if not entry.is_dir(follow_symlinks=False) or protected(path) or not recordable(path):
                continue
            if entry.name in ARTIFACTS:
                if project:
                    info = real_owned(path)
                    if info and mixed_output(path):
                        print(f'warning: mixed build output preserved: {path}', file=sys.stderr)
                    elif info:
                        if project not in recency:
                            recency[project] = recent_project(project, cutoff)
                        state = 'recent' if info.st_mtime >= cutoff or recency[project] else 'old'
                        candidates.append((path, info, state))
                continue
            if entry.name.startswith('.') or entry.name in ('Library', 'Applications', 'Virtual Machines.localized'):
                continue
            stack.append((path, level + 1, project))
    if unavailable:
        print(f'warning: {unavailable} unreadable directories were not scanned under {root}', file=sys.stderr)
    emit('projects', root, candidates)


def sensitive_name(name):
    name = name.lower()
    return (name in PROTECTED_NAMES or name.startswith('.env.')
            or re.search(r'(secret|token|password|credential|keychain|private-key)', name)
            or name.endswith(('.pem', '.key', '.p12', '.pfx', '.patch', '.bundle')))


def protected_contents(path):
    try:
        for entry in children(path):
            if sensitive_name(entry.name):
                return True
            if entry.name not in ARTIFACTS - BROAD_OUTPUTS and entry.is_dir(follow_symlinks=False) and protected_contents(entry.path):
                return True
    except OSError:
        return True
    return False


def temp_candidate(path, root, cutoff):
    info = real_owned(path)
    name = path.name.lower()
    if (not info or path.parent != root or not recordable(path) or protected(path) or info.st_mtime >= cutoff
            or name.startswith(('com.apple.', 'com.agilebits.', 'devclean.'))
            or sensitive_name(name)
            or getattr(info, 'st_flags', 0) & (getattr(stat, 'UF_IMMUTABLE', 0) | getattr(stat, 'SF_IMMUTABLE', 0) | 0x80000)):
        return None
    if stat.S_ISDIR(info.st_mode) and (recent_below(path, cutoff, 2, ARTIFACTS) or protected_contents(path)):
        return None
    return info


def temporary(root, age):
    cutoff = time.time() - age * 86400
    candidates = []
    for entry in children(root):
        path = pathlib.Path(entry.path)
        info = temp_candidate(path, root, cutoff)
        if info:
            candidates.append((path, info, f'older-than-{age}d'))
    emit('temp', root, candidates, skip_empty=True)


def open_paths():
    result = subprocess.run(['lsof', '-nP', '-F0n'], capture_output=True)
    if result.returncode not in (0, 1) or (result.returncode and result.stderr):
        raise RuntimeError('could not inspect open files')
    paths = set()
    for record in result.stdout.split(b'\0'):
        record = record.lstrip(b'\n')
        if record.startswith(b'n/'):
            path = pathlib.Path(os.fsdecode(record[1:]).removesuffix(' (deleted)'))
            paths.add(path)
            paths.update(path.parents)
    for path in paths:
        sys.stdout.buffer.write(os.fsencode(path) + b'\0')


def avd_state(root):
    paths = []
    for name in AVD_STATE:
        path = root / name
        if path.is_symlink():
            raise ValueError('unexpected AVD state symlink')
        if path.exists():
            info = real_owned(path)
            if not info:
                raise ValueError('unexpected AVD state ownership or type')
            paths.append((path, info))
    sizes = measured(paths)
    if len(sizes) != len(paths):
        raise ValueError('AVD state size could not be measured')
    fingerprint = hashlib.sha256(json.dumps([
        (path.name, info.st_dev, info.st_ino, info.st_mtime_ns, info.st_size) for path, info in paths
    ]).encode()).hexdigest()
    print(sum(sizes.values()), fingerprint, sep='\t')


def main():
    command, *args = sys.argv[1:]
    if command == 'projects':
        projects(pathlib.Path(args[0]), int(args[1]), int(args[2]))
    elif command == 'temp':
        temporary(pathlib.Path(args[0]), int(args[1]))
    elif command == 'open-paths':
        open_paths()
    elif command == 'temp-root':
        return 0 if allowed_temp_root(pathlib.Path(args[0])) else 1
    elif command == 'temp-check':
        root = pathlib.Path(args[1])
        return 0 if allowed_temp_root(root) and temp_candidate(pathlib.Path(args[0]), root, time.time() - int(args[2]) * 86400) else 1
    elif command == 'project-check':
        path, root = map(pathlib.Path, args[:2])
        project = find_project(path, root)
        if not (path.is_dir() and path.name in ARTIFACTS and project and not mixed_output(path)):
            return 1
        return 1 if args[3] == 'old' and recent_project(project, time.time() - int(args[2]) * 86400) else 0
    elif command == 'avd-state':
        avd_state(pathlib.Path(args[0]))
    elif command == 'avd-paths':
        for name in AVD_STATE:
            print(pathlib.Path(args[0]) / name)
    elif command == 'shared-paths':
        for path in SHARED_PATHS:
            print(home() / path)
    else:
        return 2
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, RuntimeError, ValueError) as error:
        print(f'warning: {error}', file=sys.stderr)
        sys.exit(1)
