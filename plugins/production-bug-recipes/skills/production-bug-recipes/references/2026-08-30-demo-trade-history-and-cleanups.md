# Trade history flow, in-box infinite scroll, and dashboard cleanup — Aug 30 2026 (Rounds 32+)

This file extends `2026-08-30-demo-close-freeze-and-quick-order.md` with
the second half of the day. Three durable patterns emerged: closed
demo positions must flow into the trade history tab as the broker-shaped
records, infinite scroll inside a fixed-height container needs the
container as the IntersectionObserver's `root`, and the home dashboard
went through three explicit user-requested cleanups (drop SIMULATED
badge, drop FX news ticker, swap MT5 → "trading account" copy).

---

## Recipe #67 — Closed demo positions must populate `recentHistory` (added Aug 30 2026)

**Symptom:** the user closes a demo position. The position card correctly
disappears from Live Positions. The analytics strip also updates. But
the **Trade History tab stays empty**, the **trade journal page shows
nothing**, and the win/loss counts in the analytics strip are stuck at
zero even after several settled trades.

**Root cause:** `buildDemoAccountData()` (the shared demo data
synthesizer used by `/account`, `/account-data`, and `/realtime/poll`)
returned `recentHistory: []` and `dashboardHistory: []` for demo users.
The closed positions lived in `position_snapshot` but **never
flowed to**:
- The home dashboard's Trade History tab
- The trade journal page (`/dashboard/journal`)
- The analytics strip's win rate, total P&L, wins, losses

**The fix — fetch closed positions and map them to the broker-shaped
history records:**

```ts
// Inside buildDemoAccountData, AFTER the open-positions block:
let closedCount = 0;
let closedRows: any[] = [];
try {
    const { data: closed, count } = await svc
        .from('position_snapshot')
        .select('*', { count: 'exact' })
        .eq('user_id', userId)
        .eq('source', 'demo')
        .not('closed_at', 'is', null)
        .order('closed_at', { ascending: false })
        .limit(500);
    closedRows = closed ?? [];
    closedCount = count ?? closedRows.length;
} catch { /* older DBs may not have these columns */ }

const demoHistory = closedRows.map((row: any) => ({
    // the broker-shaped field names so the client mapBrokerToSignal/result paths Just Work
    id: row.broker_position_id ?? `demo-history-${row.id ?? Math.random()}`,
    orderId: row.broker_position_id,
    tradableInstrumentId: row.symbol,
    routeId: row.symbol,
    qty: Number(row.qty ?? 0),
    side: row.side,
    type: row.side,
    status: 'FILLED',
    filledQty: Number(row.qty ?? 0),
    avgOpenPrice: Number(row.avg_price ?? 0),
    avgClosePrice: Number(row.close_price ?? row.current_price ?? row.avg_price ?? 0),
    openPrice: Number(row.avg_price ?? 0),
    closePrice: Number(row.close_price ?? row.current_price ?? row.avg_price ?? 0),
    stopPrice: Number(row.stop_loss ?? 0),
    takeProfit: Number(row.take_profit ?? 0),
    avgPrice: Number(row.avg_price ?? 0),
    placedDate: row.opened_at,
    lastModified: row.closed_at ?? row.opened_at,
    closedAt: row.closed_at,
    openDate: row.opened_at,
    isTriggerClose: row.close_reason === 'SL_hit' || row.close_reason === 'TP_hit',
    positionId: row.broker_position_id,
    text: row.symbol,
    pnl: Number(row.realized_pnl ?? 0),
    profit: Number(row.realized_pnl ?? 0),
    fees: 0,
    // Custom fields the dashboard UI reads
    netProfit: Number(row.realized_pnl ?? 0),
    entryPrice: Number(row.avg_price ?? 0),
    lotSize: Number(row.qty ?? 0),
    pair: row.symbol,
    symbol: row.symbol,
    timestamp: row.closed_at ?? row.opened_at,
    provider: 'Demo',
    closeReason: row.close_reason ?? 'user_closed',
}));

// Also compute real analytics from the closed rows
let wins = 0, losses = 0, totalPnl = 0;
for (const row of closedRows) {
    const pnl = Number(row.realized_pnl ?? 0);
    totalPnl += pnl;
    if (pnl > 0) wins++;
    else if (pnl < 0) losses++;
}
const settled = wins + losses;
const winRate = settled > 0 ? (wins / settled) * 100 : 0;

return NextResponse.json({
    // ... existing fields ...
    recentHistory: demoHistory,
    dashboardHistory: demoHistory.slice(0, 100),
    totalHistoryCount: demoHistory.length,
    analytics: {
        total_trades: totalTrades,
        win_rate: Number(winRate.toFixed(1)),
        total_pnl: Number(totalPnl.toFixed(2)),
        open_positions: openPositions,
        today_net: Number(totalPnl.toFixed(2)),
        today_gross: Number(totalUnrealized.toFixed(2)),
        wins, losses, settled_trades: settled,
    },
});
```

**The class-level rule:** any time a demo simulator writes to the
position table, the SAME handler must also write to the history
field on the next response. The history is the user's proof that
their trades happened — without it, the simulator feels broken even
when the math is right. Same applies to any system that
synthesizes a broker-shaped response for a paper/demo account.

**Pairs with:** Recipe #61 (closed-positions-demo-flow) — that one
fixed the response shape; this one populates the field. Recipe #62
(realized P&L balance tracking) — together they make the demo
account ledger feel like a real brokerage.

---

## Recipe #68 — Infinite scroll INSIDE a fixed-height container (added Aug 30 2026)

**Pattern:** the user wants a list that shows N items in a fixed-height
container (~3 rows), and the user scrolls WITHIN the container to see
more. The first attempt — putting the IntersectionObserver on a
sentinel outside the container with `rootMargin: '120px'` — failed
because the sentinel lives inside a 196px box that's already on screen,
so the observer never fires.

**The fix — use the scrollable container as the IntersectionObserver's
`root` and put the sentinel INSIDE that container:**

```tsx
// In TradingDashboardView, for the Trade History tab:
const [visible, setVisible] = useState(PAGE_SIZE);
const sentinelRef = useRef<HTMLDivElement | null>(null);
const scrollRef = useRef<HTMLDivElement | null>(null);

useEffect(() => {
    const sentinel = sentinelRef.current;
    const scrollRoot = scrollRef.current;
    if (!sentinel) return;
    const observer = new IntersectionObserver(
        (entries) => {
            const [entry] = entries;
            if (entry.isIntersecting) setVisible(v => v + PAGE_SIZE);
        },
        scrollRoot
            ? { root: scrollRoot, rootMargin: '0px 0px 40px 0px' }
            : { rootMargin: '120px' }     // fallback for tests / pre-mount
    );
    observer.observe(sentinel);
    return () => observer.disconnect();
}, [list.length, activeSection]);

return (
    <div className="history-list" ref={scrollRef}>
        {list.slice(0, visible).map(item => <Row key={item.id} {...item} />)}
        {list.length > visible && (
            <div ref={sentinelRef} className="infinite-scroll-sentinel">
                <Loader2 size={16} className="spin" />
            </div>
        )}
    </div>
);
```

```css
.history-list {
    display: flex;
    flex-direction: column;
    gap: 0.5rem;
    max-height: 280px;          /* ~3 full rows + gap */
    overflow-y: auto;
    padding-right: 4px;
    scrollbar-width: thin;
    scrollbar-color: rgba(255, 255, 255, 0.18) transparent;
}
.history-list::-webkit-scrollbar { width: 6px; }
.history-list::-webkit-scrollbar-thumb {
    background: rgba(255, 255, 255, 0.18);
    border-radius: 3px;
}
```

**Three key details:**

1. **The sentinel MUST be inside the scrollable container.** If it's
   outside, the observer watches the viewport vs the sentinel, and since
   the sentinel is already on-screen, the observer never fires.

2. **`root: scrollContainer` is mandatory.** Without it, the observer
   uses `null` = the viewport. With a 196px-tall container, the
   sentinel is always in the viewport, so the observer fires
   immediately on first render and never fires again.

3. **Use `rootMargin: '0px 0px 40px 0px'`** (40px from the bottom
   edge of the container) so the user doesn't see the spinner — the
   next batch loads just before they reach the bottom.

**The class-level rule:** whenever a list lives inside a
`max-height + overflow-y: auto` container and uses infinite scroll,
the IntersectionObserver MUST use the container as `root` and the
sentinel MUST be inside the container. The default viewport root
will silently fail.

**Pairs with:** Recipe #66 (page-level infinite scroll) — that's the
version for the Live Positions grid which scrolls the whole page.
This recipe is the in-container variant for the Trade History tab.

---

## Recipe #69 — Home dashboard cleanup pass (SIMULATED badge + news ticker + MT5 copy) (added Aug 30 2026)

Three small but explicit user-requested cleanups on the home
dashboard, all in one session:

### 69a. Remove redundant SIMULATED badge

The balance card had TWO demo indicators:
1. Top-right pill: `"Connected"` (live broker) or `"Demo Active"` (built-in demo) — **kept**
2. Centered purple/cyan badge: `"SIMULATED · Demo Account"` with sparkle — **removed**

**The lesson:** when a card already has a clear status pill at the
top-right ("Demo Active" vs "Connected"), don't add a SECOND
centered badge that says the same thing. Two indicators for the same
state reads as clutter. Pick one, make it clean.

### 69b. Remove FX street news ticker

The `<MarketTicker />` component rendered below the balance card with
scrolling financial news headlines. The user said:

> "Let's remove the live fx street news feed under the balance card"

**The lesson:** the news ticker was visible on first paint and
dominated visual attention. Useful information? Yes. But it competed
with the balance card for attention and pushed the more important
analytics strip + positions/history tab below the fold. Removed.

Note: the MarketTicker component file is still in the codebase —
it's used on the community tab. The component is fine; it just
didn't belong on the home dashboard.

### 69c. MT5 → "trading account" copy swap

The empty-state messages in the Live Positions + Trade History tabs
referenced "MT5":

```diff
- "Trades executed on your MT5 account will appear here in real time."
- "Connect your MT5 account to see live positions."
- "Closed trades from your MT5 account will appear here."
+ "Trades executed on your trading account will appear here in real time."
+ "Connect your trading account to see live positions."
+ "Closed trades from your trading account will appear here."
```

**The lesson:** "MT5" is a specific broker platform. The app supports
both real broker connections AND built-in demo accounts, and
neither is actually MT5. The MT5 mention was leftover from an earlier
architecture. When a UI string refers to a specific technology name
but the code now supports multiple providers, use a generic term
("trading account", "broker account", "connected account") instead.

**The class-level rule:** when supporting multiple connection types
(real broker, demo simulator, different brokers), the empty-state
copy should be provider-agnostic. Specific names belong only when
the feature is genuinely provider-locked.

---

## Files touched this session (second half)

| File | Purpose |
|---|---|
| `src/app/api/_demo-account.ts` | Added `recentHistory` + `analytics` from closed rows |
| `src/components/trading/TradingDashboardView.tsx` | Removed Copy Trade button, SIMULATED badge, MarketTicker; MT5→trading account; trade-history scroll container; infinite scroll inside container; SL/TP indicator already in via Recipe #63 |
| `src/components/trading/TradingDashboardView.css` | `.history-list` max-height + custom scrollbar; mobile tightening of `.history-row` |
| `src/app/api/broker/position/[id]/route.ts` | Augment `guided_account_starting_balance` with realized P&L on close (Recipe #62) |
| `src/app/api/_demo-account.ts` | SL/TP auto-close inside broker poll (Recipe #63) |

---

## Pairs with

- `this skill` Recipe #61 (demo close freezes) + Recipe #62 (realized P&L balance) + Recipe #63 (SL/TP auto-close) — together Recipes #67–69 close the demo lifecycle loop: open → manage → auto-close → history → balance
- `this skill` Recipe #66 (page-level infinite scroll) — Recipe #68 is the in-container variant
- `this skill` Recipe #56 (i18n plumbed vs wired) — Recipe #69c follows the same principle: when the codebase generalizes, the copy must follow
- `user/user-interaction-standards` — Recipes #69a/b/c are all explicit user cleanups, no design guesswork
