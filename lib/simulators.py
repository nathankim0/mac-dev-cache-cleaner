"""Explicit iOS simulator erasure; device definitions and runtimes survive."""
import hashlib
import json
import pathlib
import re
import subprocess
import sys

from inventory import home, identity, measured, real_owned

UUID = re.compile(r'[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}')


def devices():
    result = subprocess.run(['xcrun', 'simctl', 'list', 'devices', '--json'], check=True, capture_output=True, text=True)
    return {row['udid']: row for group in json.loads(result.stdout)['devices'].values() for row in group}


def root():
    return home() / 'Library/Developer/CoreSimulator/Devices'


def fingerprint(path, row):
    data = path / 'data'
    info = real_owned(data)
    if not info:
        raise ValueError('simulator data is not an owned real directory')
    return hashlib.sha256(json.dumps([row['udid'], row['state'], row.get('isAvailable'),
                                     info.st_dev, info.st_ino, info.st_mtime_ns]).encode()).hexdigest()


def plan(selected):
    inventory = devices()
    if any(value not in inventory for value in selected):
        raise ValueError('unknown simulator UUID; select an existing device')
    for udid, row in inventory.items():
        path = root() / udid
        info = real_owned(path)
        if not UUID.fullmatch(udid) or not info or path.is_symlink():
            continue
        size = measured([(path, info)]).get(path)
        if size is None:
            continue
        eligible = udid in selected and row['state'] == 'Shutdown' and row.get('isAvailable', False)
        action = 'erase-ios' if eligible else 'skip'
        state = 'selected-shutdown' if eligible else ('in-use' if row['state'] != 'Shutdown' else 'select-uuid')
        metadata = fingerprint(path, row) if eligible else ''
        print('ios-simulator', state, size, path, root(), identity(info), action, metadata, sep='\t')


def erase(udid, expected):
    if not UUID.fullmatch(udid):
        return 2
    path = root() / udid
    row = devices().get(udid)
    if (not row or row['state'] != 'Shutdown' or not row.get('isAvailable', False)
            or path.is_symlink() or fingerprint(path, row) != expected):
        print('warning: selected simulator changed or is active; skipped', file=sys.stderr)
        return 2
    subprocess.run(['xcrun', 'simctl', 'erase', udid], check=True)
    after = devices().get(udid)
    if not after or after['state'] != 'Shutdown':
        raise RuntimeError('simulator definition/state was not preserved')
    return 0


if __name__ == '__main__':
    try:
        if sys.argv[1] == 'plan':
            plan(sys.argv[2:])
        elif sys.argv[1] == 'erase':
            sys.exit(erase(*sys.argv[2:]))
        else:
            sys.exit(2)
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f'warning: simulator operation failed: {error}', file=sys.stderr)
        sys.exit(1)
