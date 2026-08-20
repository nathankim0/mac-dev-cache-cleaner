#!/bin/zsh

emulate -L zsh
setopt extended_glob pipe_fail

typeset -g DEVCLEAN_NAME="clear-dev-caches"
typeset -g DEVCLEAN_VERSION="0.1.0"
typeset -g DEVCLEAN_DELETE_MODE="trash"
typeset -g DEVCLEAN_DRY_RUN=1
typeset -g DEVCLEAN_ASSUME_YES=0
typeset -g DEVCLEAN_LOG_PATH="${XDG_STATE_HOME:-$HOME/.local/state}/mac-dev-cache-cleaner/operations.log"

devclean_info() {
  print -r -- "$*"
}

devclean_warn() {
  print -u2 -r -- "warning: $*"
}

devclean_die() {
  print -u2 -r -- "error: $*"
  return 1
}

devclean_command_exists() {
  command -v "$1" >/dev/null 2>&1
}

devclean_size_kb() {
  local target_path="$1"
  [[ -e "$target_path" ]] || { print 0; return 0; }
  /usr/bin/du -skP "$target_path" 2>/dev/null | /usr/bin/awk 'NR == 1 { print $1 + 0; exit }'
}

devclean_format_kb() {
  local kb="${1:-0}"
  /usr/bin/awk -v kb="$kb" 'BEGIN {
    if (kb >= 1048576) printf "%.2f GiB", kb / 1048576;
    else if (kb >= 1024) printf "%.1f MiB", kb / 1024;
    else printf "%d KiB", kb;
  }'
}

devclean_identity() {
  local target_path="$1"
  /usr/bin/stat -f '%d:%i:%m' "$target_path" 2>/dev/null
}

devclean_realpath() {
  local target_path="$1"
  print -r -- "${target_path:A}"
}

devclean_path_within() {
  local target_path="${1:A}"
  local root="${2:A}"
  [[ "$target_path" == "$root" || "$target_path" == "$root"/* ]]
}

devclean_validate_scan_root() {
  local root="$1"
  [[ -n "$root" && "$root" == /* ]] || return 1
  [[ -d "$root" && ! -L "$root" ]] || return 1
  root="${root:A}"
  case "$root" in
    /|/System(|/*)|/bin(|/*)|/sbin(|/*)|/usr(|/*)|/etc(|/*)|/Library(|/*)) return 1 ;;
    /private(|/*))
      local temp_root=""
      [[ -n "${TMPDIR:-}" ]] && temp_root="${TMPDIR:A}"
      [[ -n "$temp_root" && "$temp_root" == /private/var/folders/*/T(|/) ]] || return 1
      devclean_path_within "$root" "$temp_root" || return 1
      ;;
  esac
  return 0
}

devclean_validate_delete_target() {
  local target_path="$1"
  local allowed_root="$2"
  [[ -n "$target_path" && -n "$allowed_root" ]] || return 1
  [[ "$target_path" == /* && "$allowed_root" == /* ]] || return 1
  [[ "$target_path" != *$'\n'* && "$target_path" != *$'\r'* && "$target_path" != *$'\t'* ]] || return 1
  [[ -e "$target_path" && ! -L "$target_path" ]] || return 1
  [[ -d "$allowed_root" && ! -L "$allowed_root" ]] || return 1

  local resolved_path="${target_path:A}"
  local resolved_root="${allowed_root:A}"
  [[ "$resolved_path" != "$resolved_root" ]] || return 1
  devclean_path_within "$resolved_path" "$resolved_root" || return 1

  local temp_root=""
  [[ -n "${TMPDIR:-}" ]] && temp_root="${TMPDIR:A}"

  case "$resolved_path" in
    /|/System(|/*)|/bin(|/*)|/sbin(|/*)|/usr(|/*)|/etc(|/*)|/Library(|/*)|/private/var/db(|/*)) return 1 ;;
    /private(|/*))
      [[ -n "$temp_root" && "$temp_root" == /private/var/folders/*/T(|/) ]] || return 1
      devclean_path_within "$resolved_root" "$temp_root" || return 1
      ;;
  esac
  case "$resolved_path" in
    "$HOME"|"$HOME/Documents"(|/*)|"$HOME/Desktop"(|/*)|"$HOME/Pictures"(|/*)|"$HOME/Movies"(|/*)|"$HOME/Music"(|/*)) return 1 ;;
    */.git(|/*)|*/.ssh(|/*)|*/.aws(|/*)|*/.gnupg(|/*)) return 1 ;;
  esac
  return 0
}

devclean_path_is_recordable() {
  local target_path="$1"
  [[ -n "$target_path" && "$target_path" != *$'\n'* && "$target_path" != *$'\r'* && "$target_path" != *$'\t'* ]]
}

devclean_log_operation() {
  local operation_status="$1"
  local category="$2"
  local target_path="$3"
  local detail="${4:-}"
  local log_dir="${DEVCLEAN_LOG_PATH:h}"
  /bin/mkdir -p "$log_dir" 2>/dev/null || return 0
  /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
    "$(/bin/date '+%Y-%m-%dT%H:%M:%S%z')" "$operation_status" "$category" "$target_path" "$detail" \
    >> "$DEVCLEAN_LOG_PATH" 2>/dev/null || true
}

devclean_target_is_open() {
  local target_path="$1"
  if [[ -n "${DEVCLEAN_TEST_OPEN_PATHS:-}" ]]; then
    [[ ":$DEVCLEAN_TEST_OPEN_PATHS:" == *":$target_path:"* ]]
    return
  fi
  devclean_command_exists lsof || return 1
  lsof -n +D "$target_path" >/dev/null 2>&1
}

devclean_unique_trash_path() {
  local target_path="$1"
  local trash_root="$HOME/.Trash"
  local base="${target_path:t}"
  local suffix="$(/bin/date '+%Y%m%d-%H%M%S')-$$"
  print -r -- "$trash_root/${base}.devclean-$suffix"
}

devclean_delete_target() {
  local category="$1"
  local target_path="$2"
  local allowed_root="$3"
  local expected_identity="$4"

  if ! devclean_validate_delete_target "$target_path" "$allowed_root"; then
    devclean_warn "refused unsafe target: $target_path"
    devclean_log_operation "REFUSED" "$category" "$target_path" "path-validation"
    return 1
  fi

  local current_identity
  current_identity="$(devclean_identity "$target_path")"
  if [[ -z "$current_identity" || "$current_identity" != "$expected_identity" ]]; then
    devclean_warn "target changed since scan; skipped: $target_path"
    devclean_log_operation "SKIPPED" "$category" "$target_path" "identity-changed"
    return 1
  fi

  if devclean_target_is_open "$target_path"; then
    devclean_warn "target is in use; skipped: $target_path"
    devclean_log_operation "SKIPPED" "$category" "$target_path" "in-use"
    return 1
  fi

  if (( DEVCLEAN_DRY_RUN )); then
    devclean_log_operation "DRY_RUN" "$category" "$target_path" "$DEVCLEAN_DELETE_MODE"
    return 0
  fi

  if [[ "$DEVCLEAN_DELETE_MODE" == "trash" ]]; then
    if devclean_command_exists trash; then
      if trash "$target_path"; then
        devclean_log_operation "TRASHED" "$category" "$target_path"
        return 0
      fi
    fi

    local trash_target
    trash_target="$(devclean_unique_trash_path "$target_path")"
    /bin/mkdir -p "$HOME/.Trash" || return 1
    if /bin/mv "$target_path" "$trash_target"; then
      devclean_log_operation "TRASHED" "$category" "$target_path" "$trash_target"
      return 0
    fi
    devclean_log_operation "FAILED" "$category" "$target_path" "trash"
    return 1
  fi

  # SAFE: path and its physical parent were validated against an exact allowed root and identity immediately above.
  if /usr/bin/find "$target_path" -depth -delete; then
    devclean_log_operation "DELETED" "$category" "$target_path" "permanent"
    return 0
  fi
  devclean_log_operation "FAILED" "$category" "$target_path" "permanent"
  return 1
}

devclean_confirm() {
  local prompt="$1"
  (( DEVCLEAN_ASSUME_YES )) && return 0
  [[ -t 0 ]] || { devclean_warn "confirmation requires a terminal; pass --yes after reviewing scan output"; return 1; }
  local reply
  read "reply?$prompt [y/N] "
  [[ "$reply" == [yY] ]]
}

devclean_disk_free_kb() {
  /bin/df -k /System/Volumes/Data 2>/dev/null | /usr/bin/awk 'NR == 2 { print $4 + 0; exit }'
}

devclean_trash_status() {
  local trash_root="$HOME/.Trash"
  [[ -d "$trash_root" && ! -L "$trash_root" ]] || {
    devclean_info "Trash is empty or unavailable: $trash_root"
    return 0
  }
  local item_count trash_kb
  item_count="$(/usr/bin/find "$trash_root" -mindepth 1 -maxdepth 1 -print 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
  trash_kb="$(devclean_size_kb "$trash_root")"
  devclean_info "Trash: ${item_count:-0} top-level items, $(devclean_format_kb "$trash_kb")"
  if devclean_target_is_open "$trash_root"; then
    devclean_warn "one or more Trash items are in use"
    lsof -n +D "$trash_root" 2>/dev/null | /usr/bin/head -n 12 || true
    return 1
  fi
  devclean_info "No open Trash items detected."
}

devclean_empty_trash() {
  local restart_finder="${1:-0}"
  local trash_root="$HOME/.Trash"
  [[ -d "$trash_root" && ! -L "$trash_root" ]] || {
    devclean_info "Trash is already empty or unavailable."
    return 0
  }
  if devclean_target_is_open "$trash_root"; then
    devclean_warn "Trash contains an item that is in use; close the listed app or file operation first"
    lsof -n +D "$trash_root" 2>/dev/null | /usr/bin/head -n 12 || true
    return 1
  fi
  if /usr/bin/osascript -e 'tell application "Finder" to empty trash' >/dev/null; then
    devclean_log_operation "EMPTIED" "trash" "$trash_root" "finder"
    return 0
  fi
  (( restart_finder )) || {
    devclean_warn "Finder could not empty Trash; retry with 'empty-trash --restart-finder' after reviewing active file operations"
    return 1
  }
  /usr/bin/killall Finder >/dev/null 2>&1 || true
  /usr/bin/osascript -e 'tell application "Finder" to empty trash' >/dev/null || {
    devclean_warn "Trash is still busy after restarting Finder"
    return 1
  }
  devclean_log_operation "EMPTIED" "trash" "$trash_root" "finder-restarted"
}
