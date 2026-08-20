#!/bin/zsh

emulate -L zsh
setopt pipe_fail

typeset repo_dir="${0:A:h}"
integer install_skills=0

usage() {
  print -r -- "Usage: ./install.sh [--skills]"
  print -r -- "  --skills  Also install the bundled Codex and Claude skill"
}

while (( $# > 0 )); do
  case "$1" in
    --skills) install_skills=1 ;;
    --help|-h) usage; exit 0 ;;
    *) print -u2 -r -- "error: unknown option: $1"; usage >&2; exit 2 ;;
  esac
  shift
done

install_link() {
  local source_path="${1:A}"
  local target_path="$2"
  local target_dir="${target_path:h}"
  /bin/mkdir -p "$target_dir" || return 1

  if [[ -L "$target_path" && "${target_path:A}" == "$source_path" ]]; then
    print -r -- "Already installed: $target_path"
    return 0
  fi

  if [[ -e "$target_path" || -L "$target_path" ]]; then
    local backup_path
    backup_path="${target_path}.backup-$(/bin/date '+%Y%m%d-%H%M%S')"
    /bin/mv "$target_path" "$backup_path" || return 1
    print -r -- "Backed up existing file: $backup_path"
  fi

  /bin/ln -s "$source_path" "$target_path" || return 1
  print -r -- "Installed: $target_path -> $source_path"
}

install_link "$repo_dir/bin/clear-dev-caches" "$HOME/.local/bin/clear-dev-caches" || exit 1

if (( install_skills )); then
  install_link "$repo_dir/skills/dev-cache-cleanup" "$HOME/.codex/skills/dev-cache-cleanup" || exit 1
  install_link "$repo_dir/skills/dev-cache-cleanup" "$HOME/.claude/skills/dev-cache-cleanup" || exit 1
fi

if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
  print -r -- "Add this directory to PATH: $HOME/.local/bin"
fi
