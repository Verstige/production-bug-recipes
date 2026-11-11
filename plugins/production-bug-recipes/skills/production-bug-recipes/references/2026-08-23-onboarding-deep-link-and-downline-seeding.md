# Aug 23 2026 — Onboarding deep-link + downline seeding + PGRST204 idempotency

Companion to `2026-08-23-onboarding-lifecycle-recovery.md` and Recipe #20. Three
new patterns that surfaced after the lifecycle Round 2 was deployed — the
first two came from the user reporting a stuck onboarding flow, the third
from a mass downline backfill.

## Recipe #23 — The "no ref_id column on existing tables" idempotency trip

**Symptom:** you call an upsert or RPC that updates a row in `referral_tree`,
`quiz_attempts`, `user_progress`, `engine_unlock_log`,
`points_ledger`, etc. The error:

```
PostgresError { code: 'PGRST204', details: "Could not find the 'ref_id' column of 'X' in the schema cache" }
```

The error only fires for one of several similar tables — the others work
fine. After a successful push you see the error, restart the API, and
still see it.

**Root cause:** the existing app's `psql` schema and the Supabase PostgREST
schema cache are out of sync. Either:

- The PostgREST cache (`/rest/v1/...` introspection) hasn't seen the latest
  schema changes — most common, fixes with a `NOTIFY pgrst, 'reload schema'`
- The column genuinely doesn't exist on that table (this round's onboarding
  `risk_acknowledged_at` was this — fixed via migration)

**The diagnostic — check the table directly via PostgREST:**

```bash
curl -sL "https://<project>.supabase.co/rest/v1/<table>?select=*&limit=1" \
  -H "apikey: *** -H "Authorization: Bearer ***"
# 200 + empty array → table exists, columns fine
# 400 + PGRST204 → either column doesn't exist or cache stale
```

If the column truly doesn't exist, check the actual schema:

```sql
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = '<table>'
ORDER BY ordinal_position;
```

**The fix — three layers in order of likelihood:**

1. **Reload the PostgREST schema cache** (handles "PGRST204 + column actually
   exists" cases). The Supabase pattern is the `pg_notify` call:

   ```sql
   NOTIFY pgrst, 'reload schema';
   ```

   Then retry the request. ~80% of the time this is the answer.

2. **If the column truly doesn't exist, run a one-off migration** adding it:

   ```sql
   -- One-off forward fix. Goes in supabase/migrations/<next-timestamp>_<name>.sql.
   ALTER TABLE public.<table> ADD COLUMN IF NOT EXISTS <column> <type>;
   ```

   Push via `supabase db push --include-all --dns-resolver https`. Verify
   with `NOTIFY pgrst, 'reload schema';` and re-test.

3. **If a ref_id column exists but is NOT NULL with no default**, the upsert
   fails on existing rows. Add a default:

   ```sql
   ALTER TABLE public.<table>
     ALTER COLUMN ref_id SET DEFAULT 'manual_admin:<email>:<uuid>';
   ```

   Or make it nullable, depending on the schema's intent.

**The agent-loop guard** — when running the partner-listener cron every 5
minutes, a 400 from a single RPC shouldn't poison the whole poll. Use the
same try/catch pattern as the downline-seeding one in Recipe #24: catch
the error, log it, continue with the next event:

```ts
const results = await Promise.all(
  events.map(async (e) => {
    try {
      const { error } = await supabase
        .from('partner_rank_log')
        .insert({ user_id: e.user_id, old_rank: e.old_rank, new_rank: e.new_rank })
      if (error) {
        console.warn('[partner-listener] insert failed for', e.user_id, error.message)
        return { ok: false, error }
      }
      return { ok: true }
    } catch (e: any) {
      console.warn('[partner-listener] insert threw for', e.user_id, e?.message?.slice(0, 200))
      return { ok: false, error: e }
    }
  }),
)
```

**When this hits again:** any time an upsert/insert fails with PGRST204 or a
column-not-found on an existing table. Try the NOTIFY reload first; 4 out
of 5 times that's the fix. The other 1 out of 5 is a missing column → run
a forward-fix migration. The downline-seeding pattern in Recipe #24 also
uses `IF NOT EXISTS` style inserts to make this class of failure
auto-recoverable on retry.

---

## Recipe #24 — Idempotent downline-seeding pattern for the partner tree

**Symptom:** the user (a partner) says "I referred all my members — make them
show up in my downline table." None of the existing members have a
`referral_tree` row pointing at the partner because the original signup
flow either didn't capture a referral code (early days of the platform)
or the partner was onboarded after the fact. The partner portal's downline
table is empty.

**The class of work:** any time the operator wants to backfill or
bootstrap a partner's downline. Same shape: create `partners` rows for
non-partner users, link them to the parent partner via `referral_tree`.

**The right code path — three steps in one atomic-ish pass:**

1. **Read both sides (don't trust memory):**
   - The partner's `partners` row (`id` is the FK used by `referral_tree.parent_partner_id`)
   - Each candidate user's `auth.users.id` AND `user_accounts.id` (the FK
     used by `partners.user_id`)

2. **For each candidate, idempotent insert-or-skip into `partners`:**

   ```ts
   const existing = await supabase
     .from('partners')
     .select('id, affiliate_code')
     .eq('user_id', candidateUserId)
     .maybeSingle()
   if (existing) {
     childPartnerId = existing.id
   } else {
     const code = `PARTNER-${suffixFromEmail}-${uuid4.slice(0, 4).toUpperCase()}`
     const { data: newPartner } = await supabase
       .from('partners')
       .insert({
         user_id: candidateUserId,
         affiliate_code: code,
         referral_link: `https://yourdomain.com/ref/${code}`,
         tier: 1,
         is_partner: false,
       })
       .select('id')
       .single()
     childPartnerId = newPartner.id
   }
   ```

3. **Insert the `referral_tree` edge — but check for FK violations:**

   ```ts
   const edge = await supabase
     .from('referral_tree')
     .insert({
       parent_partner_id: parentPartnerId,
       child_partner_id: childPartnerId,
       tier: 1,
       referral_code_used: 'ADMIN-PARTNER',
     })
   ```

   **The trap here:** if you typo the `child_partner_id` (e.g. 8 hex chars
   truncated from 36), the FK constraint throws `23503` and the whole row
   fails. **Always validate UUIDs are full 36-char before inserting.**

   ```bash
   # The 8-char vs 36-char trap
   9afd42bc → 400 "key not present in partners"
   <user-uuid> → 200 OK
   ```

   When you are in the sandbox and listing partners from a query, double-
   check the full ID with a `length` check before copying into your
   insert body.

**The diagnostic for "why didn't my insert work":**

```bash
curl -sL "https://<project>.supabase.co/rest/v1/partners?user_id=eq.<uuid>&select=id,affiliate_code" \
  -H "apikey: *** -H "Authorization: Bearer ***"
```

**The full pattern in a bash script:**

```bash
SERVICE_KEY="..."
PARENT_PARTNER_ID="..."
NON_PARTNERS=(
  "uuid1:email1@example.com"
  "uuid2:email2@example.com"
)
for entry in "${NON_PARTNERS[@]}"; do
  uuid="${entry%:*}"
  email="${entry#*:}"
  EXISTING=$(curl -sL "${PROJ}/rest/v1/partners?user_id=eq.${uuid}&select=id" \
    -H "apikey: ${SERVICE_KEY}" -H "Authorization: Bearer ${SERVICE_KEY}")
  if [ "$(echo $EXISTING | jq 'length')" -gt 0 ]; then
    CHILD_ID=$(echo $EXISTING | jq -r '.[0].id')
    echo "  ↳ $email already has partner $CHILD_ID"
  else
    code="PARTNER-$(echo $email | sed 's/@.*//' | tr 'a-z' 'A-Z' | head -c 6)-$(uuidgen | head -c 4 | tr 'a-z' 'A-Z')"
    CHILD_ID=$(curl -sX POST "${PROJ}/rest/v1/partners" \
      -H "apikey: ${SERVICE_KEY}" -H "Authorization: Bearer ${SERVICE_KEY}" \
      -H "Content-Type: application/json" -H "Prefer: return=representation" \
      -d "{\"user_id\":\"${uuid}\",\"affiliate_code\":\"${code}\",...}" | jq -r '.[0].id')
    echo "  + created partner $code for $email"
  fi
  curl -sX POST "${PROJ}/rest/v1/referral_tree" \
    -H "apikey: ${SERVICE_KEY}" -H "Authorization: Bearer ${SERVICE_KEY}" \
    -H "Content-Type: application/json" \
    -d "{\"parent_partner_id\":\"${PARENT_PARTNER_ID}\",\"child_partner_id\":\"${CHILD_ID}\",\"tier\":1}"
done
```

**The audit at the end:**

```bash
curl -sL "${PROJ}/rest/v1/referral_tree?parent_partner_id=eq.${PARENT_PARTNER_ID}&select=child_partner_id" \
  -H "apikey: ${SERVICE_KEY}" -H "Authorization: Bearer ${SERVICE_KEY}" | jq 'length'
# Should equal the number of non_partners you seeded
```

Then verify in the running app:

```bash
curl -sL "https://<domain>/api/partners/dashboard" -H "Authorization: Bearer $JWT" | \
  python3 -c "import json,sys; d=json.load(sys.stdin); print(f'downline_count={d[\"downline_count\"]}'); [print(f'  {r[\"fullName\"]} ({r[\"email\"]}) lifecycle={r.get(\"lifecycle\",{}).get(\"partner_status\",{}).get(\"pill\")}') for r in d['downline']]"
```

**When this hits again:** any "I referred all my members — wire them up" or
"add this user as a tier-1 downline of mine" task. The pattern is always:
idempotent check, insert with synthetic code, link with `referral_tree` edge.
The trap is always the FK violation from a truncated UUID — verify every
UUID is full 36 chars before inserting.

---

## Recipe #25 — Onboarding deep-link: `?brokerOpenConnect=1` for modal-trigger flows

**Symptom:** the user is on the `/onboarding` wizard at step 4
(`connect_broker`) or step 5 (`link_broker`). They click the "Open"
CTA. The button does nothing — no navigation, no error, no console
message. The page stays on `/onboarding`. The user reports
"I can't continue and bypass the onboarding."

**Root cause:** the wizard's `actionForStep()` was hardcoding
`route: '/dashboard/trading?tab=BROKER'` and
`route: '/dashboard/trading?tab=BROKER'`. **Neither tab id exists**
— the trading page's `sections-data.tsx` has no `BROKER` / `BROKER`
/ broker ids, so the URL lands on `/dashboard/trading?tab=...` with no
matching state, and the user gets bounced back to `/onboarding` by the
hard-redirect gate.

The fix is the deep-link pattern: use a `?<verb>=1` query param, not a
tab id.

```ts
// src/lib/onboarding/steps.ts
{
  key: 'connect_broker',
  title: 'Connect your broker',
  route: '/dashboard/trading?brokerOpenConnect=1',  // was '?tab=BROKER'
  required: true,
},
{
  key: 'link_broker',
  title: 'Link the broker for trading',
  route: '/dashboard/trading?brokerOpenConnect=1',  // was '?tab=BROKER'
  required: true,
},
```

**The receiving side — listen for the deep-link in `TradingDashboardView`:**

```tsx
// src/components/trading/TradingDashboardView.tsx
useEffect(() => {
  if (typeof window === 'undefined') return
  try {
    const url = new URL(window.location.href)
    if (url.searchParams.get('brokerOpenConnect') === '1') {
      setShowConnectionModal(true)
      url.searchParams.delete('brokerOpenConnect')
      window.history.replaceState({}, '', url.toString())
    }
  } catch {}
}, [])
```

**The companion fix — add a "Refresh status" button to the wizard.** The new
lifecycle RPC auto-grades steps from live data (avatar set, broker row,
broker token valid, etc.), but the wizard's `lifecycle` state only re-fetches
on:
- The `app-refresh-profile` window event
- A manual page reload

Users who did the underlying task but didn't trigger any of these end up
stuck with a step showing `pending` even though the data is now valid. The
fix is a one-line "Refresh status" button next to the progress meta:

```tsx
<button
  type="button"
  className="onb-refresh"
  onClick={handleRefresh}
  disabled={refreshing}
  aria-label="Refresh your onboarding status"
>
  <RefreshCw size={12} className={refreshing ? 'is-spin' : ''} />
  {refreshing ? 'Refreshing…' : 'Refresh status'}
</button>
```

```ts
const handleRefresh = useCallback(async () => {
  setRefreshing(true)
  try {
    await fetchLifecycle()  // re-hits /api/onboarding/lifecycle
  } finally {
    setTimeout(() => setRefreshing(false), 350)
  }
}, [])
```

**The diagnostic — verify the deep-link works end-to-end:**

```bash
curl -sL "https://<domain>/api/admin/get-step?key=connect_broker" \
  -H "Authorization: Bearer $JWT"
# Should return: { route: '/dashboard/trading?brokerOpenConnect=1' }

grep -n "brokerOpenConnect" src/components/trading/TradingDashboardView.tsx
```

**The audit — search for stale `tab=` ids in any onboarding-related routes:**

```bash
grep -rn "tab=BROKER\|tab=BROKER" src/ | grep -v ".test."
# Should return zero hits. Any hit is a dead link waiting to happen.
```

**When this hits again:** any wizard step that needs to trigger a modal/UI
flow (not just navigate to a page). The pattern:
1. Define a `?<verb>=1` query param in the route
2. The receiving page reads the param on mount, opens the modal, then strips
   the param (so refresh doesn't re-open)
3. `replaceState` instead of `pushState` so the URL change doesn't pollute
   browser history
4. The wizard's "Open" link uses the deep-link route — never a tab id or
   other fragile internal state

**Companion rule — for any "user reports button does nothing" complaint on
the onboarding flow:**
- Run `grep "<step_key>.*route:\|tab=BROKER\|tab=BROKER" src/lib/onboarding/steps.ts`
  to find dead links
- Check the receiving page's `useEffect` for the deep-link param
- Verify the param is stripped after consumption

**Pair with:** Recipe #20 for the supabase CLI workflow when the dead link
is fixed via a migration.

---

## Hard rules added in this session (Aug 23 2026)

- **Never use `?tab=...` query params as internal UI state for the trading
  page.** The trading page has a fixed set of canonical tab ids. Use a
  custom query param (`?brokerOpenConnect=1`, `?showPnL=true`, etc.) for any
  ad-hoc state that needs to be passed through a route.
- **The `partner_tree` schema is partner_id-to-partner_id**, not user_id.
  The FKs are `parent_partner_id` (partners.id) and `child_partner_id`
  (partners.id). A user must be a partner to appear in any tree. If you
  want to add a non-partner user to a tree, you must first create a
  partner row for them with `is_partner=false`.
- **Always validate UUID length before insert** in the sandbox. Truncated
  UUIDs cause `23503` FK errors that look like "the user doesn't exist"
  when the actual problem is "you copied 8 chars instead of 36".
- **The `?brokerOpenConnect=1` deep-link pattern is the canonical way for any
  onboarding step that needs to trigger a modal flow.** New steps should
  reuse the same param (or define a new one for a different modal).

## Files touched (local, not yet committed at session end)

- `src/lib/onboarding/steps.ts` — deep-link routes for the two broker
  steps
- `src/components/trading/TradingDashboardView.tsx` — `useEffect` listener
  for the deep-link
- `src/app/onboarding/page.tsx` — Refresh status button + `handleRefresh`
  callback
- `src/app/onboarding/onboarding.css` — `.onb-refresh` button + spinner
  styles
