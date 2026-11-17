# mac-dev-cache-cleaner

`clear-dev-caches` is a safety-first macOS CLI that finds rebuildable developer artifacts and explains what it can reclaim before it changes anything.

It discovers projects from markers such as `.git`, `package.json`, `pubspec.yaml`, Gradle settings, `Cargo.toml`, `go.mod`, and Python project files. There are no hardcoded project names or personal workspace paths.

## Highlights

- Read-only `scan` is the default; cleanup requires the explicit `clean` command and confirmation.
- Recently active projects are visible but excluded unless `--include-recent` is passed.
- Paths are revalidated immediately before removal, including filesystem identity checks.
- Git-tracked files are preserved even inside folders named `build`, `dist`, or `.dart_tool`, including when replaying saved plans.
- Trash is the default for path-based artifacts; `--permanent` is explicit.
- Shorebird keeps the active Flutter revision.
- Android keeps the newest API, images referenced by AVDs, and NDKs referenced by Flutter or discovered Gradle projects.
- Colima prunes Docker containers, images, networks, and build cache, then trims the VM disk. Docker volumes are not pruned.
- AVD user data and temporary files are separate aggressive categories.
- Every attempted operation is logged under `~/.local/state/mac-dev-cache-cleaner/operations.log`.

The safety model is inspired by [Mole](https://github.com/tw93/Mole): bounded discovery, preview-first cleanup, explicit confirmation, recent-project protection, and deletion-time path validation. This repository is an independent implementation focused on developer caches.

## Install

Requires macOS, zsh, and Python 3.9 or newer.

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

Every mutating command asks for confirmation after displaying the exact plan. Agents and wrappers may use `--user-approved` only after showing that plan and receiving an explicit user approval; it prevents a duplicate shell prompt, not the approval step itself. The older `--yes` and `-y` spellings remain compatibility aliases but should not be used in new integrations.

Diagnose or empty a stuck Trash without deleting it directly:

```sh
clear-dev-caches trash-status
clear-dev-caches empty-trash
# If Finder itself is stuck, explicitly restart it and retry:
clear-dev-caches empty-trash --restart-finder
```

Run `clear-dev-caches --help` for every option.

### Save and apply an exact plan

For agent-driven or delayed cleanup, save the selected targets and deletion mode in a private file:

```sh
clear-dev-caches scan --all --permanent --save-plan "$TMPDIR/developer-cleanup.json"
clear-dev-caches scan --plan "$TMPDIR/developer-cleanup.json"
# After reviewing the paths and approving the permanent deletion:
clear-dev-caches clean --plan "$TMPDIR/developer-cleanup.json" --user-approved
```

A saved plan never discovers new targets or accepts a different deletion mode. Cleanup rechecks path identity, open files, and tool-specific safety conditions. Changed and in-use targets are skipped, and skipped actions are reported separately from failed actions. Keep Trash emptying separate from a saved plan.

### Inspect a specific temporary folder, Colima profile, or AVD

```sh
# Only rebuildable project output in a caller-selected, owned tmp/T directory.
clear-dev-caches scan --temp-projects --temp-root "$HOME/.openclaw/tmp"

# Whole old entries, including test copies/results: separate opt-in.
clear-dev-caches scan --temp --temp-root "$HOME/.openclaw/tmp" --save-plan "$TMPDIR/old-temp.json"

# Stopped profiles normally show Mac allocation only; this temporarily boots one.
clear-dev-caches scan --colima-profile build --inspect-stopped-colima --save-plan "$TMPDIR/build-profile.json"

# Reset only the user data and snapshots of the named inactive AVD.
clear-dev-caches scan --avd old_test_device --save-plan "$TMPDIR/avd-reset.json"
```

Colima estimates come from Docker's disk-usage inventory, excluding volumes. Intermediate build images are not counted as separate top-level images. A stopped-profile inspection can temporarily resume containers configured to auto-start; it does not change the active Docker context or save new profile settings. Applying a reviewed plan prunes only the selected profiles if their Docker inventory still matches, preserves active containers and all volumes, and restores initially stopped profiles to stopped state. Docker estimates, Mac VM disk allocation, and actual Data-volume free space are reported separately. A successful trim can leave the Mac allocation unchanged; the VM is never recreated to reclaim space.

## Categories

| Option | Scans | Preserves |
| --- | --- | --- |
| `--projects` | `node_modules`, build outputs, `.dart_tool`, `.next`, `target`, Pods, and related artifacts | source, Git data, unmarked lookalike folders, recent projects by default |
| `--temp-projects` | project artifacts inside the current user's TMPDIR or a selected owned temporary root | test source, logs, data, unmarked directories, recent artifacts by default |
| `--shared` | individual Gradle build/dependency caches, Dart analysis caches, npm, Yarn, pnpm, Bun, CocoaPods, Playwright, node-gyp, and Homebrew | version-specific Gradle state, project source, credentials |
| `--shorebird` | inactive cached Flutter revisions | active Shorebird Flutter revision |
| `--xcode` | DerivedData | archives, simulators, signing data |
| `--android` | older unused system images and NDKs | newest API, AVD images, referenced NDKs |
| `--colima` | Docker containers, images, networks, build cache, reclaimable VM blocks | Docker volumes and the profile's running/stopped state |
| `--android-avd-data` | emulator user data, snapshots, caches | AVD definition and base system image |
| `--temp` | old user-owned top-level entries in an owned temporary root | recent/active entries, zero-allocation entries, Git data and credential-like files |

`--all` includes the standard categories but intentionally excludes `--android-avd-data` and `--temp`.

Home discovery also scans `.local/share`, `.openclaw/tmp`, and known Codex artifact, backup, and temporary roots up to 12 levels deep. Known retained cache wrappers in Codex storage do not need a project manifest. The candidates are their build/dependency outputs, not the containing backup, source copy, logs, or database. Directory-scoped project scans do not add these roots. Generic `build`, `dist`, and `target` directories with identifiable mixed evidence are preserved. Project and temporary scans batch size measurements and avoid a process launch per entry.

## Safety notes

- A scan is a snapshot. Each target's device, inode, and modification time are checked again before an action.
- Cleanup and Trash-emptying require one user confirmation. Read-only scans do not.
- Open files and directories are skipped using an open-file inventory refreshed during cleanup. Unreadable paths are not treated as empty.
- The named AVD must be inactive both during planning and immediately before reset; a running AVD with a different name is preserved.
- Android package cleanup uses `sdkmanager --uninstall` and is skipped while an emulator is active.
- Trash mode does not increase free space until Trash is emptied. Pass `--empty-trash` only if that is intended, or use `--permanent` after reviewing the plan.
- Cache sizes are estimates. Judge space recovery using the Data-volume free space before and after cleanup.

## Development

```sh
zsh -n bin/clear-dev-caches lib/*.zsh tests/run.zsh install.sh
zsh tests/run.zsh
```

Contributions that weaken scan-first behavior, path validation, or preservation rules will not be accepted.

## License

MIT

### Completed mobile builds and agent scratch space

`--temp-projects` also discovers the current user's owned `/private/tmp/claude-<uid>` and Hermes profile scratch roots. Another user's directory, symlinks, and unrelated `/private` paths remain refused. Native Gradle intermediate/generated folders and `.cxx` are recognized from Gradle markers; generated image resources no longer cause every intermediate to be retained. Custom Xcode DerivedData is recognized from `info.plist` and its build layout, not from names such as `dd` alone. Dependency checkouts and original sources remain outside the selected build children.

Gradle `build/outputs` is shown as `release-review (skip)` until `--release-artifacts` is explicit. Use it only for completed releases, review the exact files, then approve the saved plan. Arbitrary screenshots and source copies are not classified as disposable solely because they are under a temporary folder.

```sh
clear-dev-caches scan --temp-projects --include-recent --permanent --save-plan "$TMPDIR/agent-builds.json"
clear-dev-caches scan --root "$HOME/finished-app" --projects --release-artifacts --include-recent --permanent --save-plan "$TMPDIR/finished-builds.json"
```

Open source files and working directories protect their project's unopened caches too. Scan marks them `in-use (skip)`; cleanup refreshes this protection. This does not prove that an idle or unidentified session is finished: explicitly exclude those roots during review.

### Reuse and inspect simulator devices

Reuse existing idle iPhone and Android devices before creating an app-specific device. Do not interrupt another task's device. iOS device data is an explicit category, separate from `--all`:

```sh
clear-dev-caches scan --ios-simulator-data
# Select an existing shutdown device UUID from xcrun simctl list devices:
clear-dev-caches scan --simulator <UUID> --save-plan "$TMPDIR/ios-reset.json"
# After approval of app/login/test-data loss on that exact device:
clear-dev-caches clean --plan "$TMPDIR/ios-reset.json" --user-approved
```

The first command only measures devices; no UUID is selected implicitly. Cleanup checks state, ownership, open files and the saved data identity again, then uses `simctl erase`. Device definitions and OS runtimes remain. Booted, changed or unselected devices are preserved. Inspect test-manager recordings as well as installed apps when one device grows unusually large.

An inspected Colima VM with no unused Docker objects may still offer a trim-only plan. It does not delete volumes or recreate the VM. Docker estimates, guest filesystem usage, host VM allocation and actual Mac free-space changes are different measurements; no reclaimed bytes are promised from trim alone.

Tests override HOME and stay inside an owned fixture tree. Real-user scratch discovery is disabled when HOME differs from the account's registered home. The shell suite additionally exports a mutation boundary, so even a discovery regression cannot remove paths outside its fixture. Run `zsh tests/run.zsh`; do not run destructive tests against personal project folders.
