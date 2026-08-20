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
  size="$(devclean_size_kb "$target_path")"
  identity="$(devclean_identity "$target_path")"
  [[ -n "$identity" ]] || return 0
  /usr/bin/printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$category" "$state" "$size" "$target_path" "$allowed_root" "$identity" "$action" >> "$output_file"
}

devclean_plan_shared_caches() {
  local output_file="$1"
  local cache_path
  for cache_path in \
    "$HOME/.gradle/caches" \
    "$HOME/.gradle/.tmp" \
    "$HOME/.npm/_cacache" \
    "$HOME/.yarn/cache" \
    "$HOME/.pnpm-store" \
    "$HOME/.bun/install/cache" \
    "$HOME/Library/Caches/CocoaPods" \
    "$HOME/Library/Caches/ms-playwright" \
    "$HOME/Library/Caches/node-gyp" \
    "$HOME/Library/Caches/Homebrew"; do
    devclean_plan_path "$output_file" "shared" "rebuildable" "$cache_path" "$HOME"
  done
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
  devclean_plan_path "$output_file" "xcode" "rebuildable" \
    "$HOME/Library/Developer/Xcode/DerivedData" "$HOME/Library/Developer/Xcode"
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
  local avd_root="$HOME/.android/avd"
  local avd_dir
  for avd_dir in "$avd_root"/*.avd(N/); do
    devclean_plan_path "$output_file" "android-avd" "device-data" "$avd_dir" "$avd_root" "wipe-avd"
  done
}

devclean_plan_colima() {
  local output_file="$1"
  local colima_root="$HOME/.colima"
  devclean_command_exists colima || return 0
  devclean_plan_path "$output_file" "colima" "preserve-volumes" "$colima_root" "$HOME" "colima-prune"
}

devclean_plan_temp() {
  local output_file="$1"
  local age_days="$2"
  local temp_root="${TMPDIR:-}"
  [[ -n "$temp_root" && -d "$temp_root" && ! -L "$temp_root" ]] || return 0
  temp_root="${temp_root:A}"
  [[ "$temp_root" == /private/var/folders/*/T(|/) ]] || {
    devclean_warn "refusing unexpected TMPDIR: $temp_root"
    return 0
  }
  local candidate
  while IFS= read -r candidate; do
    [[ -e "$candidate" && ! -L "$candidate" ]] || continue
    devclean_plan_path "$output_file" "temp" "older-than-${age_days}d" "$candidate" "$temp_root"
  done < <(/usr/bin/find "$temp_root" -mindepth 1 -maxdepth 1 -mtime "+$age_days" -user "$(/usr/bin/id -un)" -print 2>/dev/null)
}

devclean_wipe_avd() {
  local avd_dir="$1"
  local avd_root="$2"
  local expected_identity="$3"
  devclean_validate_delete_target "$avd_dir" "$avd_root" || return 1
  [[ "$(devclean_identity "$avd_dir")" == "$expected_identity" ]] || return 1
  local sdk_root adb_bin
  sdk_root="$(devclean_android_sdk_root || true)"
  adb_bin="$(devclean_android_tool adb "$sdk_root")"
  if [[ -n "$adb_bin" ]] && "$adb_bin" devices 2>/dev/null | /usr/bin/tail -n +2 | /usr/bin/grep -q '^emulator-'; then
    devclean_warn "an Android device/emulator is active; skipped AVD wipe: ${avd_dir:t}"
    return 1
  fi
  (( DEVCLEAN_DRY_RUN )) && return 0
  local state_path
  for state_path in \
    "$avd_dir/userdata-qemu.img.qcow2" "$avd_dir/snapshots" "$avd_dir/sdcard.img" \
    "$avd_dir/encryptionkey.img.qcow2" "$avd_dir/cache.img.qcow2" "$avd_dir/cache.img" \
    "$avd_dir/bootcompleted.ini" "$avd_dir/read-snapshot.txt"; do
    [[ -e "$state_path" ]] || continue
    # SAFE: every state file is an exact child of a revalidated *.avd directory; config.ini and base images are excluded.
    /usr/bin/find "$state_path" -depth -delete || return 1
  done
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
  local adb_bin
  adb_bin="$(devclean_android_tool adb "$sdk_root")"
  if [[ -n "$adb_bin" ]] && "$adb_bin" devices 2>/dev/null | /usr/bin/tail -n +2 | /usr/bin/grep -q '^emulator-'; then
    devclean_warn "an Android emulator is active; skipped SDK package: $package_id"
    return 1
  fi
  if [[ "${DEVCLEAN_TEST_MODE:-0}" == "1" ]]; then
    devclean_delete_target "android-sdk" "$target_path" "$sdk_root" "$expected_identity"
    return
  fi
  local sdkmanager_bin
  sdkmanager_bin="$(devclean_android_tool sdkmanager "$sdk_root")"
  [[ -n "$sdkmanager_bin" ]] || { devclean_warn "sdkmanager not found; skipped $package_id"; return 1; }
  "$sdkmanager_bin" --uninstall "$package_id"
}

devclean_apply_colima() {
  local colima_root="$1"
  local expected_identity="$2"
  devclean_validate_delete_target "$colima_root" "$HOME" || return 1
  [[ "$(devclean_identity "$colima_root")" == "$expected_identity" ]] || return 1
  (( DEVCLEAN_DRY_RUN )) && return 0
  devclean_command_exists colima && devclean_command_exists docker || return 1

  local was_running=0
  colima status >/dev/null 2>&1 && was_running=1
  if (( ! was_running )); then
    colima stop --force >/dev/null 2>&1 || true
    colima start || return 1
  fi
  docker system prune --all --force || return 1
  colima ssh -- sudo fstrim -av >/dev/null 2>&1 || devclean_warn "Colima trim failed; Docker data was still pruned"
  (( was_running )) || colima stop
  devclean_log_operation "PRUNED" "colima" "$colima_root" "volumes-preserved"
}
