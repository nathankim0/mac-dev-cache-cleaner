#!/bin/zsh

emulate -L zsh
setopt pipe_fail

typeset repo_dir="${0:A:h:h}"
typeset cli="$repo_dir/bin/clear-dev-caches"
typeset fixture_root
fixture_root="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/devclean-tests.XXXXXX")" || exit 1
fixture_root="${fixture_root:A}"
typeset fixture_home="$fixture_root/home"
integer passed=0
integer failed=0

cleanup() {
  [[ -d "$fixture_root" && "$fixture_root" == */devclean-tests.* ]] || return 0
  # SAFE: fixture_root was created by mktemp above and is constrained by basename.
  /usr/bin/find "$fixture_root" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT INT TERM

pass() {
  print -r -- "ok - $1"
  (( passed += 1 ))
}

fail() {
  print -u2 -r -- "not ok - $1"
  (( failed += 1 ))
}

assert_contains() {
  local name="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass "$name"
  else
    fail "$name (missing: $needle)"
  fi
}

assert_not_contains() {
  local name="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    pass "$name"
  else
    fail "$name (unexpected: $needle)"
  fi
}

assert_exists() {
  local name="$1" target_path="$2"
  if [[ -e "$target_path" ]]; then
    pass "$name"
  else
    fail "$name (missing: $target_path)"
  fi
}

assert_missing() {
  local name="$1" target_path="$2"
  if [[ ! -e "$target_path" ]]; then
    pass "$name"
  else
    fail "$name (still exists: $target_path)"
  fi
}

/bin/mkdir -p \
  "$fixture_home/work/app/node_modules/pkg" \
  "$fixture_home/work/app/build/output" \
  "$fixture_home/loose/node_modules/pkg" \
  "$fixture_home/.npm/_npx/tool/node_modules/pkg"
print -r -- '{"name":"fixture"}' > "$fixture_home/work/app/package.json"
print -r -- 'cache' > "$fixture_home/work/app/node_modules/pkg/data"
print -r -- 'cache' > "$fixture_home/work/app/build/output/data"
print -r -- 'keep' > "$fixture_home/loose/node_modules/pkg/data"
print -r -- '{"name":"tool-cache"}' > "$fixture_home/.npm/_npx/tool/package.json"
print -r -- 'keep' > "$fixture_home/.npm/_npx/tool/node_modules/pkg/data"

typeset output
output="$(HOME="$fixture_home" "$cli" scan --root "$fixture_home" --projects 2>&1)"
assert_contains "discovers node_modules below a project marker" "$output" "$fixture_home/work/app/node_modules"
assert_contains "discovers build output below a project marker" "$output" "$fixture_home/work/app/build"
assert_not_contains "ignores same-named folders outside projects" "$output" "$fixture_home/loose/node_modules"
assert_not_contains "prunes hidden global tool caches from project discovery" "$output" "$fixture_home/.npm"
assert_contains "recent projects are scan-only by default" "$output" "recent (skip)"

output="$(HOME="$fixture_home" "$cli" clean --root "$fixture_home" --projects --include-recent --permanent --yes 2>&1 || true)"
if [[ -e "$fixture_home/work/app/node_modules" || -e "$fixture_home/work/app/build" ]]; then
  print -u2 -r -- "$output"
fi
assert_missing "clean removes discovered node_modules" "$fixture_home/work/app/node_modules"
assert_missing "clean removes discovered build output" "$fixture_home/work/app/build"
assert_exists "clean preserves project source marker" "$fixture_home/work/app/package.json"
assert_exists "clean preserves unmarked lookalike directory" "$fixture_home/loose/node_modules"

/bin/mkdir -p \
  "$fixture_home/.shorebird/bin/cache/flutter/rev-current" \
  "$fixture_home/.shorebird/bin/cache/flutter/rev-old"
output="$(HOME="$fixture_home" DEVCLEAN_SHOREBIRD_REVISION=rev-current "$cli" scan --shorebird 2>&1)"
assert_contains "Shorebird scan finds an inactive revision" "$output" "rev-old"
assert_not_contains "Shorebird scan preserves the active revision" "$output" "rev-current"

typeset sdk="$fixture_home/Library/Android/sdk"
/bin/mkdir -p \
  "$sdk/system-images/android-35/google_apis/arm64-v8a" \
  "$sdk/system-images/android-36/google_apis_playstore/arm64-v8a" \
  "$sdk/ndk/25.1.0" \
  "$sdk/ndk/28.2.0" \
  "$fixture_home/.android/avd/pixel.avd" \
  "$fixture_home/work/mobile/android/app"
print -r -- 'image.sysdir.1=system-images/android-36/google_apis_playstore/arm64-v8a/' \
  > "$fixture_home/.android/avd/pixel.avd/config.ini"
print -r -- 'android { ndkVersion = "28.2.0" }' \
  > "$fixture_home/work/mobile/android/app/build.gradle"
output="$(HOME="$fixture_home" ANDROID_SDK_ROOT="$sdk" "$cli" scan --android --root "$fixture_home/work" 2>&1)"
assert_contains "Android scan finds an older system image" "$output" "android-35"
assert_contains "Android scan finds an unused older NDK" "$output" "25.1.0"
assert_not_contains "Android scan preserves an AVD image" "$output" "android-36"
assert_not_contains "Android scan preserves a referenced NDK" "$output" "28.2.0"

/bin/mkdir -p "$fixture_home/Documents/cache" "$fixture_home/work/guarded/.git/cache"
if HOME="$fixture_home" zsh -c \
  'source "$1/lib/core.zsh"; devclean_validate_delete_target "$HOME/Documents/cache" "$HOME"' zsh "$repo_dir"; then
  fail "guard rejects Documents"
else
  pass "guard rejects Documents"
fi
if HOME="$fixture_home" zsh -c \
  'source "$1/lib/core.zsh"; devclean_validate_delete_target "$HOME/work/guarded/.git/cache" "$HOME/work"' zsh "$repo_dir"; then
  fail "guard rejects Git metadata"
else
  pass "guard rejects Git metadata"
fi

/bin/mkdir -p "$fixture_home/work/open-project/node_modules"
print -r -- '{}' > "$fixture_home/work/open-project/package.json"
print -r -- 'keep' > "$fixture_home/work/open-project/node_modules/data"
typeset open_target="$fixture_home/work/open-project/node_modules"
typeset open_identity
open_identity="$(/usr/bin/stat -f '%d:%i:%m' "$open_target")"
if HOME="$fixture_home" DEVCLEAN_TEST_OPEN_PATHS="$open_target" zsh -c \
  'source "$1/lib/core.zsh"; DEVCLEAN_DRY_RUN=0; DEVCLEAN_DELETE_MODE=permanent; devclean_delete_target projects "$2" "$3" "$4"' \
  zsh "$repo_dir" "$open_target" "$fixture_home/work" "$open_identity" >/dev/null 2>&1; then
  fail "mutation sink skips an in-use target"
else
  assert_exists "mutation sink skips an in-use target" "$open_target"
fi

if HOME="$fixture_home" zsh -c \
  'source "$1/lib/core.zsh"; DEVCLEAN_DRY_RUN=0; DEVCLEAN_DELETE_MODE=permanent; devclean_delete_target projects "$2" "$3" changed-identity' \
  zsh "$repo_dir" "$open_target" "$fixture_home/work" >/dev/null 2>&1; then
  fail "mutation sink skips a target changed after scan"
else
  assert_exists "mutation sink skips a target changed after scan" "$open_target"
fi

/bin/mkdir -p "$fixture_home/.Trash/sample"
output="$(HOME="$fixture_home" "$cli" trash-status 2>&1)"
assert_contains "Trash status is read-only and reports contents" "$output" "1 top-level items"

print -r -- ""
print -r -- "$passed passed, $failed failed"
(( failed == 0 ))
