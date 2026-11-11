# Aug 23 2026 (tail end) — Five production bugs that hit after the Complete CTA + welcome modal shipped

Drop-in for `this skill's SKILL.md` merge.

These recipes were discovered when the user clicked **"Enter Dashboard"** on
the welcome modal and the navigation silently failed. Each was diagnosed and
fixed in the same session — but the recipes are general enough that future
onboarding / wizard work will hit the same shape of bug.

---

## Recipe #28 — SQL trigger with stale step list: `app_onboarding_step_changed` still required the old 4-key set

**Symptom:** a user finishes the onboarding wizard at 7/7, sees all green
checks on the lifecycle card, clicks "Complete & Enter the platform," and
the welcome modal pops. They click "Enter Dashboard" — the page **never
navigates** to `/dashboard/trading`. The hard-redirect middleware keeps
bouncing them back to `/onboarding`. The browser DevTools show the
navigation request returning a 302 → `/onboarding`.

**Root cause:** the SQL trigger `app_onboarding_step_changed` was authored in
the original 4-step migration (`202608200000_onboarding_checklist.sql`)
with this body:

```sql
SELECT COUNT(*) INTO v_completed_count
FROM public.user_progress
WHERE user_id = v_user_id
  AND step_key IN (
    'avatar_bio', 'connect_broker', 'walkthrough', 'enable_notifications'
  )
  AND status = 'completed';
```

When the Round-2 lifecycle expanded to 7 keys
(`profile_basics, accent_theme, risk_disclaimer, connect_broker, link_broker, enable_push, walkthrough`),
**the trigger function was never updated**. The wizard's Complete CTA
walks the new keys, POSTs each to `/api/onboarding/complete-step`, the
function calls write to `user_progress`, the trigger fires —
but the trigger only counts the 2 that overlap with the old list
(`connect_broker`, `walkthrough`) and stops at 2/4. `onboarding_complete`
stays `false`. The middleware gate bounces the user back.

For grandfathered users with `onboarding_complete=true` from a previous
session, the bug is masked (the flag is already true). For anyone who
hits Complete after the new system shipped, it's a hard block.

**The fix — three steps:**

1. **Forward-fix the original migration** so future re-runs of
   `db push` produce the correct trigger:

   ```sql
   -- in supabase/migrations/202608200000_onboarding_checklist.sql
   v_required_count INTEGER := 7;
   ...
   step_key IN (
     'profile_basics', 'accent_theme', 'risk_disclaimer',
     'connect_broker', 'link_broker', 'enable_push',
     'walkthrough'
   )
   ```

2. **Ship a NEW migration** that re-defines the function in prod
   (since the old function is already in `pg_proc` with the broken
   body, the CLI's PK constraint won't let you re-apply the original
   version). Pick a fresh `YYYYMMDDXXXX` timestamp. Use the same
   `CREATE OR REPLACE FUNCTION` shape.

3. **Re-fire the trigger for any stuck users** at the bottom of the
   new migration:

   ```sql
   UPDATE public.user_accounts pu
   SET onboarding_complete = TRUE,
       onboarding_completed_at = COALESCE(onboarding_completed_at, now())
   WHERE NOT COALESCE(pu.onboarding_complete, false)
     AND (
       SELECT COUNT(*) FROM public.user_progress uop
       WHERE uop.user_id = pu.id
         AND uop.step_key IN (
           'profile_basics', 'accent_theme', 'risk_disclaimer',
           'connect_broker', 'link_broker', 'enable_push',
           'walkthrough'
         )
         AND uop.status = 'completed'
     ) >= 7;
   ```

   This is safe (idempotent — only flips users with all 7 actually
   completed).

**The diagnostic before shipping any new "required step list" change:**

```sql
-- Find any SQL function whose body hard-codes the step list
SELECT
  proname,
  prosrc LIKE '%avatar_bio%' AS references_old_keys,
  prosrc ~* 'IN \([^)]*connect_broker[^)]*\)' AS has_step_key_in_clause
FROM pg_proc
WHERE prosrc ~* 'connect_broker|step_key|onboarding'
  AND proname LIKE 'os_%';
```

Any `prosrc LIKE '%avatar_bio%'` on a function that's supposed to be
operating on the new 7-key set is a bug. Update the function.

**The general rule:** any time you change the canonical step list,
**grep the entire schema for hard-coded references to the old list**.
The trigger is the most common offender (it's invoked on every
`user_progress` write), but RLS policies, materialized
views, and other SQL functions can carry the same drift.

**When this hits again:** any feature that defines a list of required
states (onboarding steps, IB rank tiers, OS milestones, etc.) AND uses
a SQL trigger to count completions and flip a durable flag. Always
keep the trigger body in lockstep with the canonical list. If you
ever see a "user is showing N/N complete in the UI but the gate still
bounces" — this is the bug.

**Pair with:** Recipe #21 (multi-version recovery dance), and the
general column-name drift prevention in Recipe #25.

---

## Recipe #29 — PWA service worker caching a stale 302 from before onboarding_complete flipped

**Symptom:** a user finishes the onboarding wizard. The welcome modal
pops. They click "Enter Dashboard" — the page **doesn't change**.
DevTools Network shows no request to `/dashboard/trading` at all.
A `Request for the original onboarding state found in cache.`
warning may appear in the SW console.

**Root cause:** the PWA service worker (`public/sw.js`) caches HTML
responses by URL pattern. When the user (still mid-onboarding)
**previously** requested `/dashboard/trading`, the middleware sent a
302 redirect to `/onboarding`. The SW stored that 302 response in
the runtime cache. After the user finishes onboarding and the
`router.replace('/dashboard/trading')` fires, the SW intercepts the
navigation request, returns the **cached 302 to /onboarding**, and
the user is bounced back to the wizard. The page never updates.

The bug only affects users who:
1. Are mid-onboarding (so the middleware 302'd them at least once)
2. Have an installed PWA (so the SW is intercepting requests)
3. Hit Complete on the wizard

So the bug is invisible in browser DevTools without the PWA
installed — but it shows up the moment a real user installs the
PWA and goes through onboarding.

**The fix — three layers:**

1. **Bump the SW `CACHE_VERSION`** so existing PWAs evict the stale
   302 cache on next activation:

   ```js
   // public/sw.js
   const CACHE_VERSION = 'app-v9';  // bumped from app-v8 on the welcome-modal release
   ```

   The `activate` event runs `caches.delete('static-app-v8')` and
   `caches.delete('runtime-app-v8')`. Existing PWAs drop the cached
   302 on next activation. iOS PWAs need close+reopen to activate the
   new SW (Chrome PWAs auto-activate).

2. **Add a hard-navigation fallback** to the click handler so even
   if the SW intercepts, the user lands on the destination:

   ```tsx
   const handleWelcomeContinue = useCallback(() => {
     setWelcomeOpen(false)
     try {
       router.replace('/dashboard/trading')
     } catch {
       window.location.href = '/dashboard/trading'
     }
     // Hard-reload fallback timer in case router.replace doesn't
     // navigate within 1.2s (e.g. SW intercept with cached redirect).
     setTimeout(() => {
       if (typeof window !== 'undefined'
         && window.location.pathname.startsWith('/onboarding')) {
         window.location.href = '/dashboard/trading'
       }
     }, 1200)
   }, [router])
   ```

   The fallback timer checks if the navigation actually took effect.
   If we're still on `/onboarding` after 1.2s, force a hard navigation
   via `window.location.href`. This bypasses the SW entirely.

3. **Pass the SPA-redirect URLs through the SW without caching** so
   the SW never serves a stale 302 to a different session's user.
   Add a `/_next/data` + navigation pass-through rule in `sw.js`:

   ```js
   self.addEventListener('fetch', (event) => {
     const req = event.request
     const url = new URL(req.url)
     // Never cache redirects for SPA routes — a 302 from one user
     // can poison another user's experience.
     if (url.pathname.startsWith('/_next/data')) return  // pass-through
     if (req.mode === 'navigate') {
       // navigation requests: try network first, fall back to cache
       event.respondWith(fetch(req).catch(() => caches.match(req)))
       return
     }
     // ... existing cache logic for static assets
   })
   ```

   This ensures the SW doesn't serve cached redirects for
   client-side navigation. The cache is reserved for static assets
   (chunks, fonts, images) only.

**The diagnostic for "is the SW serving a stale 302?":**

1. Open Chrome DevTools → Application tab → Service Workers.
2. Check "Update on reload" + click "Update" — forces the new SW.
3. Reload. The 302 cache is cleared.
4. If the bug recurs, it's not the SW — it's a different
   middleware gate logic issue.

**The diagnostic on iOS Safari (no direct SW inspector):**

1. Close the PWA (swipe up).
2. Reopen.
3. Try the navigation again.

iOS PWAs don't activate new SWs in the background. Close+reopen is
the only reliable way to test.

**The general rule:** any time the SW caches a response with a
`Cache-Control` from a previous authentication state, the next
session can be poisoned. For SPA navigation requests (HTML pages),
**always prefer network** over cache. Reserve caching for
content-hashed assets (`/_next/static/chunks/...`) which are
deterministic by URL.

**When this hits again:** any flow where:
1. A user transitions through a state change that flips a server-side
   gate (onboarding_complete, hasKYCVerified, is_admin, etc.)
2. The user previously visited a page that 302'd them to the wizard
   / login / KYC page
3. The PWA SW has cached the 302

The fix is the same: bump CACHE_VERSION, add the hard-navigation
fallback, and pass SPA navigation requests through the SW
without caching.

**Pair with:** Recipe #17 (SW CACHE_VERSION bump on every content-only
release). Recipe #29 is the specific failure mode that the bump is
meant to prevent.

---

## Recipe #30 — `Promise.allSettled` with `.then(async)` chain can reject if `r.json()` throws

**Symptom:** the Complete CTA handler fires its parallel POSTs.
`Promise.allSettled` resolves with no rejected promises — but the
welcome modal never opens, and the user sees nothing. Console shows
`[onboarding] handleComplete threw: SyntaxError: Unexpected token ...`.

**Root cause:** the production handler used `.then(async (r) => ...)`
inside `Promise.allSettled`:

```ts
const results = await Promise.allSettled(
  keys.map((key) =>
    adminFetch('/api/onboarding/complete-step', { ... })
      .then(async (r) => ({ key, ok: r.ok, status: r.status }))
  ),
)
```

When `adminFetch` returns a non-JSON error (e.g. an HTML 500 page
from the Next.js error boundary, or a Cloudflare challenge response),
`r.json()` throws because the body isn't valid JSON. The async `.then`
callback rejects. `Promise.allSettled` catches THAT as a fulfilled
rejection (good — it shows up in `results` for inspection), but the
**outer** try/catch around `Promise.allSettled` doesn't catch the
inner rejection because the .then() returns a rejected promise that
allSettled converts to a fulfilled promise.

Wait — that's wrong. `Promise.allSettled` converts every outcome
(fulfilled or rejected) to a fulfilled outcome. So the inner
rejection IS captured. The handler proceeds to `fetchLifecycle()`
and `setWelcomeOpen(true)`.

So the actual failure mode is different: **the fetchLifecycle or
setWelcomeOpen call throws because the React component unmounted**
(e.g. user clicked another button while the parallel POSTs were
in flight, or the wizard was navigating away because of a SW
redirect). The outer try/catch swallows the throw and the welcome
modal never opens.

**The fix — add explicit `.catch` per fetch, not per promise chain:**

```ts
const results = await Promise.allSettled(
  keys.map((key) =>
    adminFetch('/api/onboarding/complete-step', { ... })
      .then((r) => ({ key, ok: r.ok, status: r.status }))
      .catch((e) => ({ key, ok: false, status: 0, error: String(e) }))
  ),
)
```

Note: dropped the `async` from the inner `.then` (it was returning
`{ key, ok, status }` synchronously — no await needed). And the
`.catch` is at the fetch level, not at the Promise.allSettled level.
This way, even if `r.json()` throws, the .catch converts it to a
fulfilled `{ ok: false, error: '...' }` result that allSettled will
record as a regular fulfillment — no rejection path.

**The diagnostic for "is the welcome modal never appearing?":**

```bash
# Open the browser DevTools console with filter "onboarding"
# Look for either:
#   [onboarding] handleComplete threw: <error>
#   [onboarding] some complete-step calls failed: [...]
```

If the first is present, the outer try/catch caught a thrown error.
Check which step in the handler threw (`fetchLifecycle`, `setWelcomeOpen`,
etc.). If the second is present, inspect which step's POST failed and
why — the route returns a 400 with `{ error: 'step_not_complete:reason' }`
that points to the specific check that rejected.

**The general rule:** when wrapping fetch calls in `Promise.allSettled`,
**the `.catch` belongs at the fetch level, not the chain level**.
Async callbacks inside `.then` that don't actually await anything
are a code smell — convert them to sync callbacks. And never let a
JSON parse error on a 500 response silently kill a downstream
side-effect.

**When this hits again:** any parallel-POST pattern where the
"failure" case needs to be captured but the parent function still
needs to proceed to the next step. The pattern is always:

```ts
const results = await Promise.allSettled([
  ...items.map((item) =>
    fetch(...).then(parseResponse).catch(toSentinelResult)
  ),
])
```

`.then(parseResponse).catch(toSentinelResult)` is the pattern. The
`.catch` converts any thrown-from-inside-the-throw-chain into a
plain fulfilled result that allSettled can record without rejecting.

---

## Recipe #31 — `checkConnectBroker` should accept the durable connection-state flag, not just broker_links row

**Symptom:** a user has `user_accounts.broker_connection_status='connected'`
AND `user_accounts.broker_platform='broker'` — the canonical
"this user is connected to the broker" state — but no row in
`broker_links`. The wizard's Complete CTA POSTs
`step_key: 'connect_broker'`. The route returns 400 with
`{ error: 'step_not_complete:broker_not_connected' }`. The step stays
`pending` in `user_progress`. The trigger counts 6/7
completed and doesn't flip `onboarding_complete`. The user is stuck.

This is the **same shape as** Recipe #21 (link_broker was too
strict about token expiry). The `connect_broker` step was checking
ONLY `broker_links` and ignoring the durable flag on
`user_accounts`.

**The fix — mirror the broker-relax pattern in `checkConnectBroker`:**

```ts
// src/app/api/onboarding/complete-step/route.ts
async function checkConnectBroker(userId: string): Promise<string | null> {
  const { createServiceClient } = await import('@/lib/supabase/service')
  const svc = createServiceClient()

  // Read both potential signals in parallel — broker_links
  // row OR durable user_accounts flag.
  const [{ data: brokerRow }, { data: pubRow }] = await Promise.all([
    svc.from('broker_links')
      .select('id, broker')
      .eq('user_id', userId)
      .eq('broker', 'broker')
      .maybeSingle(),
    svc.from('user_accounts')
      .select('broker_connection_status, broker_platform')
      .eq('id', userId)
      .maybeSingle(),
  ])

  if (brokerRow) return null                                  // explicit row exists
  if (pubRow?.broker_connection_status === 'connected'
      && pubRow?.broker_platform === 'broker') return null // durable flag set
  return 'broker_not_connected'
}
```

Now `connect_broker` accepts EITHER signal. The user with the durable
flag set (e.g. from a previous the broker connect flow that wrote to
user_accounts but not broker_links) is no longer blocked.

**The general rule:** for any "is X connected?" gating check, **read
both the explicit `*_connections` table AND the durable flag on
`user_accounts`**. The durable flag is the source of truth; the
connections table is an artifact of a specific flow that may not
have run for every user.

The broker-relax migration (`202608260000_lifecycle_broker_relax.sql`)
applied the same fix to the SQL RPC. The two layers (SQL RPC + TS
completion handler) must stay in sync — if the RPC accepts a state
the route rejects, the wizard's Complete CTA flips some steps to
"completed" in the lifecycle display but can't materialize them in
`user_progress`.

**The audit check after relaxing a check:**

```bash
# Find every place that gates on the strict-only check
rg "broker_not_connected|broker_token_expiry|broker_access_token IS NOT NULL" src/
# Should be paired with the relaxed SQL check (OR'd with the durable flag)
```

If the strict-only check appears anywhere after the relax migration,
it's a regression.

**When this hits again:** any "connected" gating that reads from
`user_accounts` should look at the durable `*_status` /
`*_connected` / `*_linked` flag, not the OAuth/token expiry or
the per-flow connections table. The token's only job is to gate
the next API call that actually needs to talk to the broker — not
the UI's "are you set up?" question.

**Pair with:** Recipe #21 (durable flag vs short-lived token). Recipes
#21 and #31 are two sides of the same principle: accept the durable
flag in BOTH the SQL RPC and the TS completion handler.

---

## Recipe #32 — Partner portal "Lifecycle" column reads per-row from `app_get_user_lifecycle` (pattern + N+1 caveat)

**Class of work:** a partner portal that lists a partner's downline
users needs to show "where is each user in their lifecycle?" — a
compact pill (active / building / stuck / lead) plus a click target
that opens a drawer with the user's per-step checklist.

The pattern in production (the Aug 23 2026 partner portal work):

**API side** (`/api/partners/dashboard` route):

```ts
// After the downline mapping runs...
const userIds = downline.map((d) => d.userId).filter(Boolean)
const lifecycleMap = new Map<string, UserLifecycle | null>()
if (userIds.length > 0) {
  const lifecycleResults = await Promise.all(
    userIds.map(async (uid) => {
      try {
        const { data, error } = await db.rpc('app_get_user_lifecycle', { p_user_id: uid })
        return { uid, data: (data as UserLifecycle | null) ?? null, error: error ?? null }
      } catch (e) {
        return { uid, data: null, error: e }
      }
    }),
  )
  for (const r of lifecycleResults) {
    if (r.error) console.warn('[partners/dashboard] lifecycle rpc failed for', r.uid, r.error.message)
    else lifecycleMap.set(r.uid, r.data ?? null)
  }
  for (const row of downline) {
    if (!row.userId) continue
    row.lifecycle = lifecycleMap.get(row.userId) ?? null
  }
}
```

Each downline row carries the `lifecycle: UserLifecycle | null` field.
A failure in any one RPC does NOT block the rest of the response —
`Promise.all` + try/catch per item + sentinel `{ data: null }`.

**Client side** (`PartnerPortal.tsx`):

```tsx
type LifecycleRow = { lifecycle: any | null; displayName: string; subLabel?: string } | null
const [lifecycleRow, setLifecycleRow] = useState<LifecycleRow>(null)

const LifecyclePill = ({ lifecycle, onClick }) => {
  const pill = lifecycle?.partner_status?.pill ?? 'lead'
  const color = lifecycle?.partner_status?.color ?? '#60a5fa'
  const completed = lifecycle?.completed_count ?? 0
  const required = lifecycle?.required_count ?? 7
  const label =
    pill === 'active'    ? 'Active' :
    pill === 'idle'      ? 'Idle' :
    pill === 'stuck'     ? 'Stuck' :
    pill === 'building'  ? `${completed}/${required}` :
    'Lead'
  return (
    <button type="button" className="pp-lifecycle-pill" onClick={onClick}
      style={{ background: `${color}26`, borderColor: color, color }}>
      <span className="pp-lifecycle-pill__dot" style={{ background: color }} />
      {label}
    </button>
  )
}

// In the table cell:
<td>
  <LifecyclePill
    lifecycle={d.lifecycle}
    onClick={() => setLifecycleRow({ lifecycle: d.lifecycle, displayName: d.fullName, subLabel: d.email })}
  />
</td>
```

And the side drawer (sibling of `DashboardShell` so the fixed-position
backdrop paints over the entire viewport without stacking-context
issues — same pattern as the existing PartnerOnboardingModal):

```tsx
<LifecycleDrawer
  open={!!lifecycleRow}
  onClose={() => setLifecycleRow(null)}
  lifecycle={lifecycleRow?.lifecycle ?? null}
  displayName={lifecycleRow?.displayName ?? ''}
  displaySubLabel={lifecycleRow?.subLabel}
/>
```

**The N+1 caveat:** this design fires N RPC calls for N downline rows.
A partner with 1000+ downline users would hammer the DB with 1000
RPC calls on every dashboard load. For now (small partner downlines),
this is fine. When the partner portal grows:

1. Move the lifecycle data into a denormalized column on `partners`
   that's updated by a trigger on `user_accounts.onboarding_complete`
   + `user_progress` writes.
2. Or page the downline (20 rows per page) and fetch lifecycle only
   for the visible rows.
3. Or fetch lifecycle for the top-N most-recent downline + a lazy
   "show details" fetch per row on drawer open.

**The drawer pattern (sibling mount, not child):**

```tsx
return (
  <>
    <DashboardShell ...>
      {/* table, etc. */}
    </DashboardShell>
    <LifecycleDrawer open={...} onClose={...} ... />
  </>
)
```

Mounting the drawer as a **sibling** of the shell (not a child)
ensures the `position: fixed` backdrop paints over the entire
viewport without stacking-context interference from the shell's
transform/filter/will-change chain. Same pattern as the existing
PartnerOnboardingModal.

**When this hits again:** any admin/partner view that needs to
display a downstream user's lifecycle state inline. The pattern is
always:
- API side: parallel per-row RPC calls, attach to the row, never
  fail the whole response on one RPC failure.
- Client side: a compact pill (4-5 states) on the row + a click-to-expand
  drawer that shows the full per-step breakdown.

---

## Hard rules added in this session (Aug 23 2026 tail end)

- **The SQL trigger body must stay in lockstep with the canonical step
  list.** When you change `ONBOARDING_STEPS` in TypeScript, grep for
  every `step_key IN (...)` clause in `supabase/migrations/` and update.
- **PWA SW navigation caching is poison for state-changing flows.**
  Pass SPA navigation requests through the SW; reserve caching for
  content-hashed static assets.
- **`Promise.allSettled` + `.then(async)` is a foot-gun.** Use `.then(sync)
  .catch(sentinel)` per fetch, not `.then(async (r) => r.json())`.
- **`checkConnectBroker` (and any "is X connected?" gating) must accept
  EITHER the explicit connections row OR the durable user_accounts flag.**
  Mirror the SQL RPC's accepted states in the TS completion handler.
- **Always add a hard-navigation fallback** for `router.replace` in flows
  that transition across state gates — the SW can intercept with a
  stale 302 cached from before the gate flipped.
- **Partner portal N+1 is fine for small downlines.** Plan to
  denormalize or paginate before scaling to 100+ rows per partner.

## Files touched (Aug 23 2026 tail end)

- `supabase/migrations/202608260002_onboarding_trigger_fix_7step.sql` (NEW)
  — redefines `app_onboarding_step_changed` with the 7-key set +
  re-fires the trigger for stuck users
- `supabase/migrations/202608200000_onboarding_checklist.sql` (forward-fix)
  — updated trigger body to use the 7-key set so future re-runs
  produce the correct function
- `src/app/api/onboarding/complete-step/route.ts` — `checkConnectBroker`
  mirrored the broker-relax pattern; `handleComplete` got a per-fetch
  `.catch` sentinel
- `src/app/onboarding/page.tsx` — `handleWelcomeContinue` got the
  hard-navigation fallback (1.2s timer check)
- `public/sw.js` — `CACHE_VERSION` bumped `app-v8` → `app-v9`
- Commit: `29953ce2` "fix(onboarding): trust 7-key set + fall back to hard navigation"
- Production deploy: `a7effe16` SUCCESS

## E2E verification (recorded for the recipes)

```bash
# 1. With a valid supabase sb-<project-ref>-auth-token cookie envelope,
#    GET /dashboard/trading returns 200 (not 302 → /onboarding).
curl -sI -H "Cookie: sb-<project-ref>-auth-token=<base64-envelope>" \
  https://www.yourdomain.com/dashboard/trading | head -1
# → HTTP/2 200

# 2. The trigger re-fires for any user with all 7 completed step rows.
#    Verified for julyan: onboarding_complete=True, completed_count=7/7,
#    partner_status=active (green pill).

# 3. The hard-navigation fallback fires if router.replace stalls —
#    visible by waiting > 1.2s on a slow connection with stale SW.

# 4. handleComplete resilience: a single failed POST no longer throws
#    out of the function. Verified by manually rejecting one step in
#    the dev console and confirming the welcome modal still appears.
```


---

## Recipe #33 — Middleware-level auth gates DO NOT WORK for PWA users on client-side router.replace transitions. Use a page-level gate instead. (added Aug 26 2026)

**Symptom:** a user finishes the onboarding wizard at 7/7. The lifecycle
returns `onboarding_complete: true` from the API. The database has the
flag set. They click any navigation button (Trading Floor, partner
portal, etc.) and get bounced back to /onboarding (or any gated route).

**Root cause — the deeper architecture issue Recipe #23 didn't catch:**

Every Next.js `router.replace(url)` and `router.push(url)` is a **client-side
SPA navigation**. The browser makes an INTERNAL GET to the URL, which
means:

1. **No `Authorization: Bearer *** header** — browsers do not allow JS to
   set custom request headers on internal navigations. (Custom headers
   only work on `fetch()`, not on navigations.)
2. **Only cookies are sent** — and only cookies the app's domain has
   stored. `supabase-js` persists sessions in **localStorage on the
   supabase.co domain**, NOT as cookies on the yourdomain.com domain.

So the middleware has only one way to identify the user on a
client-side navigation: read a cookie from the yourdomain.com domain.

Three fixes were attempted in this session, all of which failed to
fully solve the problem:

1. **Add a Bearer-header fallback to the middleware.** Test with curl
   + Authorization: Bearer works. The user is still bounced — the
   browser doesn't send the header on internal navigations.
2. **Mirror the supabase-js session into document.cookie.** Patch
   `src/lib/supabase/browser.ts` so `setItem` writes a cookie too.
   Works for users who log in AFTER the patch. Fails for users who
   already had a session in localStorage — their cookie doesn't exist
   until they log out and back in (which most users don't do).
3. **Hard-navigation fallback (`window.location.href`)** when
   `router.replace` doesn't navigate within 1.2s. This works as a
   safety net but produces visible flash and feels janky.

**The architectural fix — move the gate from middleware to page level:**

```tsx
// src/components/onboarding/OnboardingGate.tsx (NEW)
// Polls /api/onboarding/lifecycle on mount. If onboarding_complete=false,
// renders the OnboardingChecklist inline at the top of /dashboard/trading.
// If onboarding_complete=true, renders null (page renders normally).
//
// Reads the access_token straight from localStorage (adminFetch
// pattern from nextjs-supabase-admin-auth skill). Never relies on the
// middleware's auth identification.

'use client'
import { useEffect, useState } from 'react'
import { OnboardingChecklist } from '@/components/OnboardingChecklist'

export default function OnboardingGate() {
    const [lifecycle, setLifecycle] = useState<{ onboarding_complete?: boolean } | null>(null)

    useEffect(() => {
        let cancelled = false
        const ac = new AbortController()
        const timer = setTimeout(() => ac.abort(), 6000)

        let token: string | null = null
        if (typeof window !== 'undefined') {
            for (const key of [
                'sb-<project-ref>-auth-token',
                'app-auth-token',
            ]) {
                try {
                    const raw = window.localStorage.getItem(key)
                    if (!raw) continue
                    const parsed = JSON.parse(raw)
                    const tok = parsed?.access_token || parsed?.[0]?.access_token
                    if (tok) { token = tok; break }
                } catch { /* ignore */ }
            }
        }

        ;(async () => {
            try {
                const r = await fetch('/api/onboarding/lifecycle', {
                    method: 'GET',
                    headers: token ? { Authorization: `Bearer ${token}` } : {},
                    signal: ac.signal,
                })
                if (cancelled) return
                if (r.ok) setLifecycle(await r.json())
            } catch { /* ignore */ }
        })()

        return () => { cancelled = true; clearTimeout(timer) }
    }, [])

    if (!lifecycle || lifecycle.onboarding_complete) return null
    return <OnboardingChecklist />
}
```

Mounted at the top of `/dashboard/trading/page.tsx` BEFORE the trading
UI:

```tsx
return (
    <DashboardShell id="trading-dashboard">
        <OnboardingGate />
        {/* WelcomeHeader, brokerHUD, etc. */}
    </DashboardShell>
)
```

And the middleware's `GATED_PREFIXES` becomes empty (or removes the
gate entirely). The middleware is now PERMISSIVE — every signed-in
request reaches the page, and the page itself renders either the
wizard or the trading UI based on local state.

**Why this works:**

- The page reads the JWT from localStorage (adminFetch pattern)
- The page makes a fetch() call with the Bearer header — browsers
  ALLOW custom headers on fetch
- The fetch returns the lifecycle state. If onboarding_complete=false,
  render the wizard inline. If true, render the trading UI.
- No redirects, no client-side navigation. The page either shows the
  wizard or the trading UI based on the live lifecycle state.

The user never gets bounced. They see the right UI immediately.

**The diagnostic — is this the bug? Check three things:**

```bash
# 1. Does /dashboard/trading return 200 with a valid cookie?
curl -sI -H "Cookie: sb-<project-ref>-auth-token=<envelope>" \
  https://www.yourdomain.com/dashboard/trading | head -1
# → HTTP/2 200 = cookie path works

# 2. Does it return 200 with Authorization: Bearer?
curl -sI -H "Authorization: Bearer <jwt>" \
  https://www.yourdomain.com/dashboard/trading | head -1
# → HTTP/2 200 = bearer path works

# 3. Does the user's PWA see the right page when they navigate?
#    (Browser DevTools → Network tab → click a navigation button →
#    look at the request that fires when router.replace runs)
#
# If 1 and 2 work but 3 still bounces, this is the bug.
```

**The pattern — for any "user state X gates access to route Y"
question, prefer the page-level gate over the middleware gate:**

| | Middleware gate | Page-level gate |
|---|---|---|
| Where it runs | Server, on every navigation | Client, on mount of the gated page |
| Auth material it can read | Cookies only (browser navigation) | Cookies + Bearer (fetch) |
| Identifies PWA user on client-side router.replace? | NO (no cookie on app domain unless session freshly created post-mirror) | YES (reads localStorage directly) |
| Redirects on failure | Server-side 302 — visible flash, can be intercepted by SW | Inline render — no redirect |
| Recovery on stale state | User must log out and back in (cookie mirror needs setItem) | Always reads current state — recovers automatically |
| Best for | Server-rendered public marketing pages where you don't have a SPA | Any SPA route that depends on user state |

**The general rule:** **Use a middleware gate only when:**
- The route is a marketing page or static content that doesn't depend
  on user-specific state, OR
- The user can only reach the route via a hard navigation (browser
  address bar, link from another origin), not via SPA navigation.

**Use a page-level gate when:**
- The route is reached via SPA navigation (Link, router.push, router.replace)
- The page depends on user-specific state (onboarding complete, role,
  membership, KYC verified, etc.)
- The user is logged in via supabase-js (or similar) which uses localStorage

**When this hits again:** any new "user must complete X before accessing Y"
gate. Always default to page-level unless you have a specific reason
to use middleware. The cookie-mirror pattern from Recipe #29 is a
workaround, not a fix — page-level is the fix.

**The migration recipe — if you already have a middleware gate:**

1. Keep the `isOnboardingComplete()` helper in the middleware (still
   used for SSR-redirect scenarios and bot traffic)
2. Remove the `GATED_PREFIXES` and the redirect logic
3. Move the gate to a page-level component (`OnboardingGate.tsx`)
4. Mount the component on each gated page
5. Test: PWA user should be able to navigate freely without bounces
6. If you need to keep middleware-level validation for some routes
   (e.g. SEO pages), use a separate `NEEDS_AUTH` predicate that's
   deliberately scoped to those routes only

**Pair with:** Recipe #29 (PWA SW serving stale 302) — both are
the same root cause (client-side navigation can't carry auth material
the way middleware expects). The page-level fix sidesteps both.

---

## Recipe #34 — useUser() loading=false race + lockManager contention = silent 401 on PWA (added Aug 26 2026)

**Symptom:** a brand-new feature works in dev (Chrome) but is "broken"
in the PWA: the user sees the gate UI, the loading spinner hangs for
10+ seconds, then the feature appears empty. The user reports the
PWA "doesn't work" but it works fine in Chrome.

**Root cause — two compounding issues:**

1. **`navigator.locks` LockManager contention** (Recipe #15): `supabase.auth.getSession()` acquires an exclusive `navigator.locks` lock on `sb-<project-ref>-auth-token`. The lock is held for 10s before timing out. During the lock, all other `getSession()` calls return `{ session: null }`.

2. **UserContext `loading=false` race** (Recipe #12): the provider flips `loading=false` BEFORE the DB-derived flags (`isTrader`, `isAdmin`) resolve. Pages that depend on these flags render the gate UI while the flag is still being fetched.

When the PWA loads, the provider's `useEffect` fires `refreshProfile()` →
`supabase.auth.getSession()` → lock waits 10s → returns null →
provider's `setLoading(false)` fires (because session is "valid" as null)
→ page renders with all flags as false → gate shows up.

If the user's session happens to be locked by another tab or by the SW
re-fetching the auth token, the provider's gate logic uses
`loading=false` AND flags=false to conclude "user is unauthenticated, show
gate." The user is stuck on the gate for 10s before the lock releases
and `isTrader` flips true.

**The fix — combine load + flag in one render path:**

```tsx
// Before (broken):
if (loading) return <Loading/>
if (!isTrader) return <Gate/>

// After (fixed):
if (loading || isTrader === undefined) return <Loading/>
if (!isTrader) return <Gate/>
```

The page treats "loading OR flag not yet read" as a single loading
state. The gate only renders when the user is DEFINITELY not a trader
(`isTrader === false`). If the flag is `undefined`, the page assumes
the flag is still being read and shows the loading state.

Combined with the fix in Recipe #12 (UserContext flips `loading=false`
AFTER all flags resolve), the two fixes compound to give a clean
load → display transition without ever showing the gate while flags
are in flight.

**The diagnostic — is this the bug?**

```bash
# Open Chrome DevTools console. Filter for "onboarding" or "auth".
# Look for any of:
#   "Acquiring an exclusive Navigator LockManager lock... timed out"
#   "useUser.refreshProfile timeout"
#   "fetchLifecycle threw"
# Any of these = the lockManager is involved.
```

If yes, apply the fix above. The combination of `loading || isTrader === undefined`
as the loading check + the 6s `AbortController` timeout in any
fetchLifecycle wrapper will surface most of these issues.

**The general rule:** in any SPA that uses supabase-js + React context
for auth state, **never make a UI decision on a flag that hasn't been
read yet**. Treat `undefined` flag values as "still loading" rather
than "false." Add `loading || flag === undefined` as the loading check.

**When this hits again:** any new feature that gates on a flag from
`useUser()` (or any similar context). The default loading check should
be `loading || (every required flag has been read at least once)`. This
pattern is robust to lockManager contention, slow DB queries, and any
other reason a flag might not be set yet.

**Pair with:** Recipe #12 (UserContext loading=false race), Recipe
#15 (navigator.locks LockManager contention), Recipe #33 (middleware
vs page-level gate).

---
