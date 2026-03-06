#!/bin/bash
# build_release.sh — Build GekkoAxeOS and package release artifacts for GekkoAxe GT
#
# Produces three artifacts per release in releases/{VERSION}/:
#
#   GekkoAxeOS-{VERSION}-firmware.bin  — raw firmware (for AxeOS UI → OTA Firmware)
#   GekkoAxeOS-{VERSION}-www.bin       — raw web UI   (for AxeOS UI → OTA Web)
#   GekkoAxeOS-{VERSION}-factory.bin   — full merged image with GekkoAxe GT config baked in
#                                        (for esptool at 0x0 or bitaxetool --firmware)
#   config-GekkoAxe_GT.cvs             — config file  (for bitaxetool --config)
#
# Usage:
#   ./build_release.sh              # build + package locally
#   ./build_release.sh --no-build   # skip idf.py build, just re-package existing build/
#   ./build_release.sh --publish    # build, package, and publish to GitHub
#
# --publish will ABORT if the GitHub release already exists (releases are immutable).
#
# ESP-IDF is sourced from ~/esp/idf.  Output goes to releases/ (in .gitignore).

set -euo pipefail

IDF_PATH="${IDF_PATH:-$HOME/esp/idf}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASES_ROOT="$SCRIPT_DIR/releases"
BUILD_DIR="$SCRIPT_DIR/build"
NO_BUILD=0
DO_PUBLISH=0

for arg in "$@"; do
    [[ "$arg" == "--no-build" ]]  && NO_BUILD=1
    [[ "$arg" == "--publish" ]]   && DO_PUBLISH=1
done

# ── Resolve version ────────────────────────────────────────────────────────────
VERSION="$(git -C "$SCRIPT_DIR" describe --tags --dirty 2>/dev/null || echo "unknown")"
RELEASE_DIR="$RELEASES_ROOT/$VERSION"
echo "==> Version: $VERSION"
echo "==> Output:  $RELEASE_DIR"

# ── Immutability guard ─────────────────────────────────────────────────────────
if [[ "$DO_PUBLISH" -eq 1 ]]; then
    if [[ "$VERSION" == *"dirty"* ]]; then
        echo "ERROR: Working tree is dirty — cannot publish a dirty build."
        echo "       Commit or stash all changes first."
        exit 1
    fi
    if gh release view "$VERSION" --repo Z3r0XG/GekkoAxeOS > /dev/null 2>&1; then
        echo "ERROR: GitHub release $VERSION already exists — releases are immutable."
        echo "       Create a new tag to publish a new release."
        exit 1
    fi
fi

# ── Upstream pre-release check (only when publishing) ─────────────────────────
# Walk back through commit history to find the upstream base commit, then check
# whether that commit is tagged as a pre-release (beta/rc) on either:
#   - the local tag name (matches *b[0-9]* or *rc*)
#   - the GitHub release API (prerelease=true)
# If the base is a pre-release, this release MUST also be pre-release.
# Publishing a stable release on top of a beta/pre-release base is forbidden.
IS_PRERELEASE=0
UPSTREAM_BASE_TAG=""

if [[ "$DO_PUBLISH" -eq 1 ]] && git remote get-url upstream > /dev/null 2>&1; then
    git fetch upstream --tags --quiet 2>/dev/null || true
    UPSTREAM_BASE="$(git log --format="%H" HEAD | while read -r sha; do
        if git merge-base --is-ancestor "$sha" upstream/master 2>/dev/null; then
            echo "$sha"; break
        fi
    done)"
    if [[ -n "$UPSTREAM_BASE" ]]; then
        UPSTREAM_BASE_TAG="$(git describe --tags --exact-match "$UPSTREAM_BASE" 2>/dev/null || true)"
        if [[ -n "$UPSTREAM_BASE_TAG" ]]; then
            # Pre-release tag pattern: contains b[0-9], rc, alpha, beta
            if echo "$UPSTREAM_BASE_TAG" | grep -qE '[bB][0-9]+$|[-_]?(rc|alpha|beta)[0-9]*$'; then
                IS_PRERELEASE=1
                echo "==> Upstream base '$UPSTREAM_BASE_TAG' is a pre-release tag."
            else
                # Double-check GitHub in case upstream marks a plain tag as pre-release
                GH_PRERELEASE="$(gh api "repos/bitaxeorg/ESP-Miner/releases/tags/${UPSTREAM_BASE_TAG}" \
                    --jq '.prerelease' 2>/dev/null || echo "")"
                if [[ "$GH_PRERELEASE" == "true" ]]; then
                    IS_PRERELEASE=1
                    echo "==> Upstream base '$UPSTREAM_BASE_TAG' is marked pre-release on GitHub."
                fi
            fi
        fi
    fi
fi

if [[ "$DO_PUBLISH" -eq 1 ]]; then
    if [[ "$IS_PRERELEASE" -eq 1 ]]; then
        echo "==> This release will be published as PRE-RELEASE (upstream base is a pre-release)."
    else
        echo "==> This release will be published as STABLE."
    fi
fi

# ── Source ESP-IDF ─────────────────────────────────────────────────────────────
if [[ ! -f "$IDF_PATH/export.sh" ]]; then
    echo "ERROR: ESP-IDF not found at $IDF_PATH"
    echo "       Install: git clone --branch v5.5 --recursive https://github.com/espressif/esp-idf.git ~/esp/idf && ~/esp/idf/install.sh esp32s3"
    exit 1
fi
# shellcheck disable=SC1091
source "$IDF_PATH/export.sh" > /dev/null 2>&1

# ── Build ──────────────────────────────────────────────────────────────────────
if [[ "$NO_BUILD" -eq 0 ]]; then
    echo "==> Building..."
    idf.py -C "$SCRIPT_DIR" build
fi

# Verify expected build outputs exist
for f in "$BUILD_DIR/bootloader/bootloader.bin" \
          "$BUILD_DIR/partition_table/partition-table.bin" \
          "$BUILD_DIR/esp-miner.bin" \
          "$BUILD_DIR/www.bin" \
          "$BUILD_DIR/ota_data_initial.bin"; do
    if [[ ! -f "$f" ]]; then
        echo "ERROR: Missing build artifact: $f"
        echo "       Run without --no-build or check idf.py build output."
        exit 1
    fi
done

mkdir -p "$RELEASE_DIR"

# ── Flash addresses ────────────────────────────────────────────────────────────
BOOTLOADER_ADDR=0x0
PARTITION_ADDR=0x8000
CONFIG_ADDR=0x9000
MINER_ADDR=0x10000
WWW_ADDR=0x410000
OTA_ADDR=0xf10000

NVS_GEN="$IDF_PATH/components/nvs_flash/nvs_partition_generator/nvs_partition_gen.py"
ESPTOOL_BASE="esptool.py --chip esp32s3 merge_bin --flash_mode dio --flash_size 16MB --flash_freq 80m"

# ── 1. Raw firmware binary (AxeOS UI OTA → Firmware) ──────────────────────────
FIRMWARE_OUT="$RELEASE_DIR/GekkoAxeOS-${VERSION}-firmware.bin"
echo "==> Copying firmware:   $(basename "$FIRMWARE_OUT")"
cp "$BUILD_DIR/esp-miner.bin" "$FIRMWARE_OUT"

# ── 2. Raw www binary (AxeOS UI OTA → Web) ────────────────────────────────────
WWW_OUT="$RELEASE_DIR/GekkoAxeOS-${VERSION}-www.bin"
echo "==> Copying www:        $(basename "$WWW_OUT")"
cp "$BUILD_DIR/www.bin" "$WWW_OUT"

# ── 3. Factory image — merged with GekkoAxe GT config (esptool / bitaxetool) ──
CVS="$SCRIPT_DIR/config-GekkoAxe_GT.cvs"
CONFIG_BIN="$RELEASE_DIR/config-GekkoAxe_GT.bin"
echo "==> Generating NVS partition from config-GekkoAxe_GT.cvs"
python3 "$NVS_GEN" generate "$CVS" "$CONFIG_BIN" 0x6000

FACTORY_OUT="$RELEASE_DIR/GekkoAxeOS-${VERSION}-factory.bin"
echo "==> Creating factory image: $(basename "$FACTORY_OUT")"
$ESPTOOL_BASE \
    $BOOTLOADER_ADDR "$BUILD_DIR/bootloader/bootloader.bin" \
    $PARTITION_ADDR  "$BUILD_DIR/partition_table/partition-table.bin" \
    $CONFIG_ADDR     "$CONFIG_BIN" \
    $MINER_ADDR      "$BUILD_DIR/esp-miner.bin" \
    $WWW_ADDR        "$BUILD_DIR/www.bin" \
    $OTA_ADDR        "$BUILD_DIR/ota_data_initial.bin" \
    -o "$FACTORY_OUT"

# Cleanup intermediate NVS bin (it's embedded in factory image)
rm -f "$CONFIG_BIN"

# ── 4. Copy config CVS for bitaxetool users ────────────────────────────────────
echo "==> Copying config:     config-GekkoAxe_GT.cvs"
cp "$CVS" "$RELEASE_DIR/config-GekkoAxe_GT.cvs"

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo "==> Done. Release artifacts in $RELEASE_DIR:"
ls -lh "$RELEASE_DIR"

# ── Publish ────────────────────────────────────────────────────────────────────
if [[ "$DO_PUBLISH" -eq 1 ]]; then
    echo ""
    echo "==> Publishing GitHub release $VERSION..."
    PRERELEASE_FLAG=""
    [[ "$IS_PRERELEASE" -eq 1 ]] && PRERELEASE_FLAG="--prerelease"
    gh release create "$VERSION" \
        "$RELEASE_DIR/GekkoAxeOS-${VERSION}-factory.bin" \
        "$RELEASE_DIR/GekkoAxeOS-${VERSION}-firmware.bin" \
        "$RELEASE_DIR/GekkoAxeOS-${VERSION}-www.bin" \
        "$RELEASE_DIR/config-GekkoAxe_GT.cvs" \
        --repo Z3r0XG/GekkoAxeOS \
        --title "GekkoAxeOS $VERSION" \
        --generate-notes \
        $PRERELEASE_FLAG
    echo "==> Published: https://github.com/Z3r0XG/GekkoAxeOS/releases/tag/$VERSION"
fi
