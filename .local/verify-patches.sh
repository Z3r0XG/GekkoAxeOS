#!/bin/bash
# verify-patches.sh — Verify all GekkoAxe-specific patches are intact
#
# Run this after every upstream merge to confirm nothing was lost.
# Usage: bash .local/verify-patches.sh

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

check() {
    local desc="$1"
    local file="$REPO/$2"
    local pattern="$3"
    if grep -q "$pattern" "$file" 2>/dev/null; then
        echo "  OK  $desc"
        ((PASS++))
    else
        echo "FAIL  $desc"
        echo "      file:    $2"
        echo "      missing: $pattern"
        ((FAIL++))
    fi
}

check_file() {
    local desc="$1"
    local file="$REPO/$2"
    if [[ -f "$file" ]]; then
        echo "  OK  $desc"
        ((PASS++))
    else
        echo "FAIL  $desc"
        echo "      missing file: $2"
        ((FAIL++))
    fi
}

echo ""
echo "── Hardware / board config ──────────────────────────"
check_file "config-GekkoAxe_GT.cvs exists"       "config-GekkoAxe_GT.cvs"
check      "board 800 entry in device_config.h"   "main/device_config.h"                 '"800"'
check      "board 800 uses FAMILY_GAMMA_TURBO"     "main/device_config.h"                 'board_version = "800".*FAMILY_GAMMA_TURBO\|FAMILY_GAMMA_TURBO.*board_version = "800"'

echo ""
echo "── lastSubmittedDiff feature ────────────────────────"
check "last_submitted_diff in global_state.h"      "main/global_state.h"                  "last_submitted_diff"
check "last_submitted_diff set in asic_result_task" "main/tasks/asic_result_task.c"        "last_submitted_diff"
check "last_submitted_diff read in statistics_task" "main/tasks/statistics_task.c"         "last_submitted_diff"
check "lastSubmittedDiff in http_server.c"          "main/http_server/http_server.c"       "lastSubmittedDiff"
check "lastSubmittedDiff in openapi.yaml"           "main/http_server/openapi.yaml"        "lastSubmittedDiff"

echo ""
echo "── Web UI — GekkoAxeOS branding ─────────────────────"
check "GekkoAxeOS SVG logo in topbar"              "main/http_server/axe-os/src/app/layout/app.topbar.component.html"          'viewBox="0 0 618 76"'
check "hamburger margin reduced in _topbar.scss"   "main/http_server/axe-os/src/app/layout/styles/layout/_topbar.scss"         "margin-left: 0.5rem"

echo ""
echo "── Web UI — GitHub update service ───────────────────"
check "update service points to Z3r0XG/GekkoAxeOS" "main/http_server/axe-os/src/app/services/github-update.service.ts"        "Z3r0XG/GekkoAxeOS"

echo ""
echo "── Stratum user-agent ───────────────────────────────"
check "stratum subscribe uses gekkoaxe/ not bitaxe/" "components/stratum/stratum_api.c" 'gekkoaxe/%s/%s'

echo ""
echo "── Release tooling ──────────────────────────────────"
check_file "build_release.sh exists"              "build_release.sh"
check      "build_release.sh has prerelease check" "build_release.sh"                     "IS_PRERELEASE"

echo ""
if [[ "$FAIL" -eq 0 ]]; then
    echo "All $PASS checks passed. Patches intact."
else
    echo "$FAIL check(s) FAILED — patches missing or overwritten by merge."
    echo "Review the failures above and re-apply the missing changes."
    exit 1
fi
echo ""
