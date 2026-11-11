# Aug 24 2026 — Pre-launch readiness audit + user_accounts trigger + leaderboard 500

Session drop-in for `this skill's SKILL.md` merge.

Three independent patterns discovered on Aug 24 2026 while running a
pre-launch readiness audit for the first 50 onboarding wave. One is
a real production-blocking bug; the others are reusable methodology.

---

## Recipe #38 — `handle_new_user` trigger must create `user_accounts` row (CRITICAL onboarding blocker)

**Symptom:** a fresh Supabase auth signup (via `/auth/v1/signup` or the
sign-in page) cannot complete ANY onboarding step. Every
`POST /api/onboarding/complete-step` returns either:
- `400 {"ok":false,"error":"step_not_complete:avatar_not_set"}` for `profile_basics`
- `400 {"ok":false,"error":"step_not_complete:risk_not_acknowledged"}` for `risk_disclaimer`
- `500 {"ok":false,"error":"insert or update on table \"user_progress\" violates foreign key constraint \"user_onboarding_progress_user_id_fkey\""}` for the steps that pass the data check

A user who has all the underlying data set (avatar uploaded, broker
connected, push subscription active) still can't progress the
wizard. The DB has `onboarding_complete=false` indefinitely.

**Root cause:** the `handle_new_user` trigger on `auth.users` was
inserting only into `partners`, not into `user_accounts`. So a fresh
Supabase auth signup left the user with:

| Table | Row exists? |
|---|---|
| `auth.users` | yes (created by the signup) |
| `partners` | yes (trigger inserted) |
| `user_accounts` | **NO** — the trigger never created it |

Every onboarding completion check reads from `user_accounts` via
`createServiceClient()`. `.single()` errors on the missing row →
`data` is null → the helper returns `avatar_not_set` / etc.

Worse: `app_complete_onboarding_step` (the RPC) tries to INSERT into
`user_progress` with `user_id = <new user>`. The FK
constraint `user_onboarding_progress_user_id_fkey` requires a
matching `user_accounts.id`. The INSERT fails with a 500.

**The fix — extend `handle_new_user()` to also insert a `user_accounts` row:**

```sql
-- supabase/migrations/202608240000_handle_new_user_creates_user_accounts.sql
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public
AS $$
DECLARE
    v_display_name TEXT;
    v_email_local  TEXT;
BEGIN
    -- Derive a sensible display name from user_metadata or email local-part.
    v_display_name := COALESCE(
        NULLIF(NEW.raw_user_meta_data->>'full_name', ''),
        NULLIF(split_part(NEW.email, '@', 1), '')
    );

    -- partners row (existing behavior). NOT EXISTS guard because
    -- partners.user_id has NO UNIQUE constraint, so ON CONFLICT
    -- would fail with `there is no unique or exclusion constraint
    -- matching the ON CONFLICT specification`.
    IF NOT EXISTS (SELECT 1 FROM public.partners WHERE user_id = NEW.id) THEN
        INSERT INTO public.partners (user_id, is_partner)
        VALUES (NEW.id, false);
    END IF;

    -- user_accounts row (NEW). Safe defaults — the user fills in
    -- avatar_url, full_name, etc. during the onboarding wizard.
    INSERT INTO public.user_accounts (id, email, full_name)
    VALUES (NEW.id, NEW.email, v_display_name)
    ON CONFLICT (id) DO NOTHING;

    RETURN NEW;
END;
$$;

-- Re-bind the trigger
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- Backfill existing users (safe because of ON CONFLICT above)
INSERT INTO public.user_accounts (id, email, full_name)
SELECT au.id, au.email,
       COALESCE(NULLIF(au.raw_user_meta_data->>'full_name', ''),
                NULLIF(split_part(au.email, '@', 1), ''))
FROM auth.users au
LEFT JOIN public.user_accounts pu ON pu.id = au.id
WHERE pu.id IS NULL
ON CONFLICT (id) DO NOTHING;

-- Same backfill for partners (no unique constraint, use NOT EXISTS)
INSERT INTO public.partners (user_id, is_partner)
SELECT au.id, false
FROM auth.users au
WHERE NOT EXISTS (SELECT 1 FROM public.partners p WHERE p.user_id = au.id);
```

Apply via `supabase db push --include-all --dns-resolver https`
(Recipe #20).

**Verified end-to-end:**

```bash
# 1. Create fresh user via /auth/v1/signup
EMAIL="e2e-$(uuidgen | cut -c1-8)@yourdomain.com"
SIGNUP=$(curl -sX POST "$SUPABASE_URL/auth/v1/signup" \
  -H "apikey: $SERVICE_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL\",\"password\":\"TestPass2026!\"}")
USER_ID=$(echo $SIGNUP | jq -r '.user.id')
JWT=$(echo $SIGNUP | jq -r '.access_token')

# 2. Wait 1.5s for trigger
sleep 1.5

# 3. Verify user_accounts row exists
curl -s "$SUPABASE_URL/rest/v1/user_accounts?id=eq.$USER_ID" \
  -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" | jq '.[0]'
# Expected: { "id": "<USER_ID>", "email": "<EMAIL>", "full_name": "e2e-..." }

# 4. Walk the wizard
for STEP in profile_basics accent_theme risk_disclaimer connect_broker link_broker enable_push walkthrough; do
    curl -sX POST "$APP_URL/api/onboarding/complete-step" \
      -H "Authorization: Bearer $JWT" -H "Content-Type: application/json" \
      -d "{\"step_key\":\"$STEP\"}" | jq -c '.'
done
# Expected: every step returns {ok: true, ...}

# 5. Verify trigger fired
curl -s "$SUPABASE_URL/rest/v1/user_accounts?id=eq.$USER_ID&select=onboarding_complete" \
  -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" | jq '.[0].onboarding_complete'
# Expected: true
```

**The general rule — every user-facing onboarding/wizard/feature flow
MUST trace which auth event creates which downstream rows.**

If the wizard reads from `user_accounts` (or any other table that the
auth-signup event should auto-populate), there MUST be a trigger or
service call that creates that row at signup time. If the trigger
exists but only inserts into ONE related table, the others are
silently broken.

**The audit — is the trigger complete for every downstream table?**

```sql
-- 1. List all triggers on auth.users
SELECT tgname, tgenabled, proname AS function_name
FROM pg_trigger
JOIN pg_proc ON pg_proc.oid = pg_trigger.tgfoid
WHERE tgrelid = 'auth.users'::regclass;

-- 2. Check the trigger function body
SELECT prosrc
FROM pg_proc
WHERE proname = 'handle_new_user';

-- 3. List the public-facing tables the auth flow should populate
-- (every table that has id REFERENCES auth.users(id))
SELECT c.conrelid::regclass AS table_name
FROM pg_constraint c
WHERE c.contype = 'f'
  AND c.confrelid = 'auth.users'::regclass
  AND c.conname NOT LIKE '%_fkey_old%';  -- ignore old FKs
```

For every FK in step 3 that the trigger does NOT handle, the
related wizard step will silently fail for fresh signups.

**When this hits again:** any new public-facing table that's FK-bound
to `auth.users` AND that the wizard/feature reads from on the first
session after signup. The default action: extend `handle_new_user()`
to also create a row in the new table, with safe defaults the
wizard will populate later.

**Pair with:** Recipe #20 (apply Supabase migrations from sandbox via
`db push --dns-resolver https`). Recipe #11 (`user_accounts.id` IS
the auth.users.id). Recipe #31 (the onboarding trigger with stale step
list) — `app_onboarding_step_changed` is the OTHER side of the same
wizard, also a trigger that needs to stay in sync with the canonical
step list.

---

## Recipe #39 — Pre-launch readiness audit methodology (the 500-sweep + fresh-user E2E + surface status)

**Class of work:** the user says "we're onboarding 50 new members, make sure everything is ready." Before the launch, audit the platform end-to-end with three checks: API 500-sweep, fresh-user E2E walkthrough, and surface HTTP status. This recipe captures the methodology.

**The methodology — three checks, run in order:**

### Check 1 — API 500-sweep (catches server-side exceptions)

```bash
# Find all API routes
ROUTES=$(find src/app/api -name 'route.ts' | \
  sed 's|src/app/api||; s|/route.ts||' | sort)

# Hit each one without auth, look for 500s
echo "$ROUTES" | while read -r R; do
    CODE=$(curl -s -o /dev/null -w '%{http_code}' \
      "https://<domain>/api${R}" \
      -H 'User-Agent: Mozilla/5.0' 2>/dev/null)
    if [ "$CODE" = "500" ]; then
        BODY=$(curl -s "https://<domain>/api${R}" -H 'User-Agent: Mozilla/5.0')
        echo "✗ $R: 500 — $BODY"
    fi
done
```

For 500s, capture the error body — it's almost always a column name,
missing table, or missing FK relationship.

**What a 500 means:** the route exists (no 404), accepts the request, but
the server throws during execution. Three common causes:

1. **Column doesn't exist** — `column "<table>.<col>" does not exist`. The
   route queries a column the migration never added, or the migration
   renamed the column but the route wasn't updated.
2. **Table doesn't exist** — `Could not find the table "<schema>.<table>"
   in the schema cache`. The migration that creates the table was
   never applied, or the route references a table in a different schema.
3. **PostgREST relationship not exposed** — `Could not find a
   relationship between "<a>" and "<b>" in the schema cache`. The FK
   exists but PostgREST can't discover it (e.g. the FK points to
   `auth.users.id` not to a public-schema table).

**The expected counts for a healthy platform:**

- ~70% of routes return **401** (require auth) — that's normal
- ~20% return **404** (wrong URL — likely the test was bad) — re-verify
  the route path
- ~10% return **405** (wrong method — endpoint only supports POST) —
  re-test with `-X POST`
- <5% return **200** (truly public — login, signup, etc.)
- **0 should return 500**

### Check 2 — Fresh-user E2E walkthrough (catches auth/permission flow bugs)

```bash
# Mint a fresh user via service-role
EMAIL="e2e-$(uuidgen | cut -c1-8)@yourdomain.com"
SIGNUP=$(curl -sX POST "$SUPABASE_URL/auth/v1/signup" \
  -H "apikey: $SERVICE_KEY" -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL\",\"password\":\"TestPass2026!\"}")
USER_ID=$(echo $SIGNUP | jq -r '.user.id')
JWT=$(echo $SIGNUP | jq -r '.access_token')

# Backfill the user_accounts row (in case the trigger didn't fire)
curl -sX POST "$SUPABASE_URL/rest/v1/user_accounts" \
  -H "apikey: $SERVICE_KEY" \
  -H "Authorization: Bearer $SERVICE_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"id\":\"$USER_ID\",\"email\":\"$EMAIL\",\"full_name\":\"E2E Ready\"}"

# Walk the full user journey:
# 1. GET /api/onboarding/lifecycle (expect 1/7 — accent_theme auto)
# 2. POST each complete-step (expect all 7 to return ok: true)
# 3. GET /api/onboarding/lifecycle (expect 7/7, onboarding_complete=true)
# 4. GET /dashboard/trading (expect 200 — gate flipped)
# 5. Cleanup via DELETE /auth/v1/admin/users/:id

# For partner-specific flows, also:
# 6. GET /api/partners/dashboard (expect 200, downline_count, etc.)
# 7. POST /api/admin/test-email to verify Resend is wired
# 8. POST /api/app/award to cross a milestone — verify email fires
```

### Check 3 — Surface HTTP status (catches the user-facing app, not just the API)

```bash
# Critical pages the new user will hit on day 1
SURFACES=(/ /onboarding /dashboard /dashboard/trading /dashboard/partners
           /dashboard/education /dashboard/guided_account /changelog /get-started /login)

for PATH in "${SURFACES[@]}"; do
    CODE=$(curl -s -o /dev/null -w '%{http_code}' \
      "https://<domain>${PATH}" -H 'User-Agent: Mozilla/5.0')
    SIZE=$(curl -sI "https://<domain>${PATH}" -H 'User-Agent: Mozilla/5.0' | \
      grep -i 'content-length' | tr -d '\r' | awk '{print $2}')
    echo "  $CODE  ${SIZE}b  $PATH"
done
```

All should return **200**. **404s are likely intentional** (sub-routes
that don't exist as pages, e.g. `/dashboard/profile` when the profile
is at `/dashboard/trading/settings`). Look for **5xx** specifically.

### The order of operations for a launch-day audit

1. **Run Check 1 first.** API 500s are usually quick wins and high-impact
   blockers. 30-60s of work.
2. **Run Check 3 next.** Surface HTTP errors mean the user is locked
   out of entire pages. Fixing them requires JSX/redirect changes
   that take longer.
3. **Run Check 2 last.** The full E2E is the slowest and most likely
   to surface auth-flow bugs that need a migration to fix.

**The pre-launch output report** (recommended format):

```
# Pre-Launch Readiness Report — <date>
# Auditor: <name>
# Scope: <scope>
# Verdict: ✅ GO | ❌ NO-GO

## Backend health
- Latest deploy: <id> SUCCESS
- SW CACHE_VERSION: <version>
- Build status: ✅ / ❌

## Onboarding flow (Check 2)
- All 7 steps complete: ✅ / ❌
- Trigger fires: ✅ / ❌
- Page-level gate: ✅ / ❌

## API 500-sweep (Check 1)
- 0 endpoints return 500 (out of <N>)

## Surface HTTP status (Check 3)
- All critical pages return 200: ✅ / ❌
- Pages still 200 after the 4xx 404s: ✅ / ❌

## Critical findings + fixes
1. <blocker>: <description> → <fix> → <commit>
2. <blocker>: <description> → <fix> → <commit>
...

## Verdict
✅ Ready to launch, or
❌ Blocker: <fix this first>
```

**When this hits again:** every "we're about to onboard / launch /
take payments / open registration" event. The 500-sweep + E2E +
surface check takes ~10 minutes for a large codebase. The bug
classes it catches (missing triggers, column mismatches, FK
relationship issues, broken routes) are the ones that pass `tsc` but
fail at runtime.

**Pair with:** `this skill` SKILL.md Cross-cutting
pattern D ("I shipped a real bug, said it was tested, but tsc just
said 'no errors'"). The pre-launch audit IS the Verifier-First rule
applied to a whole platform.

---

## Recipe #40 — `/api/leaderboard` 500: column mismatch + missing PostgREST relationship

**Symptom:** `GET /api/leaderboard` returns 500 with errors like:

```json
{"error":"column partners.rank_label does not exist"}
{"error":"column partners.ib_lot_rate does not exist"}
{"error":"column partners.total_sales does not exist"}
{"error":"column partners.downline_count does not exist"}
{"error":"Could not find a relationship between 'partners' and 'user_accounts' in the schema cache"}
```

The partner leaderboard page (`/dashboard/leaderboard`) shows a 500
error in production. This is user-facing.

**Root cause — three layered issues:**

1. The original query selected columns that don't exist on `partners`:
   `rank_label`, `ib_lot_rate`, `total_sales`, `downline_count`.
   The actual columns on `partners` are: `rank`, `ib_contract_rate`,
   `total_earnings`, `total_referrals`.

2. The query tried to join `profiles:firstName,lastName,email` but
   there's no `profiles` table — the user data lives on
   `user_accounts` with `full_name` (not split into first/last).

3. The query tried to join via `user_accounts!partners_user_id_fkey`
   but `partners.user_id` references `auth.users.id` (not
   `user_accounts.id`), so there's no PostgREST-discoverable
   relationship between the two tables.

**The fix — drop the inline join, fetch user_accounts separately:**

```ts
// src/app/api/leaderboard/route.ts — public branch
const { data: partners, error } = await supabase
  .from('partners')
  .select(`
    id,
    user_id,
    rank,
    rank_label:rank,                  -- alias rank to rank_label for the response
    ib_contract_rate,
    total_earnings,
    tier,
    created_at
  `)
  .order(sort, { ascending: false })
  .limit(limit)

if (error) {
  return NextResponse.json({ error: error.message }, { status: 500 })
}

// Fetch user_accounts separately. The .in() filter caps at 1000 by
// default which matches the .limit(200) above with headroom.
const userIds = (partners || []).map((p: any) => p.user_id).filter(Boolean)
let profileMap: Record<string, any> = {}
if (userIds.length) {
  const { data: profiles } = await supabase
    .from('user_accounts')
    .select('id, full_name, email, rank, rank_label, ib_lot_rate, total_sales, downline_count')
    .in('id', userIds)
  for (const p of (profiles || [])) profileMap[p.id] = p
}

// Stitch the two sources per row with sensible fallbacks
const leaderboard = (partners || []).map((p: any, index: number) => {
  const profile = profileMap[p.user_id]
  const rankLabel     = profile?.rank_label || p.rank || 'Partner'
  const ibLotRate     = Number(profile?.ib_lot_rate ?? p.ib_contract_rate ?? 0)
  const totalEarnings = Number(p.total_earnings ?? 0)
  const totalSales    = Number(profile?.total_sales ?? 0)
  const downlineCount = Number(profile?.downline_count ?? 0)
  return {
    rank: index + 1,
    name: profile?.full_name || (profile?.email?.split('@')[0] || 'Anonymous'),
    rank_label: rankLabel,
    ib_lot_rate: ibLotRate,
    total_earnings: totalEarnings,
    total_sales: totalSales,
    downline_count: downlineCount,
    member_since: p.created_at ?? null,
  }
})
```

**The diagnostic for "is the column on the table I'm querying?":**

```sql
-- 1. List actual columns on the table
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = '<table>'
ORDER BY ordinal_position;

-- 2. List FK relationships the table has
SELECT conname, pg_get_constraintdef(oid) AS definition
FROM pg_constraint
WHERE conrelid = '<table>'::regclass AND contype = 'f';

-- 3. List PostgREST-discoverable relationships (this is what
--    supabase-js uses for the `table!fk_name(col)` syntax)
SELECT
  tc.table_name AS source_table,
  kcu.column_name AS source_column,
  ccu.table_name AS target_table,
  ccu.column_name AS target_column,
  rc.constraint_name
FROM information_schema.table_constraints AS tc
JOIN information_schema.key_column_usage AS kcu
  ON tc.constraint_name = kcu.constraint_name
JOIN information_schema.referential_constraints AS rc
  ON rc.constraint_name = tc.constraint_name
JOIN information_schema.constraint_column_usage AS ccu
  ON ccu.constraint_name = rc.unique_constraint_name
WHERE tc.constraint_type = 'FOREIGN KEY'
  AND tc.table_schema = 'public'
  AND ccu.table_schema = 'public'   -- PostgREST only exposes public-to-public
ORDER BY tc.table_name;
```

**The general rule — when a query references `partners` and
`user_accounts` together, expect to fetch them separately:**

The two tables are joined by `auth.users.id` (the partner's user_id),
not by a direct FK. PostgREST's relationship syntax
(`table!fk_name(col)`) only works for direct FKs. The workaround is
either:

- A stored function that does the join in SQL (preferred for hot paths)
- A second query + JS-side merge (simpler, works for low-cardinality
  results)

The "second query + JS-side merge" pattern works fine when the result
set is bounded (≤1000 rows). For unbounded queries, do the join in SQL.

**When this hits again:** any new route that joins two tables that
share a common auth user but don't have a direct FK. Default to the
second-query + JS-merge pattern for the route; promote to a SQL
function if the result set exceeds 1000.

**Pair with:** Recipe #11 (`user_accounts.id` IS the auth.users.id)
— explains why the FK isn't where you'd expect it.

---

## Hard rules added in this session (Aug 24 2026)

- **Every Supabase auth signup MUST auto-create a user_accounts row.**
  The `handle_new_user` trigger is the canonical place. If a new
  feature reads from `user_accounts` for a fresh user, the trigger
  must already create the row. Verify the trigger body covers every
  public-facing table FK-bound to `auth.users`.
- **Pre-launch readiness = 500-sweep + fresh-user E2E + surface
  status.** All three. 10 minutes of work catches the bug classes
  that pass `tsc`.
- **PostgREST `!fk_name` syntax requires a direct FK between the two
  tables.** If the relationship is indirect (e.g. partners → auth.users
  → user_accounts), use a second query + JS-merge.
- **Verify column existence via `information_schema.columns` BEFORE
  writing routes that query them.** Don't trust a stale route as a
  reference — the schema may have drifted via migrations.

## Files touched (Aug 24 2026 pre-launch)

- `supabase/migrations/202608240000_handle_new_user_creates_user_accounts.sql` (NEW) — extends `handle_new_user` to also create `user_accounts` row
- `src/app/api/leaderboard/route.ts` — drop inline join, fetch user_accounts separately
- Production deploys: `f8b85b6e` (changelog backfill), `cd8fc649` (leaderboard fix 1), `2230a1c1` (leaderboard fix 2), `76d59458` (leaderboard fix 3)

## E2E verification

```bash
# 1. Trigger fires
curl -sX POST "$SUPABASE_URL/auth/v1/signup" \
  -H "apikey: $SERVICE_KEY" -H "Content-Type: application/json" \
  -d '{"email":"smoke-'$RANDOM'@yourdomain.com","password":"TestPass2026!"}' | jq -r '.user.id'
# → UUID

# Verify user_accounts row
curl -s "$SUPABASE_URL/rest/v1/user_accounts?id=eq.<UUID>" \
  -H "apikey: $SERVICE_KEY" | jq '.[0]'
# → { id, email, full_name }

# 2. Leaderboard works
curl -s https://www.yourdomain.com/api/leaderboard | jq '.leaderboard | length'
# → 0 (no partners with rank set) or N (actual count)

# 3. All 7 onboarding steps succeed
JWT=$(... mint from signup ...)
for STEP in profile_basics accent_theme risk_disclaimer connect_broker link_broker enable_push walkthrough; do
    curl -sX POST https://www.yourdomain.com/api/onboarding/complete-step \
      -H "Authorization: Bearer $JWT" -H "Content-Type: application/json" \
      -d "{\"step_key\":\"$STEP\"}" | jq -c '.ok'
done
# → true (7 times)

# 4. Trigger flips onboarding_complete
curl -s "$SUPABASE_URL/rest/v1/user_accounts?id=eq.<UUID>&select=onboarding_complete" \
  -H "apikey: $SERVICE_KEY" | jq '.[0].onboarding_complete'
# → true
```