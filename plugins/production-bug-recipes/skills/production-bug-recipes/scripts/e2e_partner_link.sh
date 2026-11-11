#!/usr/bin/env bash
# scripts/e2e_partner_link.sh
#
# End-to-end verification of the platform partner referral link chain.
# Companion to recipe #8 in the known-bugs skill. Run against
# any deployed environment to confirm that:
#
#   1. /ref/<code>              → 307 redirect to /get-started?ref=<code>
#                                 (the <code> must NOT be "undefined")
#   2. /get-started?ref=<code>  → 200
#   3. /api/partners/lookup     → returns cfd_broker_link when partner has one
#   4. /api/signup/register     → accepts a referredByCode
#
# Usage:
#   export BASE_URL=https://www.yourdomain.com
#   export REF_CODE=<your-admin-partner-code>
#   bash scripts/e2e_partner_link.sh
#
# Optional (for step 4):
#   export JWT=<supabase-access-token>
#   export USER_ID=<a-real-supabase-user-id>

set -uo pipefail

BASE_URL="${BASE_URL:-https://www.yourdomain.com}"
REF_CODE="${REF_CODE:?REF_CODE is required, e.g. export REF_CODE=PARTNER-A1B2C3}"

USER_AGENT="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

bold() { printf "\033[1m%s\033[0m\n" "$1"; }
ok()   { printf "  \033[32m✓\033[0m %s\n" "$1"; }
fail() { printf "  \033[31m✗\033[0m %s\n" "$1"; FAILED=1; }
note() { printf "  \033[36mi\033[0m %s\n" "$1"; }

FAILED=0

bold "the platform Partner Link E2E"
echo "    Base URL : $BASE_URL"
echo "    Ref code : $REF_CODE"
echo

# ── Step 1: /ref/<code> redirect target ────────────────────────────────────
bold "Step 1 — /ref/<code> redirects with the code in the URL"
REDIRECT_TARGET=$(curl -sS -o /dev/null -w "%{redirect_url}" \
    -A "$USER_AGENT" "$BASE_URL/ref/$REF_CODE" 2>&1) || true

if [[ "$REDIRECT_TARGET" == *"/get-started?ref=$REF_CODE"* ]]; then
    ok "redirect → $REDIRECT_TARGET"
elif [[ "$REDIRECT_TARGET" == *"ref=undefined"* ]] || [[ "$REDIRECT_TARGET" == *"ref=" && "$REDIRECT_TARGET" != *"$REF_CODE"* ]]; then
    fail "redirect is dropping the code: $REDIRECT_TARGET"
    note "This is recipe #8 in the known-bugs skill — the dynamic"
    note "route's params Promise wasn't awaited. Aug 14 2026 fix."
else
    fail "unexpected redirect: $REDIRECT_TARGET"
fi
echo

# ── Step 2: /get-started?ref=<code> renders 200 ─────────────────────────────
bold "Step 2 — /get-started?ref=<code> returns 200"
GET_STARTED_STATUS=$(curl -sS -o /dev/null -w "%{http_code}" \
    -A "$USER_AGENT" "$BASE_URL/get-started?ref=$REF_CODE" 2>&1) || true

if [[ "$GET_STARTED_STATUS" == "200" ]]; then
    ok "GET /get-started?ref=$REF_CODE → 200"
else
    fail "GET /get-started?ref=$REF_CODE → $GET_STARTED_STATUS"
fi
echo

# ── Step 3: /api/partners/lookup returns the partner + cfd_broker_link ─────
bold "Step 3 — /api/partners/lookup resolves the code"
LOOKUP_JSON=$(curl -sS -A "$USER_AGENT" "$BASE_URL/api/partners/lookup?code=$REF_CODE" 2>&1) || true
echo "    response: $LOOKUP_JSON"

LOOKUP_VALID=$(echo "$LOOKUP_JSON" | python3 -c "import sys,json;d=json.loads(sys.stdin.read());print(d.get('valid'))" 2>/dev/null || echo "?")

if [[ "$LOOKUP_VALID" == "True" ]]; then
    ok "lookup marked the code as valid"
else
    fail "lookup did NOT validate the code (valid=$LOOKUP_VALID)"
    note "this may be expected if the code doesn't resolve — paste your"
    note "admin partner code, not a guess."
fi

HAS_GENESIS=$(echo "$LOOKUP_JSON" | python3 -c "import sys,json;d=json.loads(sys.stdin.read());print('cfd_broker_link' in d)" 2>/dev/null || echo "?")
if [[ "$HAS_GENESIS" == "True" ]]; then
    ok "lookup response includes cfd_broker_link field"
    GENESIS_LINK=$(echo "$LOOKUP_JSON" | python3 -c "import sys,json;d=json.loads(sys.stdin.read());print(d.get('cfd_broker_link') or '<null>')" 2>/dev/null)
    note "partner's stored CFD broker link: $GENESIS_LINK"
else
    fail "lookup response is missing cfd_broker_link field"
    note "recipe #5 — the get-started wizard needs this field to surface"
    note "the partner's CFD broker account link to the new user."
fi
echo

# ── Step 4: /api/signup/register accepts referredByCode (needs JWT) ────────
bold "Step 4 — /api/signup/register (requires JWT + USER_ID env vars)"
if [[ -z "${JWT:-}" || -z "${USER_ID:-}" ]]; then
    note "skipping — set JWT and USER_ID env vars to exercise this route"
else
    RESP=$(curl -sS -A "$USER_AGENT" -X POST "$BASE_URL/api/signup/register" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $JWT" \
        -d "$(printf '{"userId":"%s","email":"e2e-test@example.com","fullName":"E2E Test","division":"trading","applicationData":{},"referredByCode":"%s"}' "$USER_ID" "$REF_CODE")" 2>&1) || true
    echo "    response: $RESP"

    if echo "$RESP" | grep -q '"success":true'; then
        ok "register accepted the referredByCode"
    else
        fail "register rejected the referredByCode"
    fi
fi
echo

bold "Summary"
if [[ "$FAILED" -eq 0 ]]; then
    printf "\033[32mAll checks passed.\033[0m\n"
    exit 0
else
    printf "\033[31mSome checks failed.\033[0m\n"
    exit 1
fi
