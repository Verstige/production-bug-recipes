# 2026-08-25 Onboarding wizard polish + migration audit session drop-in

This session drop-in captures the four reusable patterns that came out of
round-10 / round-11 of the onboarding wizard fixes plus the full migration
audit. Each matches an existing recipe class but is sharper on the failure
mechanism and adds the working pattern.

## Recipe #38 — `supabase.auth.updateUser` silently aborts the next line of code (after a 200 response) (added Aug 26 2026)

**Symptom:** a step-save handler in the wizard calls `supabase.auth.updateUser(...)`, the PUT to `/auth/v1/user` returns 200, the new JWT is written to localStorage, but **the very next `await adminFetch(...)` for `/api/onboarding/complete-step` never fires**. The function exits. No exception is thrown. `markStep` is never called. The React `completed` Set never updates. Network trace shows only the PUT — no POST to complete-step. `setError` is not fired. The user sees a button click that visually resets but doesn't persist.

```ts
// This is what the wizard had — BUG
const { error: e } = await supabase.auth.updateUser({
    data: { theme_accent: a, theme_mode: m },
})
if (e) throw new Error(e.message)            // never reached
await adminFetch('/api/onboarding/complete-step', { step_key: 'accent_theme' }) // never reached
markStep('accent_theme')                     // never reached
```

**Root cause:** the Supabase JS `updateUser` has the same `navigator.locks` LockManager contention that `getSession` has (covered by Recipe #15), but the failure mode is **different** and worse:

- `getSession` times out and resolves with `{ data: { session: null } }` after 10s.
- `updateUser` resolves successfully (200 response) with the new JWT in storage, BUT the in-tab JS microtask queue is partway through when another copy of the same singleton (created via `getSupabaseBrowserClient()` from a different bundled module instance — UserContext.tsx imports the same module that the wizard imports, but Turbopack bakes two separate copies) holds the same `lock:sb-…-auth-token` write lock. The await microtask is silently dropped. No exception, no rejection. Promise chains resolve as if everything's fine.

Because both singleton instances share the same localStorage key (`sb-<project-ref>-auth-token`), the second instance's session-refresh races on the write lock whenever the wizard's `updateUser` triggers a session refresh. **This only manifests in code paths that call `supabase.auth.*` from inside `useEffect`/event handlers in a component that ALSO imports `getSupabaseBrowserClient()` indirectly through `UserContext` or `getSupabaseBrowserClient` re-imports via different bundled modules.**

**Diagnostic recipe** (you'll spend a long time guessing otherwise):

1. Open the failing component in Chrome DevTools → Network.
2. Trigger the click. Watch for which POST/PUTs are sent and which are missing.
3. If you see the auth.write hit (PUT `/auth/v1/user` returns 200 or 204), but the next `/api/...` call **does not appear at all** in Network: this recipe. Not throw, not 401, not 403. Silent abort.
4. The Supabase JS warning in console — `Multiple GoTrueClient instances detected in the same browser context` — is the smoking gun. It only appears when two copies of the singleton exist, which is exactly the race condition.

**The fix — never call `supabase.auth.*` (write or refresh) from a wizard save handler.** Move ALL auth-side metadata writes to a server-side endpoint that the wizard can call with `adminFetch` (plain fetch + Bearer header from localStorage, see `src/lib/admin-fetch.ts`). The server endpoint uses `svc.auth.admin.updateUserById` which doesn't share the user's JS client lock:

```ts
// server-side route — uses SERVICE_ROLE key, no JS-client lock contention
export async function POST(req: NextRequest) {
    const auth = await getAuthContext(req)
    if (!auth?.userId) return NextResponse.json({ ok: false, error: 'unauthenticated' }, { status: 401 })
    const svc = createServiceClient()
    const { data: u } = await svc.auth.admin.getUserById(auth.userId)
    const merged = { ...(u?.user_metadata ?? {}), ...metaUpdates }
    await svc.auth.admin.updateUserById(auth.userId, { user_metadata: merged })
    // ...
}

// wizard save handler — pure adminFetch, no supabase.auth.* calls
const r = await adminFetch('/api/onboarding/profile', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ theme_accent, theme_mode }),
})
if (!r.ok) throw new Error('Save failed: ' + r.status)
await adminFetch('/api/onboarding/complete-step', { step_key: 'accent_theme' })
markStep('accent_theme')
```

**Same recipe applies to `supabase.auth.refreshSession()`** — handleFinish in the wizard hit the same bug; navigation never happened. Replace with `window.location.href = '/dashboard'` after a soft `adminFetch('/api/auth/me')` so the profile-refresh broadcast warms, then full navigation forces middleware to re-evaluate `onboarding_complete`.

**When this hits again:** any time you're authoring a PWA-side save handler that touches both user_metadata (auth side) AND a public-side table row (e.g. `user_accounts.full_name`), the temptation is to call `supabase.auth.updateUser` for the metadata half and a separate route for the row half. **Don't. Use one adminFetch-per-endpoint pattern.** Each endpoint does its own auth-side write via service_role.

---

## Recipe #39 — `adminFetch` is the right primitive; avoid `supabase.auth.*` from component handlers (added Aug 26 2026)

Complementing #38. `adminFetch` (`src/lib/admin-fetch.ts`) is a thin wrapper around `fetch` that:

1. Reads the access token from `localStorage.sb-...-auth-token` directly (bypassing `supabase.auth.getSession()`'s lock contention).
2. Adds `Authorization: Bearer <token>`.
3. Otherwise is just `fetch(url, init)`. No JS-client GoTrueClient involvement.

For save handlers in authenticated contexts, **prefer `adminFetch` over any `supabase.from(...).update/insert`** for these reasons:

- It works even when `supabase.auth.*` is failing due to LockManager.
- It doesn't create new GoTrueClient instances (which would risk the duplicate-instance warning).
- It calls the server-side route, which can use SERVICE_ROLE for cross-table writes (auth + user_accounts in one transaction).

**When this hits again:** any new authenticated save handler (wizard, settings page, profile editor). Use `adminFetch` to a route that does the work. If you need the server-side route to combine auth + user_accounts writes, build one even if it overlaps with `supabase.from(...)` — the reliability win is worth it.

---

## Recipe #40 — Stale `/api/...` route references in client code → silent 404 (added Aug 26 2026)

**Symptom:** the React wizard calls a route like `adminFetch('/api/profile/me', { method: 'PATCH', body: ... })`. The server returns 404 because the route does not exist. The wizard's `if (!r.ok) throw` catches the 404, `setError` shows the toast, `markStep` is never called, the step stays un-marked-complete. The user can re-click 100 times and the step never flips.

**Diagnostic:**
```
rg -n "/api/profile" src/   # see all client references
# then for each route, curl it
curl -X POST https://<host>/api/profile/me   # 404 means stale reference
```

**The fix cycle:**
1. Grep client code for `adminFetch('/api/...'` and `/api/...'` to find every assumed route.
2. Confirm each route exists by `find src/app/api -name 'route.ts' -path '*<name>*'` or `ls src/app/api/<name>/`.
3. If missing, create the missing route OR patch the client to call an existing route.
4. For one-shot save handlers (like wizard step-saves), the pattern is **one endpoint per surface step**: `/api/onboarding/profile` (round 11 of this session) handles Step 1 (accent_theme) and Step 2 (profile_basics), owned by one route file with one validation surface.

**When this hits again:** any new wizard step, settings save, or admin tool. Before shipping, grep the consumer for `adminFetch` URLs and `find` the matching route files.

---

## Recipe #41 — Migration ordering trap: 4-step trim overridden by 7-step expansion (added Aug 26 2026)

**Symptom:** the wizard at `/dashboard/(main)/onboarding/page.tsx` has `REQUIRED_STEPS = ['accent_theme', 'profile_basics', 'risk_disclaimer', 'walkthrough']` (Round 9 — 4 steps). The `app_onboarding_step_changed()` trigger flips `user_accounts.onboarding_complete = true` only when all 4 required step_key rows are in `user_progress`. The `app_get_user_lifecycle(p_user_id)` RPC returns `required_count` and a 4-entry `steps[]`.

But because the migrations were applied in date order, an **earlier** `202608240011_trim_to_4_steps.sql` got overridden by a **later** `202608250001_lifecycle_steps.sql` family that defined the trigger as 7-step. The wizard tries to flip `required_count: 4`, the trigger requires 7, no wizard row count reaches 7, the wizard's `allDone` looks at JS state `completed.size >= REQUIRED_STEPS.length` (=4), the user sees the "Enter the trading floor" CTA but the **gate at `/dashboard` keeps bouncing back to `/onboarding`** because `user_accounts.onboarding_complete` is still false (server-trigger never fired).

**Diagnostics:**
1. From the Supabase SQL Editor: `SELECT * FROM pg_proc WHERE proname='app_onboarding_step_changed';` — read the function body, look at `v_required_count := N`.
2. From the user's session: `SELECT onboarding_complete FROM user_accounts WHERE id = '<uuid>';` — true means done, false means stuck.
3. From the lifecycle endpoint: `curl /api/onboarding/lifecycle` with the user's bearer token. Read `required_count`.

**The fix:** a later-dated migration that re-creates the trigger + RPC with the correct (4-step) `v_required_count`. Naming convention: `YYYYMMDDNNN_<descriptive>.sql`; the date prefix is what matters for migration ordering. A migration named `202608260003_trim_to_4_steps_after_7step_migration.sql` runs after `202608250001_lifecycle_steps.sql` and after `202608260002_onboarding_trigger_fix_7step.sql`, so it can re-trim whichever is the most recent definition.

Two functions always need to stay in sync: `app_onboarding_step_changed` (trigger that flips `onboarding_complete`) and `app_get_user_lifecycle` (RPC the wizard reads). If you re-trim one, re-trim the other in the same migration, otherwise the user completes 4 wizard steps, the trigger fires with 7-step `IN (...)` requiring 7 rows, the trigger does nothing, the wizard's `completed.size === 4 === REQUIRED_STEPS.length` so `allDone = true`, but `user_accounts.onboarding_complete = false`, and the user is stuck.

**When this hits again:** any round of wizard expansion/contraction. Always re-trim **both** the trigger AND the RPC in one migration, with the same `v_required_count` value, and the same step_key array in the same order.

---

## Recipe #42 — Probe `pg_proc` for "absent" functions the right way (added Aug 26 2026)

**Symptom:** your migration audit probes `/rest/v1/rpc/<fn>` for every function defined in `supabase/migrations/*.sql`, treats `PGRST202` as "function does not exist", and reports 18 missing functions. Half of those are false positives.

**The trap:** PostgREST looks up the function in `pg_proc` based on the **argument list provided**. When you POST `{}` (empty JSON body) to a function that takes required arguments, PostgREST searches pg_proc for a zero-argument version of the function name. It doesn't find one → returns `PGRST202 Could not find the function ... in the schema cache`. The function exists; the probe is wrong.

**The fix:** call each RPC with **real args** that match its expected signature. Have a typed map of `KNOWN_ARGS` per function name. Probe each with the right args. PGRST202 only when called with right args = "truly missing". Anything else (including 4xx/5xx runtime errors) = "function exists". 

For functions you don't know the signature for, probe with `?select=argname,argtype` via the `pg_catalog` (or query the function existence via a wildcard — though PostgREST doesn't expose that easily).

**Pre-flight probe structure** (Node.js / fetch):
```js
const KNOWN_ARGS = {
    award_log: { p_user_id: '00000000-…', p_amount: 1, p_reason: 'audit', p_ref_id: 'audit', p_metadata: {} },
    app_get_user_lifecycle: { p_user_id: '00000000-…' },
    // …
}

for (const fn of fns) {
    const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, {
        method: 'POST',
        headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`, 'Content-Type': 'application/json' },
        body: JSON.stringify(KNOWN_ARGS[fn] ?? {}),
    })
    const body = await r.json()
    if (body?.code === 'PGRST202') absent.push(fn)
    else present.push(fn)  // even 4xx/5xx means the function exists
}
```

Bonus: **trigger functions** (anything with `RETURNS TRIGGER`) are not exposed via `/rest/v1/rpc/<name>` at all. They report PGRST202 even when present. Detect triggers by scanning the migration for `CREATE [OR REPLACE] FUNCTION … RETURNS TRIGGER` pattern and exclude them from your "absent" list.

**When this hits again:** any future migration audit, or any DB introspection from a sandboxed agent (no psql access). The audit script is at a database function audit script — extend its `KNOWN_ARGS` map when new functions land.

---

## Recipe #43 — Catch-up migration pattern: one file, idempotent CREATE OR REPLACE for every dropped function (added Aug 26 2026)

**Symptom:** the audit (Recipe #42) finds 7+ functions missing from production. Their migration source files exist but the original CREATE didn't propagate (transaction aborted, RLS conflict, partial migration). You need to add the missing functions back WITHOUT rolling back other state.

**The fix — write a single catch-up migration that:**
- `CREATE OR REPLACE FUNCTION public.<fn>(...)` for each missing function, verbatim from the source migration bodies.
- Includes `GRANT EXECUTE … TO service_role[, anon, authenticated]` for each (the original migrations grant these too).
- Drops any old function with the same name+signature first, to handle signature drift: `DROP FUNCTION IF EXISTS public.<fn>(old-sig);`.
- Ends with `NOTIFY pgrst, 'reload schema';` so PostgREST picks up the new catalog.
- Is dated to run AFTER everything else. Naming: `YYYYMMDDNNN_<descriptive>.sql`. Today's example: `202608260006_catch_up_missing_functions.sql`.

Source the function bodies from the original migration files. Don't rewrite — copy verbatim. Differences in comments / formatting are noise. The function body must match what the calling client code expects.

**Acceptable to skip:** trigger functions (cannot be CREATE OR REPLACE for security/permission reasons). If they're missing too, they have to be added separately via the original migration file's body, applied in order.

**When this hits again:** any time a function-inventory audit surfaces truly-absent RPC functions with available source. Always precede with a confirm-they're-actually-missing probe (Recipe #42's right way).

---

## Recipe #44 — Force `window.location.href = '/path'` instead of `router.push()` for cross-context nav (added Aug 26 2026)

**Symptom:** the wizard's final CTA calls `router.push('/dashboard')`. The router transitions client-side; in production, the middleware at `/dashboard` re-evaluates the user's `onboarding_complete` flag from the **stale cached cookie/auth state** when the middleware fires, sees false, redirects back to `/onboarding`. The user sees a brief flash of `/dashboard`, then back to `/onboarding`. The trigger just flipped `onboarding_complete = true` server-side, but the cookie-based middleware check doesn't see the new state because the cookie JWT hasn't been refreshed.

**The fix:** use `window.location.href = '/dashboard'` instead of `router.push('/dashboard')`. This forces a full page reload, the middleware re-fetches the user's session from the server (which sees the freshly-flipped `onboarding_complete = true`), and the gate passes.

```ts
// Instead of:
await supabase.auth.refreshSession()   // ← silently aborts (Recipe #38)
router.push('/dashboard')               // ← client-side only

// Use:
await adminFetch('/api/auth/me', { method: 'GET' })  // soft auth refresh
setSubmitting(false)
window.location.href = '/dashboard'     // full reload, middleware re-evaluates
```

**When this hits again:** any time a save handler triggers a server-side state change that a middleware-level gate depends on. The wait-for-then-client-push pattern is fine for in-app nav (e.g. clicking a tile in the dashboard goes to `/dashboard/settings`), but never for nav out of a gated flow.

---

## Cross-references

- **#15** covers `navigator.locks` LockManager contention with `auth.getSession()`. **#38** here is the same root cause but on the auth WRITE path (`updateUser`, `refreshSession`).
- **#20** covers applying migrations from sandboxed environments. **#41** covers migration ordering traps (4-step vs 7-step trim conflicts).
- **#21** covers the durable-flag vs short-lived-token pattern for the lifecycle endpoint. **#41** extends it: when the wizard's REQUIRED_STEPS list changes, both the trigger AND the RPC have to be re-trimmed together.
- **#34** covers useUser loading=false race + LockManager compound. **#38** is the WRITE-side variant of the same compound.
- **#22** covers deep-link modal-trigger pattern. **#44** is the inverse: how to NAVIGATE OUT of a gated flow cleanly after a server-side state flip.
