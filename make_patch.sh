#!/usr/bin/env bash
# Patch authoring helper for this repo.
#
#   ./make_patch.sh open   <target>            decode into unpacked/<base>_work/ and snapshot it
#   ./make_patch.sh diff   <target> [out.patch] write the patch from your edits
#   ./make_patch.sh verify <target> [out.patch] fresh decode + git apply --check
#   ./make_patch.sh reset  <target>            throw away edits, back to pristine
#   ./make_patch.sh clean  <target>            delete the work dir
#
# Layout: apks/ inputs, patches/ patch files, unpacked/ work dirs.
# <target> is a bare name (e.g. SecSettings.apk); the default patch name is
# patches/<base>_out.patch, matching run_local.sh / apply_patches.sh.
#
# The decode flags here MUST stay identical to apply_patches.sh, otherwise the
# generated patch will not apply during the build.
set -e

APKS_DIR="apks"
PATCHES_DIR="patches"
UNPACKED_DIR="unpacked"
FRAMEWORK_DIR="apktool_frameworks"

CMD="$1"; INPUT="$2"
[ -n "$CMD" ] && [ -n "$INPUT" ] || { sed -n '2,10p' "$0" | sed 's/^# \?//'; exit 1; }

BASE="${INPUT%.*}"
INPUT_FILE="$APKS_DIR/$INPUT"
WORK="$UNPACKED_DIR/${BASE}_work"
PATCH_OUT="${3:-$PATCHES_DIR/${BASE}_out.patch}"

APKTOOL="java -jar apktool.jar"
[ -f apktool.jar ] || APKTOOL="apktool"

decode_to() {  # decode_to <destdir>
  rm -rf "$1"
  $APKTOOL d --no-debug-info -f -p "$FRAMEWORK_DIR" -o "$1" "$INPUT_FILE"
}

ensure_framework() {
  if [ ! -f "$FRAMEWORK_DIR/1.apk" ]; then
    [ -f "$APKS_DIR/framework-res.apk" ] || { echo "[!] $APKS_DIR/framework-res.apk not found, cannot install framework"; exit 1; }
    echo "[*] Installing $APKS_DIR/framework-res.apk -> $FRAMEWORK_DIR"
    mkdir -p "$FRAMEWORK_DIR"
    $APKTOOL if "$APKS_DIR/framework-res.apk" -p "$FRAMEWORK_DIR"
  fi
}

case "$CMD" in
  open)
    [ -f "$INPUT_FILE" ] || { echo "[!] $INPUT_FILE not found"; exit 1; }
    ensure_framework
    mkdir -p "$UNPACKED_DIR"
    echo "[*] Decoding $INPUT_FILE -> $WORK"
    decode_to "$WORK"
    # Snapshot the pristine decode so `diff` can show only your edits.
    git -C "$WORK" init -q
    printf 'build/\ndist/\n.DS_Store\n' > "$WORK/.git/info/exclude"
    git -C "$WORK" add -A
    git -C "$WORK" -c user.name=apktool -c user.email=apktool@local \
        commit -qm "pristine decode of $INPUT"
    echo "[*] Ready. Edit files under $WORK/, then: ./make_patch.sh diff $INPUT"
    ;;

  diff)
    [ -d "$WORK/.git" ] || { echo "[!] no snapshot; run: ./make_patch.sh open $INPUT"; exit 1; }
    mkdir -p "$(dirname "$PATCH_OUT")"
    git -C "$WORK" add -A
    git -C "$WORK" diff --cached --binary > "$PATCH_OUT"
    if [ ! -s "$PATCH_OUT" ]; then
      echo "[!] No changes in $WORK — patch is empty."; rm -f "$PATCH_OUT"; exit 1
    fi
    echo "[*] Wrote $PATCH_OUT"
    git -C "$WORK" diff --cached --stat
    ;;

  verify)
    [ -f "$PATCH_OUT" ] || { echo "[!] $PATCH_OUT not found"; exit 1; }
    ensure_framework
    mkdir -p "$UNPACKED_DIR"
    TMP="$UNPACKED_DIR/${BASE}_verify"
    echo "[*] Fresh decode -> $TMP"
    decode_to "$TMP"
    if LC_ALL=C git apply --directory="$TMP" --unsafe-paths --check -v "$PATCH_OUT"; then
      echo "[*] OK: $PATCH_OUT applies cleanly to a fresh decode of $INPUT"
      rm -rf "$TMP"
    else
      echo "[!] FAILED — $TMP left in place for inspection"; exit 1
    fi
    ;;

  reset)
    [ -d "$WORK/.git" ] || { echo "[!] no snapshot for $INPUT"; exit 1; }
    git -C "$WORK" reset -q --hard HEAD
    git -C "$WORK" clean -qfd
    echo "[*] $WORK back to pristine"
    ;;

  clean)
    rm -rf "$WORK" "$UNPACKED_DIR/${BASE}_verify"
    echo "[*] removed $WORK/"
    ;;

  *) echo "[!] unknown command: $CMD"; exit 1 ;;
esac
