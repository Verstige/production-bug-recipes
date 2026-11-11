# August 22 2026 Session Additions — pending merge into SKILL.md

The autonomous curator refused direct SKILL.md patches in this session (it requires a
`skill_view` re-load after every read, but dedup-caches the result, so the patcher
gets stuck in a "load again but it's unchanged" loop). This file is a drop-in
delta: copy these sections into the matching SKILL.md anchors when a human
curator is available. The anchors below point at the existing line where each
section should be inserted.

---

## INSERT INTO SKILL.md AT THE END OF THE EXISTING "What I deliberately did NOT do" SECTION

### Recipe #19 — Trader close-with-price action: CHECK constraint + defensive fallback to `commentary` (Aug 22 2026)

**Symptom:** when a trader clicks "Close" on their signal card with a manual close price, the route returns `500 column telegram_trader_signals.close_price does not exist` (the migration adding `close_price` + `closed_at` hasn't run because pg access is broken) — OR returns `500 new row for relation "telegram_trader_signals" violates check constraint "telegram_trader_signals_status_check"` if the route writes `status='closed'` (the constraint only allows `'live', 'tp1_hit', ..., 'completed', 'expired', 'cancelled'`).

**Root cause — three layers all need to be right:**

1. **Schema columns:** the dedicated `close_price` + `closed_at` columns may not exist yet (the migration that adds them is queued but unrun when pg access is broken).
2. **CHECK constraint:** the existing constraint only allows the canonical close enum `'completed'`, NOT `'closed'`. Any code writing `status='closed'` gets rejected.
3. **Defensive probe pitfall:** `supabase.from(table).select('close_price, closed_at').limit(1)` does NOT surface missing columns as an error — PostgREST silently returns rows with `close_price: null` even when the column doesn't exist. So a "probe then conditionally include column in UPDATE" pattern silently always-thinks-columns-exist and always-includes them in the UPDATE, which then 500s on the missing-column constraint.

**The fix — three layers:**

**Layer 1 — schema probe that actually works:** wrap the probe in a try block that catches BOTH the `.error` AND any throw, and trust nothing:

```ts
let supportsClosePriceCols = false
try {
  // Probe is best-effort. PostgREST may NOT error on missing
  // columns for SELECT in some cases, so we can't trust `error` being
  // set. The defensive UPDATE below uses try/catch to handle the
  // case where the probe was wrong.
  const probe = await supabase
    .from('telegram_trader_signals')
    .select('id, close_price, closed_at')
    .eq('id', signalId)
    .limit(1)
  supportsClosePriceCols = !probe.error
} catch {
  supportsClosePriceCols = false
}

// Always set status='completed' (the only allowed close enum).
// Try to also set close_price + closed_at IF the columns exist.
const updates: Record<string, any> = {
  status: 'completed',  // ← CHECK constraint safe
  commentary: buildCloseMarker(signal.commentary, closePrice, note),
}
if (supportsClosePriceCols) {
  updates.close_price = closePrice
  updates.closed_at    = new Date().toISOString()
}

const { data, error } = await supabase
    .from('telegram_trader_signals')
    .update(updates)
    .eq('id', signalId)
    .select(...)
    .single()
if (error) return NextResponse.json({ error: error.message }, { status: 500 })
```

**Layer 2 — always set status to `'completed'`, never `'closed'`:** the existing CHECK constraint allows only `(live, tp1_hit, tp2_hit, tp3_hit, tp4_hit, sl_hit, completed, expired, cancelled)` — NOT `'closed'`. Always write `'completed'`. Surface `'closed'` semantics to clients in the response shape (the route can echo `outcome: 'closed'` separately from `signal.status: 'completed'`).

```ts
const CLOSE_STATUSES = new Set(['completed', 'cancelled', 'expired'])
if (CLOSE_STATUSES.has(signal.status)) {
  return NextResponse.json({ ok: true, signal, noChange: true })
}
```

**Layer 3 — defensive commentary marker:** even when `close_price`/`closed_at` columns don't exist, the close info MUST survive somewhere — the user wants to see what price they closed at. Stamp it into `commentary`:

```ts
function buildCloseMarker(existing: string | null, closePrice: number, note: string | undefined): string {
  const marker = `[CLOSED @ ${closePrice}]`
  const trimmed = (existing ?? '').trim()
  // Idempotent: don't double-stamp if already there
  if (trimmed.includes('[CLOSED')) return note?.trim() ? `${trimmed}\n${note.trim()}` : trimmed
  const withMarker = trimmed ? `${trimmed}\n${marker}` : marker
  return note?.trim() ? `${withMarker}\n${note.trim()}` : withMarker
}
```

The route then always sets `updates.commentary = buildCloseMarker(...)` regardless of whether the dedicated columns exist. Users see the close info in the UI even without the migration applied.

**The client-side hide-condition:** the SignalActions component hides the Close button when `signal.status` is `completed|cancelled|expired` (NOT `closed`):

```tsx
{(signal.status !== 'completed' && signal.status !== 'cancelled' && signal.status !== 'expired') && (
  <button>Close</button>
)}
```

**Idempotency for the close action:** if a trader clicks Close twice (or network retries), the route returns `{ ok: true, noChange: true }` for already-closed signals. No duplicate push fires. The `[CLOSED @ price]` marker is only added once (smart-merge in `buildCloseMarker`).

**Push fan-out uses `'closed'` as the outcome label (separate from DB status):**

```ts
// In broadcastOutcomeUpdate — the title builder reads outcome, not signal.status
if (opts.outcome === 'closed') {
  title = `⏹ ${opts.pair} closed`
  body = `${opts.traderName} · ${opts.pair}${entryLabel}${closeLabel}`
}
```

The route passes `outcome: 'closed'` to the broadcaster — the DB column is `'completed'`, the user-facing label is `'closed'`, the title emoji is `⏹`. Three separate concerns, three separate names.

**When this hits again:** any action that wants to mark a row as "done" / "closed" / "expired" / "cancelled" in `telegram_trader_signals` or any other table with a CHECK constraint on status. Always:
1. Check the constraint: `SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid = '<table>'::regclass AND contype = 'c'`
2. Pick from the allowed enum, never invent a new value
3. If you want "closed" semantics, map to whatever the constraint allows (`'completed'`)
4. Stamp any extra metadata into a JSONB or TEXT field for the migration to formalize later

### Recipe #20 — `.finally()` doesn't run when the synchronous part of the chain throws (Aug 22 2026)

**Symptom:** a state-loading flag (e.g. `loadingProfile`, `isSubmitting`, `saving`) gets stuck at `true` forever, leaving a "Save" button disabled, a loading spinner spinning, or a form unable to be edited. The user reports "the button doesn't work." Console logs (if added later) reveal nothing fired.

**Root cause:** a chained promise relies on `.finally()` to reset state:

```ts
// BROKEN — finally doesn't run if adminFetch throws synchronously
setLoading(true)
adminFetch(url)
    .then(r => r.json())
    .then(data => { setForm(...) })
    .catch(() => {})
    .finally(() => setLoading(false))  // ← skipped if anything above throws sync
```

If `adminFetch` throws synchronously (e.g. `localStorage.getItem(key)` returns a malformed JSON string and `JSON.parse` throws before the promise is even returned), the throw bypasses the entire `.then().catch().finally()` chain. `setLoading(false)` never runs.

**The fix — synchronous-throw-safe reset:**

```ts
let cancelled = false
const reset = () => { if (!cancelled) setLoading(false) }
setLoading(true)
adminFetch(url)
    .then(r => {
        if (!r.ok) throw new Error(`HTTP ${r.status}`)
        return r.json()
    })
    .then(data => {
        if (cancelled) return
        setForm(...)
    })
    .catch(err => {
        console.warn('[Component] load failed:', err?.message)
        // don't reset here — let finally do it
    })
    .finally(reset)
return () => { cancelled = true }
```

Key elements:
1. The reset function is named and pulled out — `const reset = () => …` so even if a future refactor adds a sync throw, `.finally(reset)` still calls it.
2. The `cancelled` flag guards against setting state on an unmounted component (React would warn about the memory leak).
3. The `catch` block doesn't reset state itself — `.finally(reset)` is the single source of truth.

**The same pattern is more obviously needed when the synchronous throw is between `setLoading(true)` and the chain starts:**

```ts
// FRAGILE — setLoading(true) runs but reset might never fire
const load = async () => {
    setLoading(true)
    // ⚠️ any throw HERE skips the chain entirely
    const raw = window.localStorage.getItem('token')
    const token = JSON.parse(raw)  // ← can throw synchronously
    // ...
}
```

Move all the synchronous prep OUT of the function or wrap the whole body in try/catch/finally:

```ts
const load = async () => {
    setLoading(true)
    try {
        // all sync and async work
        const raw = window.localStorage.getItem('token')
        const token = JSON.parse(raw)
        const data = await fetch(url, { headers: { Authorization: `Bearer ${token}` } }).then(r => r.json())
        if (cancelled) return
        setForm(data)
    } catch (err) {
        console.warn(err)
    } finally {
        if (!cancelled) setLoading(false)
    }
}
```

**Rule:** any time you set a loading/state flag and rely on `.finally()` to reset it, name the reset function and call it via `.finally(reset)` instead of inline. Also wrap the whole chain in a `try { ... } finally { reset() }` for belt-and-braces.

**The companion rule — `loadingProfile` from a parent needs to be defensive too:** if the parent's `setLoadingProfile(true)` fires but the child's `useEffect` cleanup unsets it, you can still get stuck states. The pattern that survives both: every `useEffect` that toggles a loading flag must also have a cleanup that cancels the in-flight request (`AbortController.abort()`) AND sets the flag to false in the cleanup.

### Recipe #21 — The trader-self-service action button chain (Aug 22 2026)

**Pattern:** traders (or admins acting as traders) mark their own signals as `tp1_hit | tp2_hit | tp3_hit | tp4_hit | sl_hit | completed | update | reopen` via in-card action buttons. Each action:
1. Validates ownership server-side
2. Updates the row atomically
3. Bumps the trader's win/loss stats via SQL RPC
4. Fires a PWA push notification with a clean format
5. Is idempotent (no duplicate push if action is repeated)

**The action handler — one route, multiple actions:**

```ts
// /api/trader/signals/[id]/update/route.ts
type ActionBody =
    | { action: 'mark'; outcome: Outcome; note?: string; emitPush?: boolean }
    | { action: 'update'; note: string; emitPush?: boolean }
    | { action: 'close'; closePrice: number; note?: string; emitPush?: boolean }
    | { action: 'reopen' }
```

Each action has its own branch:
- `mark tp1..tp4 | sl` → set the *_hit flag, increment wins/losses, fire push
- `update` → set commentary column to the note, fire push with note
- `close` → set status='completed', stamp [CLOSED @ price] into commentary (see Recipe #19), fire push
- `reopen` → clear all *_hit flags, status → live, no push

**The owner check — server-side, not just client-side:**

```ts
async function isTraderOwnedOrAdmin(req, supabase, signal): Promise<...> {
    const auth = req.headers.get('authorization')?.match(/^Bearer (.+)$/i)
    if (!auth) return { ok: false, response: NextResponse.json({ error: 'auth required' }, { status: 401 }) }
    const { data: userRes } = await supabase.auth.getUser(auth[1])
    if (!userRes?.user) return { ok: false, response: NextResponse.json({ error: 'invalid session' }, { status: 401 }) }
    const isAdmin = await isUserAdmin(supabase, userRes.user.id)
    if (!isAdmin && signal.trader_id !== userRes.user.id) {
        return { ok: false, response: NextResponse.json({ error: 'not your signal' }, { status: 403 }) }
    }
    return { ok: true, isAdmin }
}
```

**Idempotency check before each update:**

```ts
if (outcome === 'tp1') {
    if (signal.tp1_hit) return NextResponse.json({ ok: true, noChange: true })
    // ... update logic
}
```

**The PWA push notification format — clean two-line body:**

```
🟢 TP1 HIT · GBPJPY
Test Trader Julyan · GBPJPY @ 1.2650
[optional custom comment on a second line]
```

NOT: "Test Trader Julyan's setup hit TP1" — too verbose, repeats trader info, the "Trader's setup hit" boilerplate is unhelpful.

**The route pair — one for new signals, one for actions:**

- `POST /api/trader/signals` — create new signal (compose UI calls this)
- `POST /api/trader/signals/[id]/update` — mutate existing signal (SignalActions calls this)

The two routes share a single `broadcastOutcomeUpdate` / `broadcastTraderSignalPwaPush` helper that fans out to `push_subscriptions`. New actions get added to `ActionBody` and dispatched in the route handler. No need for new routes for new actions.

**Why both a close action AND a TP/SL hit button exist:**

- TP/SL hits are HOW the trade resolves — driven by the broker fills (real-world data) OR the trader marking them manually
- Close action is the "I want to exit this position right now at price X" — distinct from "TP1 hit and I'm closing at the TP1 price"

The broadcast text differs:
- TP/SL: `🟢 TP1 HIT · GBPJPY` or `🔴 SL HIT · GBPJPY` — outcome-emoji + pair + side
- Close: `⏹ GBPJPY closed` — clock-emoji + pair + the close price in the body

The DB status is `'completed'` for both, but the user sees the outcome emoji.

### Recipe #22 — Broadening scope: lockManager bug affects five code paths, not just admin (Aug 22 2026)

This is an update to Recipe #15 — the original recipe listed four affected paths. A second look after fixes were deployed surfaced a fifth, plus the pattern is even broader:

**Fifth affected path (the public trader profile page):** `src/app/trader/[slug]/page.tsx` rendered a "Trader not found" message because the anon PostgREST client (`createClient(SUPABASE_URL, ANON)`) silently acquired the lock the same way `auth.getSession()` does. When the lock timed out, `maybeSingle()` returned `null`, the page set the "Trader not found" error, and the user saw a confusing message that had nothing to do with the actual problem.

The fix: route the page through our own `/api/trader/[slug]` endpoint instead of direct PostgREST. The route runs with service_role, no auth material needed client-side, no lockManager involved.

**The broader pattern:** **any** browser-side fetch that depends on Supabase auth state is at risk of the lockManager bug. The complete list of affected code paths in a typical the platform session:

| Code path | Uses `supabase.auth.getSession()` | Fix |
|-----------|----------------------------------|------|
| `adminFetch` wrapper | YES (was) | Read access_token from localStorage directly |
| `SignalActions` (TP/SL/Update/Close/Reopen) | YES (was) | Read access_token from localStorage |
| `SendSignalForm` (composer modal) | YES (was) | Read access_token from localStorage |
| `getCurrentUserSlug` in TraderSignalsView | YES (was) | Read access_token from localStorage |
| `/trader/[slug]/page.tsx` anon client | YES (transitive) | Refactor to call `/api/trader/[slug]` instead |

The universal fix: **stop using `supabase.auth.getSession()` from a PWA for simple Bearer-header fetching**. Read the token from localStorage and skip the lockManager entirely.

**Diagnostic — when you see the lockManager error in DevTools, search the project for every place that calls `supabase.auth.getSession()` (or anything in supabase-js that fetches the session) and audit each one.**

```bash
rg -n "supabase\\.auth\\.getSession\\(\\)" src/
rg -n "getSupabaseBrowserClient" src/
```

For each match, decide:
- If the code just needs the bearer token for an API call → replace with the localStorage-read pattern (5-line helper)
- If the code needs the FULL session object (user, refresh_token, etc.) → use `supabase.auth.onAuthStateChange` instead (event-driven, no lock)
- If the code can't be changed → refactor the consumer to use an API route that uses service_role server-side (the route doesn't need the lock at all)

**When this hits again:** a new feature uses `supabase.auth.getSession()` (or any function that fetches the session) inside a PWA. Default to the localStorage-read pattern. Audit every existing call site at the start of any PWA-related work — not just the one you're touching.
