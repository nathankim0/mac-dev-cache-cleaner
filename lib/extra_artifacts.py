"""Bounded native build layouts and owned agent scratch directories."""
import os
import pathlib
import plistlib
import pwd


def owned_directory(path):
    try:
        return path.is_dir() and path.resolve() == path and path.stat().st_uid == os.getuid()
    except OSError:
        return False


def agent_temp_root():
    return pathlib.Path('/private/tmp') / f'claude-{os.getuid()}'


def private_project_root(path):
    root = agent_temp_root()
    return owned_directory(root) and owned_directory(path) and (path == root or root in path.parents)


def scratch_roots(home):
    root = agent_temp_root()
    # An overridden HOME (tests/recovery rehearsal) must never discover real-user scratch.
    actual_home = pathlib.Path(pwd.getpwuid(os.getuid()).pw_dir).resolve()
    if home == actual_home and owned_directory(root):
        yield root
    for path in sorted((home / '.hermes/profiles').glob('*/cache/scratch')):
        if owned_directory(path):
            yield path


def gradle_module(path):
    return any((path / name).is_file() for name in ('build.gradle', 'build.gradle.kts'))


def gradle_root(path):
    return any((path / name).is_file() for name in ('settings.gradle', 'settings.gradle.kts'))


def workspace(path):
    """A name like 'dd' alone is not enough to recognize DerivedData."""
    try:
        info = path / 'info.plist'
        if info.is_symlink() or info.stat().st_size > 65536:
            return None
        value = plistlib.loads(info.read_bytes()).get('WorkspacePath')
        if (isinstance(value, str) and value.startswith('/')
                and any((path / 'Build' / child).is_dir() for child in ('Intermediates.noindex', 'Products'))):
            return pathlib.Path(value)
    except (OSError, ValueError, AttributeError, plistlib.InvalidFileException):
        pass
    return None


def kind(path):
    parent = path.parent
    if path.name == '.cxx' and gradle_module(parent):
        return 'native-cache'
    if path.name == '.gradle' and gradle_root(parent):
        return 'native-cache'
    if parent.name == 'build' and gradle_module(parent.parent):
        if path.name in ('intermediates', 'generated', 'tmp', 'kotlin', 'kotlinToolingMetadata'):
            return 'native-cache'
        if path.name == 'outputs':
            return 'release-output'
    if path.name in ('Build', 'ModuleCache.noindex', 'Index.noindex', 'SDKStatCaches.noindex') and workspace(parent):
        return 'native-cache'
    return None


def container(path):
    return (path.name == 'build' and gradle_module(path.parent)) or bool(workspace(path))


def context(path):
    value = workspace(path.parent)
    if value:
        return value.parent
    return path.parent.parent if path.parent.name == 'build' else path.parent


def private_material(path):
    """Generated images are caches; keys, env files and repositories are not."""
    try:
        def unreadable(error):
            raise error
        for base, dirs, files in os.walk(path, followlinks=False, onerror=unreadable):
            if '.git' in dirs or '.git' in files:
                return True
            for name in files:
                lower = name.lower()
                if lower == '.env' or lower.startswith('.env.') or lower.endswith(('.p8', '.p12', '.pfx', '.jks', '.keystore', '.pem', '.key')):
                    return True
    except OSError:
        return True
    return False
