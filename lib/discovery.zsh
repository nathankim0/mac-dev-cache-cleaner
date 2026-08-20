#!/bin/zsh

emulate -L zsh
setopt extended_glob pipe_fail

typeset -ga DEVCLEAN_PROJECT_INDICATORS=(
  .git package.json pnpm-workspace.yaml yarn.lock pubspec.yaml Cargo.toml
  go.mod pyproject.toml requirements.txt Podfile settings.gradle settings.gradle.kts
)

typeset -ga DEVCLEAN_ARTIFACT_NAMES=(
  node_modules build .dart_tool .next dist target .turbo .pytest_cache .parcel-cache Pods
)

devclean_project_indicator_exists() {
  local dir="$1"
  local indicator
  for indicator in "${DEVCLEAN_PROJECT_INDICATORS[@]}"; do
    [[ -e "$dir/$indicator" ]] && return 0
  done
  return 1
}

devclean_find_project_root() {
  local artifact="$1"
  local scan_root="${2:A}"
  local current="${artifact:h:A}"

  while devclean_path_within "$current" "$scan_root"; do
    if devclean_project_indicator_exists "$current"; then
      print -r -- "$current"
      return 0
    fi
    [[ "$current" == "$scan_root" || "$current" == "/" ]] && break
    current="${current:h}"
  done
  return 1
}

devclean_project_is_recent() {
  local project_root="$1"
  local age_days="$2"
  local cutoff=$(( EPOCHSECONDS - age_days * 86400 ))

  if [[ -d "$project_root/.git" ]] && devclean_command_exists git; then
    local last_commit
    last_commit="$(git -C "$project_root" log -1 --format=%ct 2>/dev/null || true)"
    [[ "$last_commit" == <-> && "$last_commit" -ge "$cutoff" ]] && return 0
    [[ -n "$(git -C "$project_root" status --porcelain --untracked-files=no 2>/dev/null)" ]] && return 0
  fi

  local recent_file
  recent_file="$(/usr/bin/find "$project_root" -maxdepth 3 \
    \( -name .git -o -name node_modules -o -name build -o -name .dart_tool -o -name .next -o -name target -o -name Pods \) -prune -o \
    -type f -mtime "-$age_days" -print -quit 2>/dev/null)"
  [[ -n "$recent_file" ]]
}

devclean_artifact_is_recent() {
  local artifact="$1"
  local project_root="$2"
  local age_days="$3"
  local modified
  modified="$(/usr/bin/stat -f '%m' "$artifact" 2>/dev/null || print 0)"
  local cutoff=$(( EPOCHSECONDS - age_days * 86400 ))
  [[ "$modified" == <-> && "$modified" -ge "$cutoff" ]] && return 0
  devclean_project_is_recent "$project_root" "$age_days"
}

devclean_emit_artifacts_for_root() {
  local scan_root="${1:A}"
  local max_depth="$2"
  local age_days="$3"
  local output_file="$4"

  devclean_validate_scan_root "$scan_root" || {
    devclean_warn "skipping unsafe scan root: $scan_root"
    return 0
  }

  local candidate project_root state size identity
  while IFS= read -r candidate; do
    [[ -n "$candidate" && ! -L "$candidate" ]] || continue
    devclean_path_is_recordable "$candidate" || continue
    project_root="$(devclean_find_project_root "$candidate" "$scan_root")" || continue
    state="old"
    devclean_artifact_is_recent "$candidate" "$project_root" "$age_days" && state="recent"
    size="$(devclean_size_kb "$candidate")"
    identity="$(devclean_identity "$candidate")"
    [[ -n "$identity" ]] || continue
    /usr/bin/printf 'projects\t%s\t%s\t%s\t%s\t%s\tpath\n' \
      "$state" "$size" "$candidate" "$scan_root" "$identity" >> "$output_file"
  done < <(
    /usr/bin/find "$scan_root" -mindepth 1 -maxdepth "$max_depth" \
      -type d \( -name node_modules -o -name build -o -name .dart_tool -o -name .next \
         -o -name dist -o -name target -o -name .turbo -o -name .pytest_cache \
         -o -name .parcel-cache -o -name Pods \) -print -prune -o \
      -type d \( -name '.*' -o -name Library -o -name Applications \
         -o -name 'Virtual Machines.localized' \) -prune 2>/dev/null
  )
}

devclean_deduplicate_plan() {
  local input_file="$1"
  local output_file="$2"
  /usr/bin/awk -F '\t' '!seen[$4]++' "$input_file" > "$output_file"
}
