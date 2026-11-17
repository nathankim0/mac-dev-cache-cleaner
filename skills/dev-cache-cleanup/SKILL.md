---
name: dev-cache-cleanup
description: Inspect and reclaim macOS developer disk space with clear-dev-caches, including accumulated temporary test copies and retained build caches. Use for shrinking free space, developer cache cleanup, blocked Trash, project build artifacts, Shorebird, Xcode, Android, Colima, Docker, or post-deployment cleanup.
---

# Developer Cache Cleanup

Use `clear-dev-caches` to discover rebuildable artifacts without hardcoding project directories.

## Workflow

1. Check free space with `df -h /System/Volumes/Data`.
2. If Trash is blocked, run `clear-dev-caches trash-status`. Use `clear-dev-caches empty-trash` only with explicit authorization; add `--restart-finder` only after explaining that Finder will restart.
3. Run a read-only scan first and save the proposed scope with `--save-plan FILE`. For general disk cleanup, start with `clear-dev-caches scan --all --save-plan FILE`. For a directory-scoped request, use `scan --projects --root PATH`. Home discovery includes `.local/share`, OpenClaw temporary project artifacts, and retained Codex caches. Use `--temp-projects --temp-root PATH` for another owned temporary root.
4. Explain the largest candidates and what will be preserved. Recent projects show as `recent (skip)` and are excluded from cleanup by default.
5. Present the exact cleanup command, selected categories, item count, estimated size, deletion mode, and any Colima, Android AVD, recent-project, permanent-delete, or Trash-emptying consequences. Ask the user once whether to apply that exact plan and wait for a separate affirmative reply.
6. Only after that reply, run `clear-dev-caches clean --plan FILE --user-approved`. A saved plan keeps the reviewed targets and mode. Select `--permanent` at scan time only when immediate space recovery is part of the proposed plan. Keep emptying Trash separate from a saved plan.
7. Recheck disk space and report succeeded, skipped, and failed actions.

## Large or Continuing Growth

- Treat the user's suspected tool as a lead. If tens or hundreds of GiB are unexplained, continue diagnosis beyond that tool instead of ending after its cache is pruned.
- Compare Data-volume `df` usage with folder sizes. Inspect one level at a time, including the current user's actual `$TMPDIR`, `.local/share`, and `.codex/artifacts` / `.codex/task-artifacts`. Repeated test runs can retain complete source copies, `node_modules`, and `.next` outside the main repository.
- Use `--temp-projects` to inspect rebuildable artifacts inside temporary project copies. A parent temp directory's recent mtime does not mean all its old test runs are active. Recent artifacts still appear as `recent (skip)` for review. Use an explicit `--root` for a large retained project folder when the default depth is insufficient.
- Known retained build-cache containers can lack `package.json`; the tool recognizes them only inside Codex's artifact storage. Their source, logs, manifests, and evidence directory remain intact. Arbitrary artifact/data folders are not caches merely because their names mention tests or backups.
- Measure large unknown folders before deciding what can be discarded. Test databases, generated PDFs, screenshots, release outputs, and backup source need separate assessment and authorization; do not add their whole parent to a cleanup plan automatically.
- Inspect broad `build` candidates before approval: a project may also save screenshots or design assets there. If a candidate mixes rebuildable output with files to preserve, exclude that whole-directory action and propose only the verified disposable children instead.
- Avoid simultaneous overlapping whole-disk `du`/`find` scans. Start with top-level totals, drill into the largest result, and report access-denied paths as unmeasured. If folder totals do not explain usage, inspect `diskutil apfs list` and Data-volume snapshots before attributing the difference to caches.
- For Colima, distinguish the Docker estimate from Mac VM disk allocation and measured `df` recovery. `--colima-profile NAME` selects a profile. Only `scan --inspect-stopped-colima` temporarily starts stopped profiles; explain that startup can resume containers configured to auto-start. The tool preserves the active Docker context and volumes. A trim with no measured Mac space reduction is not reclaimed SSD space. Do not delete or recreate a VM to shrink it.
- Report actual before/after free space separately from candidate estimates. Moving files to Trash is not reclaimed space. If test copies caused the growth, name that cause and say whether their creation/retention logic was changed; do not claim recurrence is fixed by a one-time cleanup.

## Mandatory User Approval

- Read-only `scan`, `trash-status`, disk checks, and size inspection do not require confirmation.
- Every mutating `clean` or `empty-trash` command requires one fresh user confirmation after its exact plan and consequences are shown. This applies even when the original request broadly asked to free disk space.
- Do not run a mutating command in the same assistant turn that first reveals its plan. Pause and wait for the user's affirmative reply.
- After approval, use `--user-approved` so the CLI does not ask a second time. Never use the legacy `--yes` or `-y` flags from this skill.
- Approval applies only to the displayed plan. If the roots, categories, candidates, deletion mode, or consequences change, scan again and request a new confirmation.
- Never infer approval from silence, an earlier unrelated cleanup, or a deployment request.

## Safety Rules

- Never add a user-specific project path to the tool. Use repeatable `--root` options and project markers for discovery.
- Never clean source files, Git metadata, credentials, Documents, Desktop, media libraries, Docker volumes, the current Shorebird revision, Android images used by an AVD, or NDKs referenced by Flutter or discovered Gradle projects.
- Treat `--android-avd-data`, `--avd NAME`, and `--temp` as aggressive, separately authorized categories. AVD cleanup preserves the virtual-device definition and base system image but resets the selected inactive emulator’s apps, logins, saved data, and snapshots. A running or unidentified emulator is protected.
- Do not use `--include-recent` unless the user reviewed and approved recently active projects.
- If a target changed after scanning or is in use, leave it untouched and report the skip.
- Trash mode does not reclaim capacity until Trash is emptied. Present Trash size and contents status, then obtain the mandatory one-time approval before `empty-trash --user-approved`.

## Deployment Cleanup

After a successful deployment, scan the deployed repository with `clear-dev-caches scan --root <repository> --projects`. Clean only disposable build outputs approved by the user or the deployment workflow. Then scan `--shorebird` when Shorebird was used.

Do not clean after a failed or interrupted deployment. Preserve build outputs, logs, symbols, release artifacts, and patch state needed for diagnosis or retry.

## Native builds, simulator reuse and explicit data reset

- When large usage remains, include `scan --temp-projects` and `scan --ios-simulator-data` alongside project/Colima checks. Owned Claude temporary roots and Hermes scratch roots are included in temporary-project discovery; do not infer that their whole session folders are disposable.
- Gradle intermediates, generated resources, `.cxx` and recognized custom DerivedData build children are cache candidates. `build/outputs` stays `release-review (skip)` unless `--release-artifacts` is explicitly selected for completed releases. Inspect source/keys and keep current implementations protected.
- `scan --ios-simulator-data` measures only. `--simulator <UUID>` selects exact shutdown devices; obtain approval for loss of their apps, logins and test data before applying the saved plan. Definitions/runtimes remain, and booted or changed devices are skipped. Prefer reusing existing idle iPhone/Android devices rather than creating one per app.
- Active source files and working directories protect their project caches during scan and cleanup. Idle or unidentified sessions still need manual exclusion. Do not prune the shared VM/build caches of ongoing implementations just to reach a requested size estimate.
- An inspected empty Colima image inventory does not imply its host disk is free. Offer trim, preserve volumes, inspect remaining volume purposes and report actual host allocation/free space. Do not call the VM's whole size reclaimable or delete it to force the estimate.

- Tool development tests must use an isolated HOME and fixture-only mutation boundary. Never auto-discover the real user's system scratch roots when HOME is overridden. Validate this boundary before full cleanup regressions; source protection alone does not authorize deleting an unapproved cache.
