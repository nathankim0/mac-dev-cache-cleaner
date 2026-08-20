# mac-dev-cache-cleaner

`clear-dev-caches` is a safety-first macOS CLI that finds rebuildable developer artifacts and explains what it can reclaim before it changes anything.

It discovers projects from markers such as `.git`, `package.json`, `pubspec.yaml`, Gradle settings, `Cargo.toml`, `go.mod`, and Python project files. There are no hardcoded project names or personal workspace paths.

## Highlights

- Read-only `scan` is the default; cleanup requires the explicit `clean` command and confirmation.
- Recently active projects are visible but excluded unless `--include-recent` is passed.
- Paths are revalidated immediately before removal, including filesystem identity checks.
- Trash is the default for path-based artifacts; `--permanent` is explicit.
- Shorebird keeps the active Flutter revision.
- Android keeps the newest API, images referenced by AVDs, and NDKs referenced by Flutter or discovered Gradle projects.
- Colima prunes Docker containers, images, networks, and build cache, then trims the VM disk. Docker volumes are not pruned.
- AVD user data and temporary files are separate aggressive categories.
- Every attempted operation is logged under `~/.local/state/mac-dev-cache-cleaner/operations.log`.

The safety model is inspired by [Mole](https://github.com/tw93/Mole): bounded discovery, preview-first cleanup, explicit confirmation, recent-project protection, and deletion-time path validation. This repository is an independent implementation focused on developer caches.

## Install

```sh
git clone https://github.com/nathankim0/mac-dev-cache-cleaner.git
cd mac-dev-cache-cleaner
./install.sh
```

Install the bundled Codex/Claude skill too:

```sh
./install.sh --skills
```

The installer links the CLI to `~/.local/bin/clear-dev-caches`. An existing file at that path is moved to a timestamped backup instead of being overwritten.

## Usage

Start with a scan:

```sh
clear-dev-caches
clear-dev-caches scan --root "$HOME/Developer" --all
```

Apply the reviewed plan:

```sh
# Recoverable path cleanup; items remain in Trash.
clear-dev-caches clean --root "$HOME/Developer" --projects

# Immediately release space from project artifacts.
clear-dev-caches clean --root "$HOME/Developer" --projects --permanent

# Clean global toolchains without hardcoding a project directory.
clear-dev-caches clean --shorebird --android --colima
```

Diagnose or empty a stuck Trash without deleting it directly:

```sh
clear-dev-caches trash-status
clear-dev-caches empty-trash
# If Finder itself is stuck, explicitly restart it and retry:
clear-dev-caches empty-trash --restart-finder
```

Run `clear-dev-caches --help` for every option.

## Categories

| Option | Scans | Preserves |
| --- | --- | --- |
| `--projects` | `node_modules`, build outputs, `.dart_tool`, `.next`, `target`, Pods, and related artifacts | source, Git data, unmarked lookalike folders, recent projects by default |
| `--shared` | Gradle, npm, Yarn, pnpm, Bun, CocoaPods, Playwright, node-gyp, and Homebrew caches | project source and credentials |
| `--shorebird` | inactive cached Flutter revisions | active Shorebird Flutter revision |
| `--xcode` | DerivedData | archives, simulators, signing data |
| `--android` | older unused system images and NDKs | newest API, AVD images, referenced NDKs |
| `--colima` | Docker containers, images, networks, build cache, reclaimable VM blocks | Docker volumes and the profile's running/stopped state |
| `--android-avd-data` | emulator user data, snapshots, caches | AVD definition and base system image |
| `--temp` | user-owned top-level TMPDIR entries older than the threshold | recent entries and anything outside the exact TMPDIR |

`--all` includes the standard categories but intentionally excludes `--android-avd-data` and `--temp`.

## Safety notes

- A scan is a snapshot. Each target's device, inode, and modification time are checked again before an action.
- Open path-based targets are skipped.
- Android package cleanup uses `sdkmanager --uninstall` and is skipped while an emulator is active.
- Trash mode does not increase free space until Trash is emptied. Pass `--empty-trash` only if that is intended, or use `--permanent` after reviewing the plan.
- Cache sizes are estimates. Colima and AVD actions preserve some data, so actual reclaimed space can be lower than the displayed footprint.

## Development

```sh
zsh -n bin/clear-dev-caches lib/*.zsh tests/run.zsh install.sh
zsh tests/run.zsh
```

Contributions that weaken scan-first behavior, path validation, or preservation rules will not be accepted.

## License

MIT
