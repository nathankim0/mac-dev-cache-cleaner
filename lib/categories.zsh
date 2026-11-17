#!/bin/zsh

emulate -L zsh
setopt extended_glob pipe_fail

devclean_plan_path() {
  local output_file="$1"
  local category="$2"
  local state="$3"
  local target_path="$4"
  local allowed_root="$5"
  local action="${6:-path}"
  [[ -e "$target_path" && ! -L "$target_path" ]] || return 0
  devclean_path_is_recordable "$target_path" || return 0
  local size identity
  if ! size="$(devclean_size_kb "$target_path")" || [[ "$size" != <-> ]]; then
    size=0; state=unmeasured; action=skip
  fi
  identity="$(devclean_identity "$target_path")"
  [[ -n "$identity" ]] || return 0
  /usr/bin/printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$category" "$state" "$size" "$target_path" "$allowed_root" "$identity" "$action" >> "$output_file"
}

devclean_plan_shared_caches() {
  local output_file="$1" cache_path
  while IFS= read -r cache_path; do
    devclean_plan_path "$output_file" "shared" "rebuildable" "$cache_path" "${HOME:A}"
  done < <(python3 -B "$DEVCLEAN_LIB_DIR/inventory.py" shared-paths)
}

devclean_shorebird_current_revision() {
  if [[ -n "${DEVCLEAN_SHOREBIRD_REVISION:-}" ]]; then
    print -r -- "$DEVCLEAN_SHOREBIRD_REVISION"
    return 0
  fi
  devclean_command_exists shorebird || return 1
  shorebird --version 2>/dev/null | /usr/bin/awk '/Flutter .* revision / { print $NF; exit }'
}

devclean_plan_shorebird() {
  local output_file="$1"
  local cache_root="$HOME/.shorebird/bin/cache/flutter"
  [[ -d "$cache_root" ]] || return 0
  local current_revision
  current_revision="$(devclean_shorebird_current_revision || true)"
  if [[ -z "$current_revision" ]]; then
    devclean_warn "could not resolve the active Shorebird Flutter revision; skipping Shorebird cleanup"
    return 0
  fi
  local revision_dir
  for revision_dir in "$cache_root"/*(N/); do
    [[ "${revision_dir:t}" == "$current_revision" ]] && continue
    devclean_plan_path "$output_file" "shorebird" "stale-revision" "$revision_dir" "$cache_root"
  done
}

devclean_plan_xcode() {
  local output_file="$1"
  local cache_root="$HOME/Library/Developer/Xcode/DerivedData" cache_dir
  # Keep a running app's cache without retaining every unrelated project's output.
  for cache_dir in "$cache_root"/*(N/); do
    devclean_plan_path "$output_file" "xcode" "rebuildable" "$cache_dir" "$cache_root"
  done
}

devclean_android_sdk_root() {
  local sdk_root="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
  [[ -d "$sdk_root" ]] || return 1
  print -r -- "${sdk_root:A}"
}

devclean_android_tool() {
  local tool_name="$1"
  local sdk_root="$2"
  local discovered
  discovered="$(command -v "$tool_name" 2>/dev/null || true)"
  [[ -n "$discovered" ]] && { print -r -- "$discovered"; return 0; }
  case "$tool_name" in
    adb)
      [[ -x "$sdk_root/platform-tools/adb" ]] && print -r -- "$sdk_root/platform-tools/adb"
      ;;
    sdkmanager)
      if [[ -x "$sdk_root/cmdline-tools/latest/bin/sdkmanager" ]]; then
        print -r -- "$sdk_root/cmdline-tools/latest/bin/sdkmanager"
      else
        local candidate
        for candidate in "$sdk_root"/cmdline-tools/*/bin/sdkmanager(N-.); do
          print -r -- "$candidate"
          return 0
        done
      fi
      ;;
  esac
}

devclean_android_required_images() {
  local avd_root="$HOME/.android/avd"
  [[ -d "$avd_root" ]] || return 0
  local config image_path
  for config in "$avd_root"/*.avd/config.ini(N); do
    image_path="$(/usr/bin/awk -F= '/^image\.sysdir\.1=/ { print $2; exit }' "$config")"
    [[ -n "$image_path" ]] && print -r -- "${image_path%/}"
  done
}

devclean_flutter_ndk_versions() {
  local flutter_bin flutter_root plugin_file
  flutter_bin="$(command -v flutter 2>/dev/null || true)"
  if [[ -n "$flutter_bin" ]]; then
    flutter_bin="${flutter_bin:A}"
    flutter_root="${flutter_bin:h:h}"
    for plugin_file in "$flutter_root"/packages/flutter_tools/gradle/src/main/kotlin/*.kt(N); do
      /usr/bin/sed -nE 's/.*ndkVersion[^\"]*\"([0-9.]+)\".*/\1/p' "$plugin_file"
    done
  fi
  for plugin_file in "$HOME"/.shorebird/bin/cache/flutter/*/packages/flutter_tools/gradle/src/main/kotlin/*.kt(N); do
    /usr/bin/sed -nE 's/.*ndkVersion[^\"]*\"([0-9.]+)\".*/\1/p' "$plugin_file"
  done
}

devclean_project_ndk_versions() {
  local scan_root gradle_file
  for scan_root in "${DEVCLEAN_SCAN_ROOTS[@]}"; do
    while IFS= read -r gradle_file; do
      /usr/bin/sed -nE 's/.*ndkVersion[^\"]*\"([0-9.]+)\".*/\1/p' "$gradle_file"
    done < <(/usr/bin/find "$scan_root" -maxdepth "${DEVCLEAN_MAX_DEPTH:-6}" \
      \( -name .git -o -name node_modules -o -name build -o -name Library -o -name .Trash \) -prune -o \
      -type f \( -name build.gradle -o -name build.gradle.kts \) -print 2>/dev/null)
  done
}

devclean_plan_android() {
  local output_file="$1"
  local sdk_root
  sdk_root="$(devclean_android_sdk_root || true)"
  [[ -n "$sdk_root" ]] || { devclean_warn "Android SDK not found; skipping"; return 0; }

  typeset -A keep_images keep_ndks
  local required image_dir relative api newest_api=0 version ndk_dir newest_ndk=""
  while IFS= read -r required; do
    [[ -n "$required" ]] && keep_images[$required]=1
  done < <(devclean_android_required_images)

  for image_dir in "$sdk_root"/system-images/android-*/*/*(N/); do
    relative="${image_dir#$sdk_root/system-images/}"
    api="${${relative%%/*}#android-}"
    [[ "$api" == <-> && "$api" -gt "$newest_api" ]] && newest_api="$api"
  done
  for image_dir in "$sdk_root"/system-images/android-*/*/*(N/); do
    relative="${image_dir#$sdk_root/system-images/}"
    api="${${relative%%/*}#android-}"
    [[ "$api" == "$newest_api" ]] && keep_images[$relative]=1
  done

  for ndk_dir in "$sdk_root"/ndk/*(N/); do
    version="${ndk_dir:t}"
    if [[ -z "$newest_ndk" || "$version" > "$newest_ndk" ]]; then
      newest_ndk="$version"
    fi
  done
  [[ -n "$newest_ndk" ]] && keep_ndks[$newest_ndk]=1
  while IFS= read -r version; do
    [[ -n "$version" ]] && keep_ndks[$version]=1
  done < <({ devclean_project_ndk_versions; devclean_flutter_ndk_versions; } | /usr/bin/sort -u)

  for image_dir in "$sdk_root"/system-images/android-*/*/*(N/); do
    relative="${image_dir#$sdk_root/system-images/}"
    [[ -n "${keep_images[$relative]-}" ]] && continue
    local package_id="system-images;${relative//\//;}"
    devclean_plan_path "$output_file" "android-sdk" "unused-image" "$image_dir" "$sdk_root" "sdkmanager:$package_id"
  done
  for ndk_dir in "$sdk_root"/ndk/*(N/); do
    version="${ndk_dir:t}"
    [[ -n "${keep_ndks[$version]-}" ]] && continue
    devclean_plan_path "$output_file" "android-sdk" "unused-ndk" "$ndk_dir" "$sdk_root" "sdkmanager:ndk;$version"
  done
}

devclean_plan_android_avd_data() {
  local output_file="$1"
  shift
  local avd_root="${HOME:A}/.android/avd" avd_dir name info size fingerprint state action sdk_root adb_bin
  sdk_root="$(devclean_android_sdk_root || true)"
  adb_bin="$(devclean_android_tool adb "$sdk_root")"
  for avd_dir in "$avd_root"/*.avd(N/); do
    name="${${avd_dir:t}%.avd}"
    (( $# == 0 )) || (( ${argv[(Ie)$name]} )) || continue
    [[ ! -L "$avd_dir" ]] && devclean_path_is_recordable "$avd_dir" || continue
    info="$(python3 -B "$DEVCLEAN_LIB_DIR/inventory.py" avd-state "$avd_dir")" || continue
    IFS=$'\t' read -r size fingerprint <<< "$info"
    state="inactive device data"; action=wipe-avd
    if ! devclean_avd_inactive "$name" "$adb_bin"; then
      state="active or unknown"; action=skip
    elif (( size == 0 )); then
      state="no allocated user data"; action=skip
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' android-avd "$state" "$size" "$avd_dir" "$avd_root" \
      "$(devclean_identity "$avd_dir")" "$action" "$fingerprint" >> "$output_file"
  done
}

devclean_plan_colima() {
  local output_file="$1" inspect_stopped="$2"
  shift 2
  [[ -d "$HOME/.colima" && ! -L "$HOME/.colima" ]] && devclean_command_exists colima || return 0
  python3 -B "$DEVCLEAN_LIB_DIR/colima.py" plan "$inspect_stopped" "$@" >> "$output_file"
}

devclean_plan_temp() {
  local output_file="$1" age_days="$2" temp_root="$3"
  python3 -B "$DEVCLEAN_LIB_DIR/inventory.py" temp-root "$temp_root" || {
    devclean_warn "refusing unexpected temporary root: $temp_root"
    return 1
  }
  python3 -B "$DEVCLEAN_LIB_DIR/inventory.py" temp "$temp_root" "$age_days" >> "$output_file"
}

devclean_avd_inactive() {
  local avd_name="$1" adb_bin="$2" devices serial state running_name
  [[ -n "$adb_bin" ]] || return 1
  devices="$("$adb_bin" devices 2>/dev/null)" || return 1
  while IFS=$' \t' read -r serial state; do
    [[ "$serial" == emulator-* ]] || continue
    [[ "$state" == device ]] || return 1
    running_name="$("$adb_bin" -s "$serial" shell getprop ro.boot.qemu.avd_name 2>/dev/null)" || return 1
    [[ -n "$running_name" && "$running_name" != "$avd_name" ]] || return 1
  done <<< "$devices"
}

devclean_wipe_avd() {
  local avd_dir="$1"
  local avd_root="$2"
  local expected_identity="$3" expected_state="$4"
  devclean_validate_delete_target "$avd_dir" "$avd_root" || return 2
  [[ "$avd_root" == "${HOME:A}/.android/avd" && "${avd_dir:h}" == "$avd_root" && "$avd_dir" == *.avd ]] || return 2
  [[ "$(devclean_identity "$avd_dir")" == "$expected_identity" ]] || return 2
  local sdk_root adb_bin
  sdk_root="$(devclean_android_sdk_root || true)"
  adb_bin="$(devclean_android_tool adb "$sdk_root")"
  if ! devclean_avd_inactive "${${avd_dir:t}%.avd}" "$adb_bin" || devclean_target_is_open "$avd_dir"; then
    devclean_warn "AVD is active or its status is unknown; skipped: ${avd_dir:t}"
    return 2
  fi
  local info state_path
  info="$(python3 -B "$DEVCLEAN_LIB_DIR/inventory.py" avd-state "$avd_dir")" || return 2
  if [[ "${info#*$'\t'}" != "$expected_state" ]]; then
    devclean_warn "AVD data changed since review; skipped: ${avd_dir:t}"
    return 2
  fi
  (( DEVCLEAN_DRY_RUN )) && return 0
  while IFS= read -r state_path; do
    [[ -e "$state_path" && ! -L "$state_path" ]] || continue
    # SAFE: each state file is an exact child of the revalidated AVD directory.
    /usr/bin/find "$state_path" -depth -delete || return 1
  done < <(python3 -B "$DEVCLEAN_LIB_DIR/inventory.py" avd-paths "$avd_dir")
  devclean_log_operation "WIPED" "android-avd" "$avd_dir" "user-data"
}

devclean_apply_android_package() {
  local target_path="$1"
  local sdk_root="$2"
  local expected_identity="$3"
  local package_id="$4"
  devclean_validate_delete_target "$target_path" "$sdk_root" || return 1
  [[ "$(devclean_identity "$target_path")" == "$expected_identity" ]] || return 1
  (( DEVCLEAN_DRY_RUN )) && return 0
  local adb_bin devices
  adb_bin="$(devclean_android_tool adb "$sdk_root")"
  if [[ -z "$adb_bin" ]] || ! devices="$("$adb_bin" devices 2>/dev/null)" || /usr/bin/grep -q '^emulator-' <<< "$devices"; then
    devclean_warn "an Android emulator is active or its status is unknown; skipped SDK package: $package_id"
    return 2
  fi
  if [[ "${DEVCLEAN_TEST_MODE:-0}" == "1" ]]; then
    devclean_delete_target "android-sdk" "$target_path" "$sdk_root" "$expected_identity"
    return
  fi
  local sdkmanager_bin
  sdkmanager_bin="$(devclean_android_tool sdkmanager "$sdk_root")"
  [[ -n "$sdkmanager_bin" ]] || { devclean_warn "sdkmanager not found; skipped $package_id"; return 1; }
  "$sdkmanager_bin" "--sdk_root=$sdk_root" --uninstall "$package_id"
}

devclean_apply_colima() {
  local profile_path="$1" root="$2" expected_identity="$3" profile="$4" metadata="$5"
  [[ "$root" == "${HOME:A}/.colima" && "$profile_path" == "$root/$profile" ]] || return 2
  devclean_validate_delete_target "$profile_path" "$root" || return 2
  [[ "$(devclean_identity "$profile_path")" == "$expected_identity" ]] || return 2
  (( DEVCLEAN_DRY_RUN )) && return 0
  python3 -B "$DEVCLEAN_LIB_DIR/colima.py" prune "$profile" "$metadata" || return $?
  devclean_log_operation "PRUNED" "colima" "$profile_path" "volumes-preserved"
}
