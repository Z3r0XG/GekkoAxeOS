#!/bin/bash
# build_release.sh — Build GekkoAxeOS and package release artifacts
#
# Produces the following artifacts per release in releases/{VERSION}/:
#
#   gekkoaxe-firmware-{VERSION}.bin          — raw firmware (OTA Firmware, all boards)
#   gekkoaxe-www-{VERSION}.bin               — raw web UI  (OTA Web, all boards)
#   gekkoaxe-factory-{BOARD}-{VERSION}.bin   — merged factory image per config file
#                                              (esptool at 0x0 or bitaxetool --firmware)
#   config-{BOARD}.cvs                       — config files (bitaxetool --config)
#
#   BOARD is derived from config-{BOARD}.cvs filenames (e.g. 800, 601, GekkoAxe_GT).
#   config-custom.cvs is excluded (user-local only).
#
# Usage:
#   ./build_release.sh              # build + package locally
#   ./build_release.sh --no-build   # skip idf.py build, just re-package existing build/
#   ./build_release.sh --publish    # build, package, and publish to GitHub
#   ./build_release.sh --boards "800 601 GekkoAxe_GT"  # only these boards
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
BOARDS_FILTER=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-build)   NO_BUILD=1 ;;
        --publish)    DO_PUBLISH=1 ;;
        --boards)     BOARDS_FILTER="$2"; shift ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
    shift
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
            if echo "$UPSTREAM_BASE_TAG" | grep -qE '[bB][0-9]+$|[-_]?(rc|alpha|beta)[0-9]*$'; then
                IS_PRERELEASE=1
                echo "==> Upstream base '$UPSTREAM_BASE_TAG' is a pre-release tag."
            else
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
        echo "==> This release will be published as PRE-RELEASE."
    else
        echo "==> This release will be published as STABLE."
    fi
fi

# ── Source ESP-IDF ─────────────────────────────────────────────────────────────
if [[ ! -f "$IDF_PATH/export.sh" ]]; then
    echo "ERROR: ESP-IDF not found at $IDF_PATH"
    exit 1
fi
source "$IDF_PATH/export.sh" > /dev/null 2>&1

# ── Build ──────────────────────────────────────────────────────────────────────
if [[ "$NO_BUILD" -eq 0 ]]; then
    echo "==> Building..."
    idf.py -C "$SCRIPT_DIR" build
fi

for f in "$BUILD_DIR/bootloader/bootloader.bin" \
          "$BUILD_DIR/partition_table/partition-table.bin" \
          "$BUILD_DIR/esp-miner.bin" \
          "$BUILD_DIR/www.bin" \
          "$BUILD_DIR/ota_data_initial.bin"; do
    [[ -f "$f" ]] || { echo "ERROR: Missing build artifact: $f"; exit 1; }
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

# ── 1. Raw firmware binary (OTA → Firmware, same for all boards) ──────────────
FIRMWARE_OUT="$RELEASE_DIR/gekkoaxe-firmware-${VERSION}.bin"
echo "==> Firmware:  $(basename "$FIRMWARE_OUT")"
cp "$BUILD_DIR/esp-miner.bin" "$FIRMWARE_OUT"

# ── 2. Raw www binary (OTA → Web, same for all boards) ────────────────────────
WWW_OUT="$RELEASE_DIR/gekkoaxe-www-${VERSION}.bin"
echo "==> WWW:       $(basename "$WWW_OUT")"
cp "$BUILD_DIR/www.bin" "$WWW_OUT"

# ── 3. Factory image + config per board ───────────────────────────────────────
FACTORY_FILES=()
CONFIG_FILES=()

for CVS in "$SCRIPT_DIR"/config-GekkoAxe_*.cvs; do
    BOARD="$(basename "$CVS" .cvs | sed 's/^config-//')"

    # If --boards filter specified, skip non-matching
    if [[ -n "$BOARDS_FILTER" ]]; then
        echo "$BOARDS_FILTER" | tr ' ' '\n' | grep -qx "$BOARD" || continue
    fi

    CONFIG_BIN="$RELEASE_DIR/config-${BOARD}.bin"
    FACTORY_OUT="$RELEASE_DIR/gekkoaxe-factory-${BOARD}-${VERSION}.bin"
    CONFIG_OUT="$RELEASE_DIR/config-${BOARD}.cvs"

    echo "==> Board $BOARD: generating NVS..."
    python3 "$NVS_GEN" generate "$CVS" "$CONFIG_BIN" 0x6000

    echo "==> Board $BOARD: $(basename "$FACTORY_OUT")"
    $ESPTOOL_BASE \
        $BOOTLOADER_ADDR "$BUILD_DIR/bootloader/bootloader.bin" \
        $PARTITION_ADDR  "$BUILD_DIR/partition_table/partition-table.bin" \
        $CONFIG_ADDR     "$CONFIG_BIN" \
        $MINER_ADDR      "$BUILD_DIR/esp-miner.bin" \
        $WWW_ADDR        "$BUILD_DIR/www.bin" \
        $OTA_ADDR        "$BUILD_DIR/ota_data_initial.bin" \
        -o "$FACTORY_OUT"

    rm -f "$CONFIG_BIN"

    cp "$CVS" "$CONFIG_OUT"

    FACTORY_FILES+=("$FACTORY_OUT")
    CONFIG_FILES+=("$CONFIG_OUT")
done

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

    UPLOAD_FILES=("$FIRMWARE_OUT" "$WWW_OUT" "${FACTORY_FILES[@]}" "${CONFIG_FILES[@]}")

    UPSTREAM_VER="$(echo "$VERSION" | grep -oP 'v[0-9]+\.[0-9]+\.[0-9]+')"
    BOARDS_LIST="$(for f in "${CONFIG_FILES[@]}"; do board="$(basename "$f" .cvs)"; echo "- \`${board}\`"; done)"

    RELEASE_NOTES="$(cat <<EOF
Based on [ESP-Miner ${UPSTREAM_VER}](https://github.com/bitaxeorg/ESP-Miner/releases/tag/${UPSTREAM_VER}).

### Boards

${BOARDS_LIST}

### Flashing

See the [README](https://github.com/Z3r0XG/GekkoAxeOS#flashing-a-release) for full flashing instructions.
EOF
)"

    gh release create "$VERSION" \
        "${UPLOAD_FILES[@]}" \
        --repo Z3r0XG/GekkoAxeOS \
        --title "GekkoAxeOS $VERSION" \
        --notes "$RELEASE_NOTES" \
        $PRERELEASE_FLAG
    echo "==> Published: https://github.com/Z3r0XG/GekkoAxeOS/releases/tag/$VERSION"
fi
