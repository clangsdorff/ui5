#!/usr/bin/env bash

set -e

# Usage: ./apply_patches.sh <target_file> <patch_file> [additional_patches...]
#
# Layout:
#   apks/      source APK/JAR inputs (target files)
#   patches/   *.patch files
#   unpacked/  decode working dirs (transient)
#   dist/      signed *_patched.* outputs
# Target and patch arguments are bare names; the folders are resolved here.

APKS_DIR="apks"
PATCHES_DIR="patches"
UNPACKED_DIR="unpacked"
DIST_DIR="dist"

INPUT_NAME="$1"
shift

if [ -z "$INPUT_NAME" ] || [ -z "$1" ]; then
    echo "Usage: $0 <target_file> <patch_file> [additional_patches...]"
    exit 1
fi

INPUT_FILE="$APKS_DIR/$INPUT_NAME"
BASE_NAME="${INPUT_NAME%.*}"
EXT="${INPUT_NAME##*.}"
OUTPUT_DIR="$UNPACKED_DIR/${BASE_NAME}_decoded"
FINAL_FILE="$DIST_DIR/${BASE_NAME}_patched.${EXT}"
TEMP_FILE="$UNPACKED_DIR/${BASE_NAME}_temp.${EXT}"

if [ ! -f "$INPUT_FILE" ]; then
    echo "[!] Target not found: $INPUT_FILE"
    exit 1
fi

mkdir -p "$UNPACKED_DIR" "$DIST_DIR"

APKTOOL_CMD="apktool"
if [ -f "apktool.jar" ]; then
    APKTOOL_CMD="java -jar apktool.jar"
fi

FRAMEWORK_DIR="apktool_frameworks"

echo "[*] Processing: $INPUT_FILE"

# 1. DECODE
echo "  -> Decoding (without debug info)..."
rm -rf "$OUTPUT_DIR"
$APKTOOL_CMD d --no-debug-info -f -p "$FRAMEWORK_DIR" -o "$OUTPUT_DIR" "$INPUT_FILE"

# Special case for framework.jar
if [[ "$INPUT_NAME" == *"framework.jar" ]]; then
    if unzip -l "$INPUT_FILE" | grep -q "debian.mime.types"; then
        echo "  -> Applying debian.mime.types fix for framework.jar..."
        unzip -q -o "$INPUT_FILE" "res/*" -d "$OUTPUT_DIR/unknown" || true
    fi
fi

# 2. PATCH
for PATCH_NAME in "$@"; do
    PATCH_FILE="$PATCHES_DIR/$PATCH_NAME"
    if [ ! -f "$PATCH_FILE" ]; then
        echo "  [!] Patch not found: $PATCH_FILE"
        exit 1
    fi
    echo "  -> Applying patch: $PATCH_FILE"
    LC_ALL=C git apply --directory="$OUTPUT_DIR" --verbose --unsafe-paths "$PATCH_FILE"
done

# 2.5. SIGNATURE INJECTION
if grep -rl "PUT SIGNATURE HERE" "$OUTPUT_DIR" > /dev/null 2>&1; then
    CERT_PEM=""
    for candidate in platform.x509.pem aosp_platform.x509.pem; do
        if [ -f "$candidate" ]; then
            CERT_PEM="$candidate"
            break
        fi
    done

    if [ -n "$CERT_PEM" ]; then
        echo "  -> Injecting platform signature from $CERT_PEM..."
        CERT_SIGNATURE=$(sed '/CERTIFICATE/d' "$CERT_PEM" | tr -d '\n' | base64 -d | xxd -p -c 0)
        # Portable in-place edit (BSD sed on macOS needs a suffix arg after -i;
        # GNU sed does not — so avoid -i entirely and use a temp file).
        grep -rl --include="*.smali" "PUT SIGNATURE HERE" "$OUTPUT_DIR" | while IFS= read -r f; do
            sed "s|PUT SIGNATURE HERE|$CERT_SIGNATURE|g" "$f" > "$f.sigtmp" && mv "$f.sigtmp" "$f"
        done
    else
        echo "  [!] WARNING: 'PUT SIGNATURE HERE' found but no .x509.pem available — skipping injection."
    fi
fi

# 3. META-INF Copy
if [ -d "$OUTPUT_DIR/original/META-INF" ]; then
    echo "  -> Preserving original META-INF..."
    mkdir -p "$OUTPUT_DIR/build/apk"
    cp -a "$OUTPUT_DIR/original/META-INF" "$OUTPUT_DIR/build/apk/META-INF"
fi

# 4. BUILD
echo "  -> Rebuilding..."
$APKTOOL_CMD b -p "$FRAMEWORK_DIR" -o "$TEMP_FILE" "$OUTPUT_DIR"

# 5. SIGN / ZIPALIGN
if [[ "$EXT" == "apk" ]]; then
    echo "  -> Zipaligning..."
    zipalign -p 4 "$TEMP_FILE" "${TEMP_FILE}_aligned.apk"
    echo "  -> Signing (apksigner - platform key)..."
    # v4 disabled: it emits a .idsig and forces PackageManager down the fs-verity
    # path, which fails to scan when the apk sits on a read-only system partition
    # without fs-verity. v2+v3 only.
    apksigner sign --key platform.pk8 --cert platform.x509.pem \
        --v2-signing-enabled true --v3-signing-enabled true --v4-signing-enabled false \
        --out "$FINAL_FILE" "${TEMP_FILE}_aligned.apk"
    rm -f "${TEMP_FILE}_aligned.apk"
else
    echo "  -> Zipaligning (JAR file)..."
    zipalign -p 4 "$TEMP_FILE" "$FINAL_FILE"
fi

rm -f "$TEMP_FILE"
rm -rf "$OUTPUT_DIR"

# 6. COMPRESSION CHECK
echo "  -> Checking compression for $FINAL_FILE:"
unzip -v "$FINAL_FILE" | awk '
BEGIN { count = 0 }
NR>3 && / (\.dex|\.arsc|\.so)$/ {
    method = "STORED (Uncompressed)"
    if ($2 ~ /Defl/) method = "DEFLATED (Compressed)"
    print "     " $8 " -> " method
    count++
}
END {
    if (count == 0) print "     No .dex, .arsc, or .so files found."
}'

echo "  -> Completed: $FINAL_FILE"
