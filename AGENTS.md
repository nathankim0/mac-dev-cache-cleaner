# Contributor Safety Rules

- Keep the default command read-only. Mutations require `clean` and confirmation.
- Before any mutation, show the exact plan and consequences, ask the user once, and wait for a separate affirmative reply. Use `--user-approved` only after that reply; never infer approval or use the legacy `--yes` flag in agent workflows.
- Never hardcode a user, project, or workspace path. Discover projects from markers below caller-supplied roots.
- Treat scan output as untrusted input. Revalidate containment, symlink status, and filesystem identity at every mutation sink.
- Preserve project source, Git metadata, credentials, Docker volumes, active Shorebird revisions, referenced Android images, and referenced NDKs.
- Keep aggressive cleanup categories opt-in and separate from `--all`.
- Add or update fixture-based tests for every safety or discovery change.
- Run `zsh -n` and `zsh tests/run.zsh` before committing.
