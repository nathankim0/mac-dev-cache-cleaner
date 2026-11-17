"""Persist the selected rows and the deletion mode; never expand a saved plan."""

import json
import os
import pathlib
import re
import stat
import sys

from inventory import ARTIFACTS, SHARED_PATHS, allowed_temp_root, home, protected, recordable, within

SCHEMA = 'clear-dev-caches-plan-v1'
MAX_BYTES = 64 * 1024 * 1024


def row_is_valid(row):
    if not isinstance(row, list) or len(row) not in (7, 8) or not all(isinstance(item, str) and recordable(item) for item in row):
        return False
    category, state, size, raw_path, raw_root, identity, action, *_ = row
    path, root = pathlib.Path(raw_path), pathlib.Path(raw_root)
    if (not path.is_absolute() or not root.is_absolute() or '..' in path.parts or '..' in root.parts
            or not within(path, root) or path == root or protected(path) or not size.isdigit()
            or not re.fullmatch(r'\d+:\d+:-?\d+', identity)):
        return False
    h = home()
    if action == 'path':
        if category == 'projects':
            return path.name in ARTIFACTS
        if category == 'shared':
            return root == h and path in {h / item for item in SHARED_PATHS}
        if category == 'xcode':
            derived = h / 'Library/Developer/Xcode/DerivedData'
            return ((path == derived and root == derived.parent)
                    or (root == derived and path.parent == derived))
        if category == 'shorebird':
            return path.parent == root == h / '.shorebird/bin/cache/flutter'
        if category == 'temp':
            return path.parent == root and allowed_temp_root(root) and bool(re.fullmatch(r'older-than-\d{1,4}d', state))
    if category == 'android-avd' and action == 'wipe-avd':
        return (path.parent == root == h / '.android/avd' and path.suffix == '.avd'
                and len(row) == 8 and bool(re.fullmatch(r'[0-9a-f]{64}', row[7])))
    if category == 'android-sdk' and action.startswith('sdkmanager:'):
        package = action.removeprefix('sdkmanager:').split(';')
        return (len(package) in (2, 4) and package[0] in ('ndk', 'system-images')
                and all(re.fullmatch(r'[a-zA-Z0-9_.-]+', part) and part not in ('.', '..') for part in package)
                and path == root.joinpath(*package))
    if category == 'colima' and action.startswith('colima-prune:') and len(row) == 8:
        name = action.removeprefix('colima-prune:')
        metadata = json.loads(row[7])
        return (bool(re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9_-]{0,62}', name))
                and path == root / name and root == h / '.colima'
                and isinstance(metadata, dict) and metadata.get('status') in ('Running', 'Stopped')
                and bool(re.fullmatch(r'[0-9a-f]{64}', metadata.get('fingerprint', ''))))
    return False


def save(source, target, mode, empty, restart, age, depth, roots):
    rows = [line.split('\t') for line in pathlib.Path(source).read_text().splitlines()]
    document = {'format': SCHEMA, 'delete_mode': mode, 'empty_trash': empty == '1', 'restart_finder': restart == '1',
                'age_days': int(age), 'max_depth': int(depth), 'scan_roots': roots, 'targets': rows}
    if not all(row_is_valid(row) for row in rows):
        raise ValueError('invalid planned target; saved plan was not written')
    # A typo in --save-plan must not overwrite an existing file.
    fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w') as output:
        json.dump(document, output, ensure_ascii=False, indent=2)
        output.write('\n')


def load(source, targets, settings):
    fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'r') as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077 or info.st_size > MAX_BYTES:
            raise ValueError('saved plan must be a private, user-owned regular file')
        document = json.loads(stream.read(MAX_BYTES + 1))
    if not isinstance(document, dict) or document.get('format') != SCHEMA or document.get('delete_mode') not in ('trash', 'permanent'):
        raise ValueError('unrecognized saved plan')
    age, depth = document.get('age_days'), document.get('max_depth')
    roots, rows = document.get('scan_roots'), document.get('targets')
    if (type(age) is not int or not 1 <= age <= 3650 or type(depth) is not int or not 1 <= depth <= 12
            or not isinstance(roots, list) or not all(isinstance(root, str) and root.startswith('/') and recordable(root) for root in roots)
            or not isinstance(rows, list) or not all(row_is_valid(row) for row in rows)
            or len({row[3] for row in rows}) != len(rows)
            or document.get('empty_trash') is not False or document.get('restart_finder') is not False):
        raise ValueError('invalid saved plan settings or targets')
    pathlib.Path(targets).write_text(''.join('\t'.join(row) + '\n' for row in rows))
    flags = (document['delete_mode'], str(int(document['empty_trash'])), str(int(document['restart_finder'])), str(age), str(depth))
    pathlib.Path(settings).write_text('\t'.join(flags) + '\n' + ''.join(root + '\n' for root in roots))


if __name__ == '__main__':
    try:
        command, *args = sys.argv[1:]
        if command == 'save':
            source, target, mode, empty, restart, age, depth, *roots = args
            save(source, target, mode, empty, restart, age, depth, roots)
        elif command == 'load':
            load(*args)
        else:
            sys.exit(2)
    except (OSError, ValueError, TypeError, KeyError) as error:
        print(f'error: {error}', file=sys.stderr)
        sys.exit(1)
