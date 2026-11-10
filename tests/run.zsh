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

output="$(HOME="$fixture_home" "$cli" clean --root "$fixture_home" --projects --include-recent --permanent 2>&1 || true)"
assert_contains "non-interactive cleanup requires user approval" "$output" "requires one user confirmation"
assert_exists "unapproved cleanup preserves node_modules" "$fixture_home/work/app/node_modules"
assert_exists "unapproved cleanup preserves build output" "$fixture_home/work/app/build"

output="$(HOME="$fixture_home" "$cli" clean --root "$fixture_home" --projects --include-recent --permanent --user-approved 2>&1 || true)"
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
output="$(HOME="$fixture_home" "$cli" empty-trash 2>&1 || true)"
assert_contains "non-interactive Trash empty requires user approval" "$output" "requires one user confirmation"
assert_exists "unapproved Trash empty preserves contents" "$fixture_home/.Trash/sample"

typeset fixture_temp="$fixture_root/user/T"
typeset extended_home="$fixture_temp/extended-home"
typeset temp_source="$fixture_temp/test-runs/run/source"
typeset retained_cache="$extended_home/.codex/artifacts/task/retained-build-cache"
typeset local_source="$extended_home/.local/share/load-runs/run/source"
typeset retained_artifacts="$extended_home/.codex/task-artifacts/task/retained-build-artifacts"
/bin/mkdir -p \
  "$extended_home/work" \
  "$extended_home/work/retained-build-cache/node_modules/pkg" \
  "$local_source/node_modules/pkg" \
  "$retained_cache/client/.next/cache" "$retained_cache/client/lib" \
  "$retained_artifacts/node_modules/pkg" \
  "$extended_home/.codex/artifacts/evidence/node_modules/pkg" \
  "$temp_source/node_modules/pkg" "$temp_source/web/.next/cache" \
  "$fixture_temp/test-runs/run/data" "$fixture_temp/unmarked/node_modules/pkg"
print -r -- '{}' > "$local_source/package.json"
print -r -- '{}' > "$temp_source/package.json"
print -r -- 'source' > "$retained_cache/client/lib/keep.ts"
print -r -- 'evidence' > "$extended_home/.codex/artifacts/task/result.json"
print -r -- 'test data' > "$fixture_temp/test-runs/run/data/keep.pdf"
print -r -- 'test log' > "$fixture_temp/test-runs/run/run.log"
/bin/ln -s "$fixture_home/loose/node_modules" "$temp_source/web/node_modules"

output="$(HOME="$extended_home" TMPDIR="$fixture_temp/" "$cli" scan --projects 2>&1)"
assert_contains "home scan discovers hidden local test project caches" "$output" "$local_source/node_modules"
assert_contains "home scan discovers retained caches without a manifest" "$output" "$retained_cache/client/.next"
assert_contains "home scan discovers retained task build artifacts" "$output" "$retained_artifacts/node_modules"
assert_not_contains "unmarked evidence folders are not treated as caches" "$output" "$extended_home/.codex/artifacts/evidence/node_modules"
assert_not_contains "retained cache names outside artifact storage need a project marker" "$output" "$extended_home/work/retained-build-cache/node_modules"
assert_exists "scanning retained artifacts preserves source" "$retained_cache/client/lib/keep.ts"
output="$(HOME="$extended_home" TMPDIR="$fixture_temp/" "$cli" scan --projects --root "$extended_home/work" 2>&1)"
assert_not_contains "explicit project root does not widen into hidden storage" "$output" "$retained_cache"

output="$(HOME="$extended_home" TMPDIR="$fixture_temp/" ANDROID_SDK_ROOT="$extended_home/missing-sdk" "$cli" scan --all 2>&1)"
assert_contains "all includes temporary project caches" "$output" "$temp_source/node_modules"
assert_contains "temporary recent artifacts remain scan-only" "$output" "recent (skip)"
assert_not_contains "temporary lookalikes without markers are ignored" "$output" "$fixture_temp/unmarked/node_modules"
assert_not_contains "temporary symlink artifacts are ignored" "$output" "$temp_source/web/node_modules"
assert_exists "all is read-only for temporary caches" "$temp_source/node_modules"

output="$(HOME="$extended_home" TMPDIR="$fixture_temp/" "$cli" clean --temp-projects --permanent --user-approved 2>&1)"
assert_exists "recent temporary caches are protected without override" "$temp_source/node_modules"
output="$(HOME="$extended_home" TMPDIR="$fixture_temp/" "$cli" clean --projects --temp-projects --include-recent --permanent --user-approved 2>&1)"
assert_missing "cleanup removes temporary dependency copies" "$temp_source/node_modules"
assert_missing "cleanup removes nested temporary build output" "$temp_source/web/.next"
assert_missing "cleanup removes retained build output without a manifest" "$retained_cache/client/.next"
assert_missing "cleanup removes hidden local dependency copies" "$local_source/node_modules"
assert_missing "cleanup removes retained task dependency copies" "$retained_artifacts/node_modules"
assert_exists "cleanup preserves test source" "$temp_source/package.json"
assert_exists "cleanup preserves test data" "$fixture_temp/test-runs/run/data/keep.pdf"
assert_exists "cleanup preserves test logs" "$fixture_temp/test-runs/run/run.log"
assert_exists "cleanup preserves retained source" "$retained_cache/client/lib/keep.ts"
assert_exists "cleanup preserves retained evidence" "$extended_home/.codex/artifacts/task/result.json"
assert_exists "cleanup preserves symlink destinations" "$fixture_home/loose/node_modules/pkg/data"
assert_exists "cleanup preserves unmarked temporary lookalikes" "$fixture_temp/unmarked/node_modules"

# Saved plans do not rediscover new targets and still check identities.
typeset frozen="$fixture_home/work/frozen" saved="$fixture_root/reviewed.json"
/bin/mkdir -p "$frozen/node_modules" "$frozen/.next" "$frozen/build/dist/screenshots"
print -r -- '{}' > "$frozen/package.json"
print -r -- 'user evidence' > "$frozen/build/dist/screenshots/original.png"
output="$(HOME="$fixture_home" "$cli" scan --root "$frozen" --projects --include-recent --permanent --save-plan "$saved" 2>&1)"
assert_contains "saves a reviewed plan" "$output" "Saved exact cleanup plan"
assert_contains "recognizes mixed build directories" "$output" "mixed build output preserved"
assert_exists "scan leaves approved candidates intact" "$frozen/node_modules"
/bin/mkdir -p "$frozen/dist"
/usr/bin/touch -t 200001010000 "$frozen/.next"
output="$(HOME="$fixture_home" "$cli" clean --plan "$saved" </dev/null 2>&1 || true)"
assert_contains "saved plans still require confirmation" "$output" "requires one user confirmation"
output="$(HOME="$fixture_home" "$cli" clean --plan "$saved" --trash --user-approved 2>&1 || true)"
assert_contains "saved plans reject mode overrides" "$output" "saved scope and mode"
output="$(HOME="$fixture_home" "$cli" clean --plan "$saved" --user-approved 2>&1 || true)"
assert_missing "replays the unchanged approved target" "$frozen/node_modules"
assert_exists "preserves a changed approved target" "$frozen/.next"
assert_exists "never adds a newly discovered target" "$frozen/dist"
assert_exists "preserves mixed build evidence" "$frozen/build/dist/screenshots/original.png"
assert_contains "reports skipped separately from failed" "$output" "1 succeeded, 1 skipped, 0 failed"

# Retained backups and application-specific temp roots expose only build caches.
typeset backup="$extended_home/.codex/task-backups/old/preserved-caches/web"
typeset app_temp="$extended_home/.openclaw/tmp"
/bin/mkdir -p "$backup/node_modules/pkg" "$app_temp/closed/source/.next/cache"
print -r -- 'patch' > "$backup/keep.patch"
print -r -- '{}' > "$app_temp/closed/source/package.json"
print -r -- 'db evidence' > "$app_temp/closed/keep.sqlite"
output="$(HOME="$extended_home" TMPDIR="$fixture_temp" "$cli" scan --projects 2>&1)"
assert_contains "discovers retained backup cache without a manifest" "$output" "$backup/node_modules"
assert_contains "discovers caches under an app-specific temp root" "$output" "$app_temp/closed/source/.next"
assert_not_contains "does not select test database copies in the standard scan" "$output" "$app_temp/closed/keep.sqlite"
assert_exists "retained patch is preserved" "$backup/keep.patch"

# A regular file held open by another process must be protected too.
typeset scratch="$extended_home/scratch/tmp"
/bin/mkdir -p "$scratch/empty-service" "$scratch/old-git/.git" "$scratch/old-secret/sub"
print -r -- 'old data' > "$scratch/old.log"
print -r -- 'open data' > "$scratch/open.log"
print -r -- 'do not delete' > "$scratch/old-secret/sub/.env.local"
/usr/bin/find "$scratch" -exec /usr/bin/touch -t 200001010000 {} +
exec {open_fd}< "$scratch/open.log"
output="$(HOME="$extended_home" "$cli" clean --temp --temp-root "$scratch" --permanent --user-approved 2>&1 || true)"
exec {open_fd}<&-
assert_missing "scoped old temporary file is removed" "$scratch/old.log"
assert_exists "a real open regular file is preserved" "$scratch/open.log"
assert_exists "zero-allocation temp directory is left alone" "$scratch/empty-service"
assert_exists "temporary Git metadata is protected" "$scratch/old-git/.git"
assert_exists "credentials nested in old temp data are protected" "$scratch/old-secret/sub/.env.local"

# One running emulator does not block cleanup of a separately selected stopped AVD.
typeset fake_bin="$fixture_root/mock-bin" inactive="$fixture_home/.android/avd/offline.avd"
/bin/mkdir -p "$fake_bin" "$inactive"
cat > "$fake_bin/adb" <<'SH'
#!/bin/sh
case "$1" in
  devices) printf 'List of devices attached\nemulator-5554\tdevice\n' ;;
  -s) printf 'pixel\n' ;;
  *) exit 1 ;;
esac
SH
/bin/chmod +x "$fake_bin/adb"
print -r -- 'base image' > "$inactive/config.ini"
print -r -- 'old user data' > "$inactive/userdata-qemu.img.qcow2"
print -r -- 'active user data' > "$fixture_home/.android/avd/pixel.avd/userdata-qemu.img.qcow2"
output="$(PATH="$fake_bin:$PATH" HOME="$fixture_home" "$cli" clean --avd offline --permanent --user-approved 2>&1 || true)"
assert_missing "inactive selected AVD user data is reset" "$inactive/userdata-qemu.img.qcow2"
assert_exists "inactive AVD definition survives reset" "$inactive/config.ini"
assert_exists "running AVD data is preserved" "$fixture_home/.android/avd/pixel.avd/userdata-qemu.img.qcow2"

if (( EUID != 0 )); then
  /bin/chmod 000 "$fixture_home/.Trash"
  output="$(HOME="$fixture_home" "$cli" trash-status 2>&1 || true)"
  /bin/chmod 700 "$fixture_home/.Trash"
  assert_contains "unreadable Trash is not reported empty" "$output" "Trash is unmeasured"
fi

python3 -B -m unittest discover -s "$repo_dir/tests" -p 'test_*.py' || fail "Colima fixture tests"

print -r -- ""
print -r -- "$passed passed, $failed failed"
(( failed == 0 ))
