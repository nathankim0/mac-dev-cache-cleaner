#!/bin/zsh

emulate -L zsh
setopt extended_glob pipe_fail

devclean_emit_artifacts_for_root() {
  local scan_root="${1:A}"
  local max_depth="$2" age_days="$3" output_file="$4"
  devclean_validate_scan_root "$scan_root" || {
    devclean_warn "skipping unsafe scan root: $scan_root"
    return 0
  }
  python3 "$DEVCLEAN_LIB_DIR/inventory.py" projects "$scan_root" "$max_depth" "$age_days" "${DEVCLEAN_RELEASE_ARTIFACTS:-0}" >> "$output_file"
}

devclean_deduplicate_plan() {
  /usr/bin/awk -F '\t' '
    NR == FNR { if ($1 == "temp" && $7 == "path" && $2 != "unmeasured") whole[$4]=1; next }
    !seen[$4]++ {
      ancestor=$4
      while (sub("/[^/]+$", "", ancestor)) if (ancestor in whole) next
      print
    }
  ' "$1" "$1" > "$2"
}
