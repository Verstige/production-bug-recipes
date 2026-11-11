# 2026-09-09 — Empty-state flash, white-label broker account-data, and broker-dispatch mirror bug class

## What broke

Three connected bugs hit on Sep 9, 2026:

1. **Empty-state UI flash for white-label broker users** — The home balance card showed
   "Connect Account / Tap to enable live trading / Try a demo account" for
   ~1-2s on every page load, even for users who were connected to white-label broker.
   Caused by `whitelabelConnected` not being in the empty-state condition (only
   `brokerConnected` was checked).

2. **white-label broker account-data loads "slowly" + trade history missing** —
   `TradingContext.doReconnect()` was calling `/api/broker/account-data`
   for white-label broker users. That endpoint requires `broker_access_token` on `user_accounts`,
   which white-label broker users don't have (they have `whitelabel_access_token`). So the
   endpoint 400'd, the TradingContext fell back to cached state, and the UI
   showed stale/empty data forever.

3. **Live P&L always $0.00 for white-label broker users** — The 10-second price poller in
   `TradingContext.tsx` was gated on `!brokerConnected`, so it never
   fired for white-label broker users. Without polled prices, `getLivePnL()` returned 0.

## Root cause (one-line answer for all three)

Same class of bug repeated across three layers: any UI/poller/gate that
checked only `brokerConnected` skipped white-label broker users, even when white-label broker
was fully connected. After fixing the route-layer broker dispatch for
`/api/broker/quote` (Sep 9 earlier), the *client-side* equivalents
were never updated.

## What shipped (3 commits)

1. **`feat(whitelabel): empty-state fix`** — added `whitelabelConnected` +
   `connectionChecked` to the empty-state UI condition, persist both to
   `broker_session_cache` localStorage, hydrate on mount.
2. **`fix(whitelabel): live P&L poller now runs for white-label broker users`** — changed
   `if (!brokerConnected) return` to
   `if (!brokerConnected && !whitelabelConnected) return` in
   `TradingContext.tsx` line 599.
3. **`fix(whitelabel): add /api/whitelabel/account-data`** — new dedicated route
   that proxies to white-label broker's `/api/tap/{positions,orders,ordersHistory,
   account-state}` in parallel, maps fields to broker shape defensively,
   returns same shape as `/api/broker/account-data`. TradingContext
   dispatches to it for white-label broker users.

## Class-level pattern (the real lesson)

**Any time you add a new broker, audit EVERY layer that gates on broker
state. The route-layer fix is necessary but not sufficient.**

Specifically:

- **Route layer:** `broker_platform` dispatch → route calls the right
  provider server-side. UI calls unified endpoint, broker-agnostic.
  ✅ Fixed for `/api/broker/quote` (Sep 9), `/api/broker/account-data` (Sep 9).

- **Client-side `useEffect` early-return gates:** `if (!brokerConnected) return`
  silently skips white-label broker users. Search for `brokerConnected` in `useEffect`
  deps + early-return patterns and add the new broker.
  ✅ Fixed in `TradingContext.tsx` line 599 (price poller).
  ⚠️ NOT YET FIXED: SSE `EventSource` subscription (line ~498),
  `useEffect` deps around line 334/344/354/366 (analytics updates).

- **Conditional renders:** any UI conditional that shows/hides based on
  "is the user connected to a broker?" must enumerate every broker. The
  empty-state UI is the worst offender because it's user-visible.
  ✅ Fixed.

- **State flags:** aggregations like `isConnected = mt5Connected ||
  dxConnected || matchTraderConnected || brokerConnected` need to
  include the new broker. They are not the right gate for empty-state UI
  because they resolve AFTER all broker health checks complete.
  ✅ Empty-state now uses both `whitelabelConnected` and `connectionChecked`.

- **Polling handlers:** any `setInterval` / SSE / fetch polling that fires
  on a broker condition. Same pattern as useEffect gates.
  ✅ Price poller fixed. SSE + analytics polling still gated on
  `brokerConnected` only — known follow-up.

## The mirror bug class

The Sep 9 partner-api-integrations addendum already covered the
**route-layer broker dispatch** pattern. What was MISSING from that
addendum (and what bit us three times in one day) is the **client-side
mirror** of that dispatch:

```
Route-layer dispatch added:
  ✅ Server picks the right provider based on broker_platform
  ✅ Unified endpoint contract on the wire

Client-side mirror NOT added:
  ❌ useEffect gates still check only the legacy broker
  ❌ Conditional renders still check only the legacy broker
  ❌ State flag aggregations still miss the new broker
  ❌ SSE subscriptions still open only when legacy broker is true
```

**When to use this audit pattern:** every time you add a new broker to a
broker-dispatching route, ALSO grep the codebase for the legacy broker
flag (`brokerConnected` here) in:
- `useEffect` deps + early-return gates
- `if (XConnected)` render conditions
- `useState(!!Y)` initializers that read from cache
- `useEffect(() => { if (!Y) return; ... }, [Y])` patterns
- `setInterval` / polling handlers tied to a broker flag
- SSE `EventSource` connection lifetimes

## Quick grep recipe to find the gaps

```bash
cd ~/Projects/the platform

# 1. Find every place that gates on the broker-only
grep -rn 'brokerConnected' src/ --include='*.ts' --include='*.tsx' \
  | grep -v 'test\|spec' \
  | head -30

# 2. For each hit, check whether white-label broker users should also pass:
#    - if (!brokerConnected) return  ← CLIENT-SIDE GATE
#    - if (brokerConnected) { ... }
#    - isConnected && brokerConnected  ← AGGREGATE FLAG
#    - useEffect([..., brokerConnected])  ← DEP ARRAY
#    - new EventSource(...) only when brokerConnected  ← SSE/WS

# 3. For every CLIENT-SIDE GATE, ask: "Does white-label broker need this too?"
#    - price poller: YES → already fixed
#    - SSE realtime: YES → likely still broken for white-label broker
#    - analytics refresh: YES → likely still broken for white-label broker
#    - refreshTerminalData caller: YES → likely still broken for white-label broker
# 4. For every render condition, add || whitelabelConnected
# 5. For every state initialiser that reads from cache, add whitelabelConnected
```

## white-label broker-specific data shape gotchas

When proxying white-label broker's `/api/tap/*` responses, the field names don't
always match the broker shape. The `/api/whitelabel/account-data` route uses
defensive mapping:

```typescript
const symbol = String(p?.symbol ?? p?.tradableInstrumentId ?? 'Unknown');
const qty = Number(p?.qty ?? p?.quantity ?? p?.volume ?? 0);
const avgPrice = Number(p?.avgPrice ?? p?.price ?? p?.openPrice ?? 0);
const pnl = Number(p?.pnl ?? p?.unrealizedPl ?? p?.openPnl ?? 0);
const stopLoss = slOrder?.price ?? p?.stopLoss ?? p?.sl ?? null;
const takeProfit = tpOrder?.price ?? p?.takeProfit ?? p?.tp ?? null;
```

If white-label broker returns an empty array OR throws 401, the route returns
`{ connected: false, ... }` instead of crashing. The route exposes a
`partialErrors` field on every successful response so debugging is
straightforward without inspecting logs.

**Class-level rule:** when proxying between two systems that should be
shape-compatible but might not be, **defensive mapping** (try multiple
field name variants) + **raw passthrough** (`raw: p` in every mapped
object) + **`partialErrors` field** on the response is the safe pattern.
The raw field lets you debug from the browser console without redeploying.

## The empty-state + connectionChecked pattern

For the empty-state UI, the simple condition `!brokerConnected` is
wrong because:
- white-label broker users have `brokerConnected=false` but ARE connected.
- First-ever loads have BOTH flags false until checks resolve.

The right pattern:

```typescript
// Three states to handle:
// 1. User has a cache entry → use cached values, no flash
// 2. First-ever load → hide empty state until health checks resolve
// 3. Disconnected user → show empty state immediately

const [whitelabelConnected, setwhite-label brokerConnected] = useState<boolean>(!!_tlCache?.whitelabelConnected);
const [connectionChecked, setConnectionChecked] = useState<boolean>(!!_tlCache?.connectionChecked);

// Persist both on every check:
useEffect(() => {
    fetch('/api/whitelabel/health').then(...).then((data) => {
        setwhite-label brokerConnected(data?.user_connected === true);
        setConnectionChecked(true);
        writeCache({
            ...readCache(),
            whitelabelConnected: ...,
            connectionChecked: true,
            ts: Date.now(),
        });
    });
}, []);

// Render:
{!brokerConnected && !whitelabelConnected && connectionChecked && (
    <EmptyStateUI />
)}
```

The third condition (`connectionChecked`) is the trick that prevents the
flash. Without it, on first-ever load both flags are `false` → empty state
shows immediately → looks broken for users who were about to see their
data populate ~1s later.

## When this pattern appears next time

Any new broker, any new connection state, any new "are we connected"
check — the gate pattern needs to enumerate. Don't rely on `isConnected`
aggregations because they resolve after the empty state would have already
flashed. The actual fix is per-broker explicit gates + a "verified"
boolean that flips true after both checks resolve.

## Related recipes

- the route-layer broker dispatch recipe (predecessor pattern) --
  the same flow, one layer up, before the empty-state class was fixed.
- `nextjs-railway-broken` — companion diagnostic for when chunks are stale
  on CDN after deploy.
- `railway-deploy-verify-loop` — the loop that ensures chunks DO update
  even when CDN is caching old ones.
