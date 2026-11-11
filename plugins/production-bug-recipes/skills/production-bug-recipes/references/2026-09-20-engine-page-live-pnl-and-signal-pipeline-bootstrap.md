# 2026-09-20 — Engine page live P&L, signal pipeline bootstrap, cipher 5-digit, dual-auth + adminFetch

Several independent phases shipped on the same day. Each bug fell in a different layer of the same pipeline (Telegram listener → Supabase `public.signal_log` → Next.js components). The diagnostic ladder below is the order to walk in, top to bottom, when "Engine page shows mock data" or "engine write-back doesn't update Supabase" shows up. Recipes #62–#71.

## Recipe #62 — Engine Performance page shows hardcoded mock data despite `public.signal_log` having real rows

**Symptom:** `/dashboard/trading` ENGINES section renders `+51,350 NET PIPS · 80.4% WIN RATE · 300 CLOSED` for ENGINE_H even though `SELECT count(*) FROM signal_log WHERE engine='ENGINE_H'` is 7. The numbers exactly match `src/components/trading/enginesData.ts:97-148` which contains static `signals: 300, wins: 180, totalPips: 51350` — a giveaway that those literals are leaking.

**Root cause:** `src/components/trading/EnginesView.tsx` merges static ENGINES metadata with live stats from `useRecentEngineSignals()`. The merge was:

```ts
const live = liveStats[e.name.toUpperCase()];
if (!live) return e;
const hasClosed = live.closed > 0;
return { ...e, totalPips: hasClosed ? live.totalPips : e.totalPips };
```

`hasClosed = live.closed > 0` only swaps to live data when there is at least one CLOSED trade. Most rows have `status='live'` (haven't aged out yet), so `closed=0`, so the merge kept the hardcoded mock numbers. The static array also defines per-preset `wr`, `avgPips`, `avg pips/trade`, etc., which the merge likewise kept on the false branch.

**Fix:** swap whenever `live.signals > 0` (open OR closed). Recompute `wr` and `avgPips` from live values; preserve only the static label/symbol/strategy metadata. A separate fallback path returns the static item when the engine has zero rows in `signal_log` — that's the only correct case for using mock numbers.

```ts
const enginesWithLive = useMemo(() => {
  return engines.map((e) => {
    const live = liveStats[e.name.toUpperCase()];
    if (!live || live.signals === 0) return e;
    const wr = live.closed > 0 ? Math.round((live.wins / live.closed) * 100) : 0;
    return {
      ...e,
      signals: live.signals,
      wins: live.wins,
      losses: live.losses,
      pending: live.pending,
      closed: live.closed,
      wr,
      totalPips: Math.round(live.totalPips * 10) / 10,
      avgPips: live.closed > 0 ? Math.round((live.totalPips / Math.max(live.closed, 1)) * 10) / 10 : 0,
    };
  });
}, [engines, liveStats]);
```

**Lesson (general pattern):** when a UI component has TWO data sources — a static fallback array and a live fetch — the merge logic almost always leaks the fallback unless the live fetch is EXCLUSIVELY used whenever it has data. The "swap only when there's a closed trade" gate looks like sensible conservatism, but it's the wrong axis. The right axis: `live.signals > 0`, regardless of closed/open status.

---

## Recipe #63 — Cipher BTC `Entry @ 81.00` instead of `Entry @ 81,181.10` in iOS push

**Symptom:** Cipher signals arrive in iOS push notifications truncated to two digits — `Order: BUY ↑ - Entry @ 81.00 | SL @ 81.00`. Same numbers seen in `public.signal_log.entry=81` after the listener ingests them. Missing 3 digits before the decimal.

**Diagnosed wrong twice, then right:**

- First hypothesis: "the listener regex stops at commas." Verified the regex (`[\d,]+\.\d+|\d+`) and a simulation: clean capture. **Wrong hypothesis.**
- Second hypothesis: "the cipher scanner is formatting the activation message at `:,.1f` (one decimal)." That was a real bug — but it only affects `BUY Order @ 81,181.1 : Activated`, not the original signal message. **Wrong layer for the symptom.**
- Third (correct) hypothesis: **the listener is running on an OLD process that's still using the pre-Sep-13 regex (`\d+(?:\.\d+)?`).** Sep 13 fix `8edbf677` added comma handling and was committed to source, but the running Python process hasn't been restarted.

**Why three diagnoses were needed:** a runtime bug vs. a parse-output question is the same query for both the regex AND the formatter. The diagnostic that separated them: the peek endpoint showed `entry=81` for rows the listener wrote as recently as today's date — meaning the listener is what's broken, not the scanner. (The scanner bugs were independent and should ship separately.)

**Fix path:** confirm the listener is on Railway. Find the service ID via `railway status --json`. Restart via `railway restart --service <id> --yes` (see Recipe #66 for the CLI dance). Verify next cipher signal lands with `entry=81181.10`.

**Companion fix (separately):** cipher_scanner.py and phantom_scanner.py used `:,.1f` for `BUY Order @ N : Activated` and `BUY Order @ N : SL HIT` messages, even though the underlying `trade.entry` is stored at 2-decimal precision. Replaced all `:,.1f` with `:,.2f` for these scanners (8 occurrences in cipher, 3 in phantom). 8 occurrences replaced across files `src/lib/trading_bot/cipher_scanner.py` and `src/lib/trading_bot/phantom_scanner.py`. **This is a separate bug** — not the cause of the iOS push symptom, but it would have surfaced as a follow-up.

**Lesson:** when a value is displayed wrong, audit the full path: scanner → Telegram post → listener parse → Supabase write → notify route format → iOS notification body. Each layer has its own formatter and could be the culprit. Don't stop at the first plausible hypothesis.

---

## Recipe #64 — Listener realtime subscription only listens to `INSERT`, not `UPDATE` — engine write-back invisible

**Symptom:** `/api/signals/[id]/event` is called by the engines on every TP/SL hit, the row's `tp1_hit=true` updates in `public.signal_log`. But the Engine Performance page, the signal history list, and the Past Signals feed never refresh. The pages still show stale state until a manual refresh.

**Root cause:** the listener fires realtime events (`postgres_changes`) on `INSERT` only. The engine write-back is an `UPDATE` on the same table. Without `UPDATE` in the event filter, every P&L change on a row is invisible to realtime until the next `INSERT` (which won't happen for the same `id`).

**Three files had the same bug:**
- `src/components/trading/EnginesView.tsx` — channel listener for engine stats
- `src/components/trading/ExpiredSignalsList.tsx` — realtime refresh for past signals (only INSERT, didn't even have an UPDATE listener at all)
- `src/hooks/useSignals.ts` — live signals table realtime subscription
- `src/components/trading/EngineDetailModal.tsx` — engine modal realtime subscription

**Fix (apply to all three):** subscribe to both INSERT and UPDATE. Debounce so a TP1→TP2→TP3→TP4 flurry doesn't cause 4 back-to-back fetches. 750ms is enough; 1.5s is overkill.

```ts
let pending = false;
const triggerRefresh = () => {
  if (pending) return;
  pending = true;
  setTimeout(() => { pending = false; void fetchRecent(); }, 750);
};

const channel = supabase
  .channel('engine-recent-signals')
  .on('postgres_changes',
    { event: 'INSERT', schema: 'public', table: 'signal_log' },
    () => { triggerRefresh(); })
  .on('postgres_changes',
    { event: 'UPDATE', schema: 'public', table: 'signal_log' },
    () => { triggerRefresh(); })
  .subscribe();
```

**Lesson:** every Supabase realtime subscription on a signal table must include both `INSERT` and `UPDATE` if the table is updated in place. `INSERT`-only listeners are correct for purely-append audit logs but not for any table that gets `PATCH`ed downstream. Audit `signal_log` carefully — it's both written (listener→engine write-back) and read (every UI page).

---

## Recipe #65 — Bootstrap migration for `public.signal_log` after engine pipeline was supposed to create it

**Symptom:** every query against `public.signal_log` from a Next.js route returns 0 rows / `Empty`. The Engine Performance page shows "0 SIGNALS · LIVE PERFORMANCE DATA." Selecting from Supabase Studio directly shows the table EXISTS but has no rows because the listener was writing to a different store.

**Root cause:** the engine/bot pipeline lives on the user's other computer (not this repo) and was supposed to create `public.signal_log` via direct supabase-py insert. The CREATE TABLE happened on the OTHER machine's DB but never on this Supabase project — so every query against it either returned 0 rows (if the table existed) or 42703 / "relation does not exist" (if it didn't). Migration `202607270001_create_signal_log.sql` only created `telegram_trader_signals` (NOT `signal_log`) per its docstring header, and the engine pipeline was supposed to bootstrap `signal_log` itself.

**Fix:** shipped `supabase/migrations/20260918_bootstrap_signal_log_pipeline.sql`. Idempotent. Does ALL of:

1. `CREATE TABLE IF NOT EXISTS public.signal_log (...)` — full schema with `id TEXT PK`, pair/direction/entry/sl/tp1-4, `tp*_hit`/`sl_hit`/`status`/`engine`/`strategy`/`source`, sent_at with the source CHECK constraint `('channel', 'bot', 'manual')`
2. `ALTER TABLE public.signal_log DISABLE ROW LEVEL SECURITY` — match the existing `202607282200_signal_log_disable_rls.sql`
3. 9 indexes — `(status)`, `(pair)`, `(channel_id)`, `(sent_at DESC)`, `(pair, sent_at DESC)`, `(strategy, sent_at DESC)`, `(engine, sent_at DESC)`, `(telegram_message_id)` covering the queries from `EnginesView`, `/api/signals/history`, `/api/home/recent-signals`
4. `ALTER PUBLICATION supabase_realtime ADD TABLE public.signal_log` — every realtime subscription will silently not fire without this

User applies in Supabase Studio SQL editor.

**Lesson (general pattern):** when a table is referenced by multiple files in the codebase AND populated by an external pipeline (a separate Python bot, another machine, an external service), the migration files in the codebase should bootstrap that table. **Don't trust that the external pipeline will create the table on the same DB project.** If a row count from Studio SQL doesn't match what the app expects, the table might not exist on this project at all.

---

## Recipe #66 — Railway CLI service discovery + restart pattern (no hang, no prompt)

**Symptom:** `railway restart --service <id>` hangs forever, prompts for confirmation in non-interactive mode, or returns `Error: Not authenticated` from the GraphQL API at `backboard.railway.com/graphql/v2`.

**The dance that works:**

```bash
# 1. Find the service ID for the listener (or any service)
railway status --json | jq '.environments.edges[].node.serviceInstances.edges[].node | {id, serviceId, serviceName: ., latestDeploymentId: .latestDeployment.id}'
# Note serviceId like "<service-uuid>"

# 2. Restart (must pass --yes for non-interactive)
railway restart --service <service-uuid> --yes
```

The `--yes` flag is mandatory. Without it the CLI waits on a stdin `y/n` that never comes.

**Don't try the GraphQL API directly with a Bearer token** — Cloudflare returns `error code: 1010` (banned) at `backboard.railway.com/graphql/v2`, even with a valid token. The CLI uses a different authenticated session that gets through.

**Don't try `https://api.railway.com/v2/projects/<id>/services`** — that endpoint returns 404. The actual REST path is via the websocket-driven CLI.

**For runtime diagnostic verification:** `railway logs --service <service-uuid> --lines 50` will show whether the listener restart actually picked up the new code. Look for timestamps after the restart and verify the new source paths appear in any `listening on 0.0.0.0:8080` line.

---

## Recipe #67 — `Source CHECK` constraint pitfall on `signal_log`

**Symptom:** `/api/signals/[id]/event` returns 500 `{"error":"new row for relation \"signal_log\" violates check constraint \"signal_log_source_check\""}` when the bot engine fills in `engine='ENGINE_G'` for a `strategy='ENGINE_G'` write.

**Root cause:** the engine write-back route initially passed `source: 'engine'` but the table's `source` column has `CHECK (source IN ('channel', 'bot', 'manual'))`. `'engine'` is not in the constraint, so it fails.

**Fix:** map `'engine'` → `'bot'` (semantically correct — the engine bot is the writer). Comment the mapping in code so a future reader doesn't try to "fix" the value back to `'engine'`. Always check the `CHECK` constraint before adding a literal to a route's INSERT/UPDATE path. Restated: **`column=literal` writes fail-closed** when the literal isn't in a CHECK constraint.

**Lesson:** add `EXPLAIN` to the diagnostic ladder for 500 errors on INSERT/UPDATE routes: open the route, find the literal, grep for the column's CHECK constraint in `supabase/migrations/`. Faster than browsing the running DB.

---

## Recipe #68 — Dual-auth for engine write-back routes (bearer preferred, cookie fallback)

**Symptom:** `/api/signals/[id]/event` returns 401 for engine bots even when the shared secret is sent as `Authorization: Bearer ***`. The route's `createServerClient().getSession()` returns null because the bot doesn't have a logged-in Supabase session — only an env-var bearer.

**Two-tier pattern that works (after `bf31207e`):**

```ts
let userId: string | null = null;
const authHeader = req.headers.get('authorization') ?? '';
const bearerToken = authHeader.replace(/^Bearer\s+/i, '').trim();
if (bearerToken) {
  const svcBearer = createServiceClient();
  const { data: userData, error } = await svcBearer.auth.getUser(bearerToken);
  if (userData?.user) userId = userData.user.id;
}
if (!userId) {
  const supabase = await createClient();
  const { data: { session } } = await supabase.auth.getSession();
  if (session?.user?.id) userId = session.user.id;
}
if (!userId) return NextResponse.json({ error: 'Not authenticated' }, { status: 401 });
```

Same pattern as `/api/partners/me/whitelabel-referral` after Recipe #15's `108cb7fb` patch.

**Important caveat:** `svc.auth.getUser(token)` validates against the **user** JWT, NOT against a service-role shared secret. The shared-secret pattern (separate from user auth) requires a different validator, e.g. comparing to `process.env.INTERNAL_API_TOKEN` directly:

```ts
const internalToken = process.env.INTERNAL_API_TOKEN;
if (bearerToken === internalToken || bearerToken === process.env.PUSH_API_TOKEN) {
  userId = 'service-bot';  // marker for engine write-back
}
```

This is the pattern `/api/signals/[id]/event` evolved to. The route accepts BOTH a user JWT (for browser calls) and the shared secret (for engine bots). Two allowed token types, one route. Add `INTERNAL_API_TOKEN` to Railway env vars if missing — don't reuse `PUSH_API_TOKEN`.

**On the client:** `adminFetch` (in `src/lib/admin-fetch.ts`) sends `Authorization: Bearer *** AND cookies. Use it for engine-action calls, not `fetch()` which only sends cookies.

---

## Recipe #69 — Cipher/Phantom `:.1f` activation-message formatter dropping precision (independent of the listener regex bug)

**Symptom:** Cipher activations read `BUY Order @ 81,181.1 : Activated` — one decimal dropped for BTC trades that should be 2-decimal precision.

**Root cause:** `src/lib/trading_bot/cipher_scanner.py:786` and `phantom_scanner.py` activation-message builders used `f"{trade.entry:,.1f}"` even though `trade.entry` is already rounded to 2 decimals. The `:,.1f` format strips one decimal of precision.

**Fix:** `:,.1f` → `:,.2f` for ALL price formatters in `cipher_scanner.py` (8 occurrences) and `phantom_scanner.py` (3 occurrences). The phantom scanner had similar `:,.1f` only in debug logs — also fixed for consistency.

**Lesson:** when the underlying value is already at the correct precision, the format string must match. `:,.1f` looks like it's documenting the precision when actually it's the source of the bug. **Audit format strings against the value's stored precision whenever the displayed number is wrong.** Generic substitution (`:,.1f` → `:,.2f`) is cheap enough to do across the whole engine-bot directory; verified no other format strings mis-state the precision.

---

## Recipe #70 — Direction-aware pips calc using highest-hit TP and DB fallback

**Symptom:** Engine Performance page shows positive pips on SL-hit trades, or shows the same pips regardless of TP1 vs TP2 vs TP3 vs TP4.

**Wrong calc (before fix):**

```ts
const isWin = r.tp1_hit || r.tp2_hit || r.tp3_hit || r.tp4_hit;
const isLoss = r.sl_hit;
let pips = 0;
if (isWin && r.tp1) pips = Math.abs(r.tp1 - r.entry);   // ignores direction
else if (isLoss) pips = -Math.abs(r.sl - r.entry);
```

**Correct calc (after fix):**

```ts
const pipUnit = (r.pair ?? '').toUpperCase().endsWith('JPY') ? 0.01 : 0.0001;
const tps = [
  { hit: r.tp4_hit, price: r.tp4 },
  { hit: r.tp3_hit, price: r.tp3 },
  { hit: r.tp2_hit, price: r.tp2 },
  { hit: r.tp1_hit, price: r.tp1 },
];
let pips = 0, resolved = false;
for (const t of tps) {
  if (t.hit && typeof t.price === 'number' && t.price > 0) {
    const raw = isBuy ? (t.price - r.entry) : (r.entry - t.price);
    pips = raw / pipUnit;
    resolved = true;
    break;
  }
}
if (!resolved && r.sl_hit) {
  const raw = isBuy ? (r.sl - r.entry) : (r.entry - r.sl);
  pips = raw / pipUnit;
}
// Prefer the engine-computed pips column when non-zero.
if (typeof dbPips === 'number' && dbPips !== 0) pips = dbPips;
```

**Lesson:** pips math that ignores direction gets the WRONG sign for half the trades. JPY pairs need a different `pipUnit` than non-JPY (0.01 vs 0.0001). Use the highest-hit TP, not TP1 alone — engines often exit at TP3, not TP1. **And always prefer the DB-computed pips over the page's recalculation** — the engine's broker-close-time value is the canonical answer.

**Helpful diagnostic:** `SELECT engine, pips, status, direction FROM signal_log ORDER BY sent_at DESC LIMIT 50` — eyeball whether positive pips line up with BUY trades where `tp_price > entry`, or SELL trades where `tp_price < entry`. If positive pips line up with losing SELL trades, the direction term is being skipped somewhere.

---

## Recipe #71 — Engine write-back + history feed bug cluster (TP-on-SL is WIN, not LOSS + TP chips should show real prices + time-pill overlap with LOSS)

Four related fixes in one push on the Past Signals feed (`src/components/trading/ExpiredSignalsList.tsx`, `/api/signals/history`):

1. **TP-on-SL is WIN, not LOSS.** Previous state logic: SL + any TP hit → `closed_loss`. Wrong. If TP1 hit before SL, the trade booked partial pips and was actually a partial win. New: SL + any TP → `closed_win` (uses highest-hit TP for pip count).

2. **TP chips should not include the price inline on collapsed rows.** User wanted minimal — `TP1 ✓` `TP2 ·` — not `TP1 ✓ 1.0830`. Real numbers still appear in the expanded detail panel.

3. **Time-pill on collapsed row was overlapping the LOSS state pill** in the 8-column grid. Removed the time column from the collapsed view; time appears in the expanded footnote only.

4. **Pip count must use highest-hit TP, computed in the route** not from the DB column which may be wrong on legacy rows. Same direction-aware calc as Recipe #70.

Bonus fix (from earlier in the session): **the Past Signals feed was filtering `status NOT IN ('live', 'pending')`** so an expired signal sits invisible until something updates its status. Added `POST /api/signals/[id]/settle` so the SwipeSignalCard's `onSettled('expired')` calls update `status` in the DB and the row appears immediately. Wire dual-auth (Recipe #68) once for both routes.

---

## Recipe summary (this session)

- **#62** — Engine Performance mock-data leak: swap merge on live.signals > 0, not live.closed > 0
- **#63** — Cipher 5-digit push: listener running on old regex; restart it; companion `:,.1f` → `:,.2f` in scanners
- **#64** — Realtime UPDATE subscription gaps: every Supabase realtime listener on `signal_log` must include `UPDATE`, not just `INSERT`
- **#65** — Bootstrap migration for `signal_log` when external pipeline doesn't create it
- **#66** — Railway CLI service discovery + non-interactive restart: `railway status --json`, `--yes` flag required
- **#67** — Source CHECK constraint: map `'engine'` → `'bot'` (bot is the writer)
- **#68** — Dual-auth routes: bearer-token first (shared secret OR user JWT), cookie-session fallback
- **#69** — `:,.1f` → `:,.2f` for ALL price formatters in cipher + phantom scanners
- **#70** — Direction-aware pips calc with highest-hit TP and DB-column fallback
- **#71** — Past Signals feed bug cluster: TP-on-SL is WIN, no inline prices on collapsed, time-pill overlap

All committed Sep 19-20, 2026. Topic tags for skill triggers: `engine performance mock data`, `closed-only-merge`, `cipher 5-digit`, `comma regex`, `realtime update`, `bootstrap migration signal_log`, `railway service restart`, `source check constraint`, `INTERNAL_API_TOKEN`, `dual auth route`, `bearer engine bot`, `direction-aware pips`, `closed win` (TP-on-SL), `past signals feed`, `signal history row expansion`.
