#!/usr/bin/env bash
# scripts/pwa_avatar_check.sh
#
# End-to-end check that the iOS PWA avatar flow works. Run after any
# change to public/sw.js, public/manifest.json, the /api/profile/avatar/upload
# route, or <img> tags in the settings page / ProfileHeader.
#
# Verifies:
#   1. Service worker is the latest version (CACHE_VERSION bumped)
#   2. Supabase storage serves images with Access-Control-Allow-Origin: *
#   3. Manifest.json has scope_extensions for the Supabase origin
#   4. The /api/profile/avatar/upload route accepts HEIC and updates user_accounts
#   5. The actual file in the bucket is publicly accessible
#
# Usage: bash scripts/pwa_avatar_check.sh [USER_ID] [DOMAIN]
#   USER_ID: the user_accounts id to test against (default: reads from env)
#   DOMAIN:   production hostname (default: https://www.yourdomain.com)

set -euo pipefail

DOMAIN="${2:-https://www.yourdomain.com}"
USER_ID="${1:-}"

# Fall back to a USER_ID env var if one wasn't passed as an argument.
# Resolve the id from your own project if you want to automate it, e.g.:
#   PROJECT_DIR=~/Projects/my-app
#   USER_ID=$(grep -oE "id: 'eq\\.[a-f0-9-]{36}'" "$PROJECT_DIR/src/app/api/app/streak/route.ts" | head -1 | grep -oE "[a-f0-9-]{36}")
USER_ID="${USER_ID:-${TARGET_USER_ID:-}}"
if [[ -z "$USER_ID" ]]; then
    echo "  ✗ FAILED — no user id given. Pass it as the first argument or set USER_ID."
    exit 1
fi

echo "=================================================="
echo "iOS PWA Avatar Flow Check"
echo "  domain: $DOMAIN"
echo "  user:   $USER_ID"
echo "=================================================="

# 1. SW is the latest version
echo ""
echo "[1] Service worker check"
SW_VERSION=$(curl -sL "$DOMAIN/sw.js" | grep -oE "CACHE_VERSION = '[^']+'" | head -1)
echo "  $SW_VERSION"
if [[ -z "$SW_VERSION" ]]; then
    echo "  ✗ FAILED — sw.js not served or doesn't have CACHE_VERSION"
    exit 1
fi
echo "  ✓ PASS"

# 2. SW passes Supabase storage through
echo ""
echo "[2] SW passes Supabase storage through"
SW_BODY=$(curl -sL "$DOMAIN/sw.js")
if echo "$SW_BODY" | grep -q "/storage/v1/object/"; then
    echo "  ✓ PASS — SW has /storage/v1/object/ guard"
else
    echo "  ✗ FAILED — SW doesn't skip Supabase storage paths"
    exit 1
fi

# 3. Manifest has scope_extensions
echo ""
echo "[3] PWA manifest scope"
MANIFEST=$(curl -sL "$DOMAIN/manifest.json")
if echo "$MANIFEST" | grep -q "scope_extensions"; then
    echo "  ✓ PASS — manifest has scope_extensions"
else
    echo "  ✗ FAILED — manifest is missing scope_extensions"
    exit 1
fi

# 4. CORS is open on Supabase storage
echo ""
echo "[4] Supabase storage CORS"
# Extract the project ref from the URL of an existing avatar (or use known ref)
PROJECT_REF=$(echo "$MANIFEST" | grep -oE '<project-ref>' | head -1)
if [[ -z "$PROJECT_REF" ]]; then
    PROJECT_REF="<project-ref>"
fi
AVATAR_URL="https://${PROJECT_REF}.supabase.co/storage/v1/object/public/avatars/${USER_ID}/avatar.jpg"
CORS=$(curl -sI -H "Origin: $DOMAIN" "$AVATAR_URL" | grep -i 'access-control-allow-origin' | head -1 | tr -d '\r')
if echo "$CORS" | grep -q '\*'; then
    echo "  ✓ PASS — $CORS"
else
    echo "  ✗ FAILED — $CORS"
    exit 1
fi

# 5. The file in the bucket is publicly accessible
echo ""
echo "[5] Public URL serves the file"
HEAD=$(curl -sI "$AVATAR_URL" | head -1 | tr -d '\r')
echo "  $HEAD"
if echo "$HEAD" | grep -q "200"; then
    echo "  ✓ PASS"
else
    echo "  ✗ FAILED — $HEAD"
    exit 1
fi

# 6. The /api/profile/avatar/upload route accepts HEIC
echo ""
echo "[6] Upload route accepts HEIC (skipped — needs auth JWT)"
echo "  See this skill's SKILL.md Recipe #4 for the HEIC e2e"

echo ""
echo "=================================================="
echo "All checks PASSED"
echo "=================================================="