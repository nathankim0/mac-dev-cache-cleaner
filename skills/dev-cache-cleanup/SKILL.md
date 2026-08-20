---
name: dev-cache-cleanup
description: Safely inspect and reclaim macOS developer disk space with clear-dev-caches. Use when disk space is low, developer caches need cleanup, Trash cleanup is blocked, or the user asks about project build artifacts, node_modules, Shorebird, Xcode DerivedData, Android SDK/emulator data, Colima, Docker caches, or post-deployment cleanup.
---

# Developer Cache Cleanup

Use `clear-dev-caches` to discover rebuildable artifacts without hardcoding project directories.

## Workflow

1. Check free space with `df -h /System/Volumes/Data`.
2. If Trash is blocked, run `clear-dev-caches trash-status`. Use `clear-dev-caches empty-trash` only with explicit authorization; add `--restart-finder` only after explaining that Finder will restart.
3. Run a read-only scan first. Start with `clear-dev-caches scan --all`; add `--root PATH` when the user scoped the work to a directory.
4. Explain the largest candidates and what will be preserved. Recent projects show as `recent (skip)` and are excluded from cleanup by default.
5. Present the exact cleanup command, selected categories, item count, estimated size, deletion mode, and any Colima, Android AVD, recent-project, permanent-delete, or Trash-emptying consequences. Ask the user once whether to apply that exact plan and wait for a separate affirmative reply.
6. Only after that reply, run `clear-dev-caches clean` with the same options plus `--user-approved`. Prefer the default Trash mode when recoverability matters; use `--permanent` only when the approved plan explicitly prioritizes immediately reclaiming space.
7. Recheck disk space and report succeeded, skipped, and failed actions.

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
- Treat `--android-avd-data` and `--temp` as aggressive, separately authorized categories. AVD cleanup preserves the virtual-device definition and base system image but resets emulator user data.
- Do not use `--include-recent` unless the user reviewed and approved recently active projects.
- If a target changed after scanning or is in use, leave it untouched and report the skip.
- Trash mode does not reclaim capacity until Trash is emptied. Present Trash size and contents status, then obtain the mandatory one-time approval before `empty-trash --user-approved`.

## Deployment Cleanup

After a successful deployment, scan the deployed repository with `clear-dev-caches scan --root <repository> --projects`. Clean only disposable build outputs approved by the user or the deployment workflow. Then scan `--shorebird` when Shorebird was used.

Do not clean after a failed or interrupted deployment. Preserve build outputs, logs, symbols, release artifacts, and patch state needed for diagnosis or retry.
