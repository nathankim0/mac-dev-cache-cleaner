"""Measure and prune local Colima profiles without using the active Docker context."""

import contextlib
import hashlib
import http.client
import json
import os
import pathlib
import re
import socket
import subprocess
import sys

from inventory import home, identity, real_owned

NAME = re.compile(r'[a-zA-Z0-9][a-zA-Z0-9_-]{0,62}\Z')
STOPPED = {'created', 'exited', 'dead'}


def profiles():
    result = subprocess.run(['colima', 'list', '--json'], check=True, capture_output=True, text=True)
    return {row['name']: row for line in result.stdout.splitlines() if line.strip()
            for row in [json.loads(line)] if row.get('runtime') == 'docker' and NAME.fullmatch(row.get('name', ''))}


def profile_root(name):
    if not NAME.fullmatch(name):
        raise ValueError('invalid Colima profile name')
    root = home() / '.colima' / name
    if not real_owned(root) or not root.is_dir():
        raise ValueError('unavailable Colima profile directory')
    return root


def allocated_kib(name):
    lima = home() / '.colima' / '_lima'
    instance = 'colima' if name == 'default' else 'colima-' + name
    return sum(p.stat().st_blocks // 2 for p in (lima / instance / 'disk', lima / '_disks' / instance / 'datadisk') if p.is_file())


class UnixHTTP(http.client.HTTPConnection):
    def __init__(self, path):
        super().__init__('localhost', timeout=20)
        self.path = str(path)

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self.path)


def daemon_socket(name):
    path = profile_root(name) / 'docker.sock'
    if path != path.resolve() or not path.is_socket():
        raise ValueError('Colima Docker socket is unavailable or outside Colima storage')
    return path


def api(path, endpoint):
    with contextlib.closing(UnixHTTP(path)) as connection:
        connection.request('GET', endpoint)
        response = connection.getresponse()
        if response.status != 200:
            raise RuntimeError(f'Docker inventory request failed ({response.status})')
        return json.load(response)


def snapshot(path):
    # /system/df lists the same top-level images as Docker's disk-usage report.
    # `image ls --all` also lists intermediate build images and is not a valid
    # comparison for that report's image count or reclaimable bytes.
    df = api(path, '/system/df')
    images = df.get('Images') or []
    containers = df.get('Containers') or []
    cache = df.get('BuildCache') or []
    volumes = df.get('Volumes') or []
    stopped = [row for row in containers if row['State'] in STOPPED]
    active = [row for row in containers if row['State'] not in STOPPED]
    active_images = {row['ImageID'] for row in active}
    unused = [row for row in images if row['Id'] not in active_images]
    unused_cache = [row for row in cache if not row.get('InUse', True)]
    size = sum(max(0, row['Size'] - max(0, row.get('SharedSize', 0))) for row in unused)
    size += sum(max(0, row.get('SizeRw', 0)) for row in stopped)
    size += sum(max(0, row['Size']) for row in unused_cache if not row.get('Shared', True))
    objects = {
        'daemon': api(path, '/info')['ID'],
        'images': sorted(row['Id'] for row in images),
        'containers': sorted((row['Id'], row['ImageID'], row['State']) for row in containers),
        'cache': sorted((row['ID'], bool(row.get('InUse', True))) for row in cache),
        'volumes': sorted(row['Name'] for row in volumes),
    }
    return {'fingerprint': hashlib.sha256(json.dumps(objects, sort_keys=True).encode()).hexdigest(),
            'images': len(unused), 'stopped': len(stopped), 'build_cache': len(unused_cache),
            'active_ids': sorted(row['Id'] for row in active), 'volumes': objects['volumes'],
            'estimated_kib': size // 1024}


@contextlib.contextmanager
def running(name, status):
    started = status == 'Stopped'
    try:
        if started:
            subprocess.run(['colima', 'start', name, '--activate=false', '--save-config=false'], check=True, stdout=sys.stderr)
        yield daemon_socket(name)
    finally:
        if started:
            subprocess.run(['colima', 'stop', name], check=True, stdout=sys.stderr)


def plan(names, inspect_stopped):
    installed = profiles()
    for name in names or sorted(installed):
        row = installed.get(name)
        if not row:
            print(f'warning: Docker profile not available: {name}', file=sys.stderr)
            continue
        try:
            root = profile_root(name)
            status = row['status']
            allocated = allocated_kib(name)
            if status == 'Stopped' and not inspect_stopped:
                print('colima', f'stopped; {allocated / 1048576:.2f} GiB on Mac; inspect to estimate', 0,
                      root, root.parent, identity(root.lstat()), 'skip', sep='\t')
                continue
            if status not in ('Running', 'Stopped'):
                raise ValueError('profile is neither running nor stopped')
            with running(name, status) as path:
                report = snapshot(path)
            metadata = json.dumps({'status': status, 'fingerprint': report['fingerprint']}, separators=(',', ':'))
            state = (f"{report['images']} images, {report['stopped']} stopped, {report['build_cache']} build cache; "
                     f'{allocated / 1048576:.2f} GiB on Mac')
            # A previously pruned VM can still retain allocated free blocks.
            action = 'colima-prune:' + name if allocated or report['images'] or report['stopped'] or report['build_cache'] else 'skip'
            if not (report['images'] or report['stopped'] or report['build_cache']):
                state += '; trim only, recovery not guaranteed'
            print('colima', state, report['estimated_kib'], root, root.parent, identity(root.lstat()), action, metadata, sep='\t')
        except (OSError, ValueError, RuntimeError, KeyError, subprocess.CalledProcessError) as error:
            print(f'warning: could not inspect Colima profile {name}: {error}', file=sys.stderr)


def prune(name, metadata):
    status = profiles().get(name, {}).get('status')
    if status != metadata.get('status') or status not in ('Running', 'Stopped'):
        print(f'warning: profile state changed; skipped: {name}', file=sys.stderr)
        return 2
    before_kib = allocated_kib(name)
    with running(name, status) as path:
        before = snapshot(path)
        if before['fingerprint'] != metadata.get('fingerprint'):
            print(f'warning: Docker inventory changed; skipped: {name}', file=sys.stderr)
            return 2
        env = {key: value for key, value in os.environ.items() if key not in ('DOCKER_HOST', 'DOCKER_CONTEXT')}
        subprocess.run(['docker', '--host', f'unix://{path}', 'system', 'prune', '--all', '--force'], check=True, env=env)
        after = snapshot(path)
        if not set(before['volumes']) <= set(after['volumes']) or not set(before['active_ids']) <= set(after['active_ids']):
            raise RuntimeError('Docker preservation check failed')
        trim = subprocess.run(['colima', '--profile', name, 'ssh', '--', 'sudo', 'fstrim', '-av'], capture_output=True)
        if trim.returncode:
            print(f'warning: Docker pruned, but VM trim failed: {name}', file=sys.stderr)
    after_kib = allocated_kib(name)
    print(f'Colima {name}: estimated Docker cleanup {before["estimated_kib"] / 1048576:.2f} GiB; '
          f'Mac VM disk allocation {before_kib / 1048576:.2f} -> {after_kib / 1048576:.2f} GiB; '
          f'{len(before["volumes"])} volumes and {len(before["active_ids"])} active containers preserved.')
    if after_kib >= before_kib:
        print(f'Colima {name}: no reduction in Mac disk allocation measured.')
    return 0


if __name__ == '__main__':
    try:
        if sys.argv[1] == 'plan':
            plan(sys.argv[3:], sys.argv[2] == '1')
        elif sys.argv[1] == 'prune':
            sys.exit(prune(sys.argv[2], json.loads(sys.argv[3])))
    except (OSError, ValueError, RuntimeError, KeyError, subprocess.CalledProcessError) as error:
        print(f'warning: Colima operation failed: {error}', file=sys.stderr)
        sys.exit(1)
