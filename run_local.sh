#!/usr/bin/env bash
# Local equivalent of the old CI patch job.
# Usage: ./run_local.sh                 -> build every target
#        ./run_local.sh SecSettings.apk -> build one target
#
# Layout: apks/ inputs, patches/ patch files, unpacked/ work dirs, dist/ outputs.
# All verbose apktool/git output goes to the log file; the terminal shows only
# concise English status lines.
set -e

APKS_DIR="apks"
PATCHES_DIR="patches"
LOG="build.log"

# Terminal status (stdout) vs. full log (file).
say() { printf '%s\n' "$*"; }
: > "$LOG"   # truncate log at start

BT="$(ls -d "$HOME"/Library/Android/sdk/build-tools/* 2>/dev/null | sort -V | tail -1)"
[ -n "$BT" ] || { echo "[!] Android SDK build-tools not found"; exit 1; }
export PATH="$BT:$PATH"

command -v zipalign  >/dev/null || { echo "[!] zipalign missing in $BT";  exit 1; }
command -v apksigner >/dev/null || { echo "[!] apksigner missing in $BT"; exit 1; }

say "Preparing (log: $LOG)..."
{
  # 1. apktool (same version as CI)
  if [ ! -f apktool.jar ]; then
    echo "[*] Downloading apktool 3.0.2"
    curl -sSfL -o apktool.jar \
      https://github.com/iBotPeaches/Apktool/releases/download/v3.0.2/apktool_3.0.2.jar
  fi

  # 2. AOSP platform keys
  for f in platform.x509.pem platform.pk8; do
    [ -f "$f" ] || curl -sSfL -O \
      "https://raw.githubusercontent.com/aosp-mirror/platform_build/main/target/product/security/$f"
  done

  # 3. Install framework-res
  echo "[*] Installing $APKS_DIR/framework-res.apk"
  mkdir -p apktool_frameworks
  java -jar apktool.jar if "$APKS_DIR/framework-res.apk" -p apktool_frameworks

  # 4. Reassemble split files (parts live in apks/)
  for first in "$APKS_DIR"/*.part_aa; do
    [ -e "$first" ] || continue
    base="${first%.part_aa}"                 # e.g. apks/SecSettings.apk
    echo "[*] Merging $base"
    cat "$base".part_* > "$base"
    if [ -f "$base.sha256" ]; then
      ( cd "$(dirname "$base")" && shasum -a 256 -c "$(basename "$base").sha256" )
    fi
  done
} >> "$LOG" 2>&1

# 5. Targets (mirrors the old CI matrix)
patches_for() {
  case "$1" in
    framework.jar)             echo "framework_out.patch" ;;
    samsungkeystoreutils.jar)  echo "samsungkeystoreutils_out.patch" ;;
    services.jar)              echo "services_out.patch" ;;
    SecSettings.apk)           echo "SecSettings_out.patch" ;;
    HoneyBoard.apk)            echo "HoneyBoard_out.patch" ;;
    knoxsdk.jar)               echo "knoxsdk_out.patch" ;;
    *) return 1 ;;
  esac
}

run_target() {
  local t="$1" p
  p="$(patches_for "$t")" || { say "Skipping $t (unknown target)"; return 0; }
  for f in $p; do
    [ -f "$PATCHES_DIR/$f" ] || { say "Skipping $t (no patch)"; return 0; }
  done
  say "Patching $t..."
  if ./apply_patches.sh "$t" $p >> "$LOG" 2>&1; then
    say "Patched  $t"
  else
    say "FAILED   $t (see $LOG)"
    return 1
  fi
}

chmod +x apply_patches.sh
rc=0
if [ -n "$1" ]; then
  run_target "$1" || rc=1
else
  for t in framework.jar samsungkeystoreutils.jar services.jar SecSettings.apk HoneyBoard.apk knoxsdk.jar; do
    run_target "$t" || rc=1
  done
fi

say ""
say "Output:"
ls -1 dist/*_patched.* 2>/dev/null | sed 's/^/  /' || say "  (none)"
[ "$rc" -eq 0 ] && say "Done." || say "Done with errors (see $LOG)."
exit "$rc"
