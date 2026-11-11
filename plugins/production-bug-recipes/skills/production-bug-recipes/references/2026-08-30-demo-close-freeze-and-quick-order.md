# Demo account closing flow fixes, Quick Order panel, and shared buildDemoAccountData refactor — Aug 30 2026 (Rounds 31x–32)

The user reported a cascade of bugs around demo account state and the
Quick Order panel. This session also shipped the reusable Quick Order
panel for the home page, infinite scroll on Live Positions + Trade
History, the MT5→"trading account" copy swap, removal of the Copy
Trade button, mobile calendar polish, and the Spanish i18n wiring on
the Settings page. Six durable patterns surfaced.

---

## Recipe #61 — Demo close "freezes the dashboard" because three endpoints returned different shapes for demo users (added Aug 30 2026)

**Symptom:** the user clicks **Close Position** on a live position card. The position correctly disappears from the Live Positions grid. But the balance card stops ticking, the position list never refreshes again, and the user has to force-quit and reopen the app to recover.

**Root cause:** three the broker-related endpoints had inconsistent demo handling.

| Endpoint | What demo users got | Effect |
|---|---|---|
| `/api/broker/account` | `{ connected: false }` | TradingContext.refreshBrokerData() early-returns without updating balance/equity/signals |
| `/api/realtime/poll` | `{ ok: false }` | SSE broker stops emitting snapshots (the broker's state.lastErrorAt gets set, retry backoff kicks in) |
| `/api/broker/account-data` | Correct demo data | Only this one had the demo intercept |

`/api/broker/account` and `/api/realtime/poll` both gated on `broker_access_token` which demo users don't have. Real the broker users never see this — only demo accounts.

When the user clicked Close:

1. `closeTerminalPosition()` called `setSignals(prev.filter(...))` and `setBrokerPositions(prev.filter(...))` — position correctly removed from local state ✓
2. After 2s, `refreshBrokerData()` fired → fetched `/account` → got `connected: false` → early-returned without updating balance/equity/results
3. The SSE broker hit `/realtime/poll` every 30s → got `ok: false` → stopped emitting snapshots
4. **No more updates from any source** → state appears frozen
5. Cached state in `broker_session_cache` desynced from DB → dashboard stuck

**The fix — extract `buildDemoAccountData` to a shared module and call it from all three endpoints when `broker_connection_status === 'demo'`:**

```ts
// src/app/api/_demo-account.ts (NEW shared module)
export async function buildDemoAccountData(params: {
    userId: string;
    accountId: string;
    accountName?: string;
    startingBalance?: number;
    svc: ServiceClient;
}): Promise<NextResponse> {
    // 1. Read position_snapshot for open demo positions
    // 2. Read guided_account_starting_balance for starting capital
    // 3. Fetch live Yahoo prices from /api/demo/price
    // 4. Compute live P&L per position via demoPipSize/demoPipValue
    // 5. Return the broker-shaped response (positions, balance,
    //    equity, analytics, allAccounts, ...)
    // ...
}
```

```ts
// /api/broker/account/route.ts
const { data: demoCheck } = await svc
    .from('user_accounts')
    .select('broker_connection_status, guided_account_starting_balance, broker_account_name')
    .eq('id', userId)
    .maybeSingle();
if (demoCheck?.broker_connection_status === 'demo') {
    return await buildDemoAccountData({
        userId,
        accountId: `demo-account-${userId}`,
        accountName: demoCheck.broker_account_name ?? 'Demo Account',
        startingBalance: demoCheck.guided_account_starting_balance ?? 0,
        svc,
    });
}

// /api/realtime/poll/route.ts
if (publicUser.broker_connection_status === 'demo') {
    const demoRes = await buildDemoAccountData({
        userId,
        accountId: publicUser.broker_account_id,
        accountName: publicUser.broker_account_name ?? 'Demo Account',
        startingBalance: publicUser.guided_account_starting_balance ?? 0,
        svc,
    });
    const demoBody = await demoRes.json();
    return NextResponse.json({ ok: true, ...demoBody });
}
```

Also: extend the `user_accounts` SELECT in `/api/realtime/poll` to include `broker_connection_status`, `broker_account_name`, and `guided_account_starting_balance` — the existing SELECT only had the broker token columns.

**The class-level rule:** any time you have a `broker_connection_status === 'demo'` branch in ONE broker route, every other broker route that talks to the same user MUST have the same branch. Otherwise the TradingContext will get inconsistent shapes depending on which route fires next, and the UI will desync after any state change (close, refresh, switch account).

**Diagnostic when the demo dashboard freezes after a state change:**

1. Open browser DevTools → Network tab → filter by `/api/broker/`
2. Watch what happens around the freeze moment
3. If you see `/api/broker/account` returning `connected: false` after a Close, the demo intercept is missing on that endpoint
4. If you see the SSE stream go silent (no `/api/realtime/stream` events for >30s), the broker's poll is failing → check `/api/realtime/poll`

---

## Recipe #62 — Demo realized P&L never updates the user's starting balance (added Aug 30 2026)

**Symptom:** the user closes a demo position that was +$50. The position card correctly disappears. The trade history card shows "Win +$50.00". But the **balance card stays at $10,000** — same as before the trade. Open 5 winning trades, balance still $10,000. Close them, balance still $10,000. The wins are silently disappearing from the user's total.

**Root cause:** `closeDemoPosition` writes `realized_pnl` to the position row but never touches the user's `guided_account_starting_balance`. The dashboard reads `guided_account_starting_balance` as the canonical balance (it's what `buildDemoAccountData` returns as `balance`). So wins/losses never propagate to the displayed balance.

**The fix — atomically add `realizedPnl` to `guided_account_starting_balance` after marking the position closed:**

```ts
// In closeDemoPosition, AFTER the position update succeeds:
const { data: balRow } = await svc
    .from('user_accounts')
    .select('guided_account_starting_balance')
    .eq('id', userId)
    .maybeSingle();
if (balRow) {
    const current = Number(balRow.guided_account_starting_balance ?? 0);
    const newBalance = Number((current + realizedPnl).toFixed(2));
    await svc
        .from('user_accounts')
        .update({ guided_account_starting_balance: newBalance })
        .eq('id', userId);
}
```

**Why not atomic SQL?** I used read-then-write for simplicity. For the
demo account system, race conditions between two concurrent closes
are vanishingly unlikely (a user can't close two positions in the
same JS tick). If you ever need stricter consistency, do this with an
RPC that runs `guided_account_starting_balance = guided_account_starting_balance + realizedPnl`
in a single UPDATE statement.

**The class-level rule:** any time you write `realized_pnl` to a
position row, also write the same delta to the user's balance field
in the same transaction. Otherwise the win/loss is invisible. This
applies to ANY simulator or paper-trading system where the user's
balance needs to track their cumulative wins/losses — not just
their open positions.

**Pairs with:** Recipe #55 (demo P&L entry-price drift) — that one
fixed the per-position math; this one fixes the running total.

---

## Recipe #63 — Demo SL/TP auto-close logic inside the broker poll (added Aug 30 2026)

**Symptom:** the user sets a stop-loss or take-profit on a demo
position. The price moves past the level. The position stays open
indefinitely. The user expected the position to auto-close at the
SL/TP price (the way real the broker does via working orders).

**Root cause:** the demo simulator computes live P&L every poll but
never checked whether the live price had crossed the user's SL/TP
levels. Positions only closed when the user clicked the Close
button.

**The fix — add SL/TP detection inside `buildDemoAccountData` (which
runs on every broker poll, ~30s):**

```ts
const positionsToAutoClose: { pos, closePrice, reason: 'SL' | 'TP' }[] = [];

const enrichedPositions = positions.map((p) => {
    // ... existing P&L computation ...
    
    const sl = Number(p.stop_loss ?? 0);
    const tp = Number(p.take_profit ?? 0);
    if (sl > 0 || tp > 0) {
        let slHit = false, tpHit = false;
        if (side === 'BUY') {
            slHit = sl > 0 && livePrice <= sl;
            tpHit = tp > 0 && livePrice >= tp;
        } else {
            slHit = sl > 0 && livePrice >= sl;
            tpHit = tp > 0 && livePrice <= tp;
        }
        if (slHit) positionsToAutoClose.push({ pos: p, closePrice: sl, reason: 'SL' });
        else if (tpHit) positionsToAutoClose.push({ pos: p, closePrice: tp, reason: 'TP' });
    }
    
    return { /* ... */ };
});

// After the .map(), process auto-closes BEFORE returning the snapshot
if (positionsToAutoClose.length > 0) {
    let totalRealizedDelta = 0;
    for (const { pos, closePrice, reason } of positionsToAutoClose) {
        // 1. Mark the position closed with realized_pnl set
        await svc.from('position_snapshot').update({
            status: 'closed',
            closed_at: new Date().toISOString(),
            current_price: Number(closePrice.toFixed(5)),
            realized_pnl: Number(realizedPnl.toFixed(2)),
            unrealized_pnl: Number(realizedPnl.toFixed(2)),
            close_reason: `${reason}_hit`,
        }).eq('broker_position_id', pos.broker_position_id).eq('user_id', userId);
        
        totalRealizedDelta += realizedPnl;
    }
    
    // 2. Update the user's starting balance with the net delta
    if (totalRealizedDelta !== 0) {
        const { data: balRow } = await svc.from('user_accounts')
            .select('guided_account_starting_balance').eq('id', userId).maybeSingle();
        if (balRow) {
            const newBalance = Number((Number(balRow.guided_account_starting_balance ?? 0) + totalRealizedDelta).toFixed(2));
            await svc.from('user_accounts')
                .update({ guided_account_starting_balance: newBalance })
                .eq('id', userId);
        }
    }
}
```

**Three important details:**

1. **Close at the SL/TP price, NOT the live price.** If BTCUSD is at $78,250 and the user's TP is $78,200, closing at $78,250 gives them 50 extra pips they didn't ask for. By closing at $78,200 (the TP level), they get exactly what they configured.
2. **Set `close_reason='SL_hit'` or `'TP_hit'`.** The trade journal can show these distinctly from user-clicked closes — useful for analytics and for the user to see which positions hit their limits vs which they closed manually.
3. **Combine all SL/TP hits in a single balance update.** If two positions both hit SL on the same poll, do one read + one write of `guided_account_starting_balance` instead of two round trips.

**Pairs with:** Recipe #62 (realized P&L tracking). Same balance update pattern; just sourced from auto-close instead of user close.

---

## Recipe #64 — "Quick Order submit doesn't work" — feedback invisibility, not a broken handler (added Aug 30 2026)

**Symptom:** the user reports "the submit order button in the quick order box isn't working." Backend testing shows `/api/broker/execute` returns 200 success, positions write to `position_snapshot`, the position appears in Live Positions within ~3s. So the API works.

**Root cause:** the success/error toast auto-cleared after 4 seconds. The user clicked submit, the trade went through, the position appeared in the table 3 seconds later, but the small toast message disappeared too quickly for the user to see. They assumed nothing happened.

**The fix — make the feedback persistent with a dismiss button:**

```tsx
// Before:
{submitMsg && (
    <div className={`qo-msg qo-msg--${submitMsg.kind}`}>
        {submitMsg.text}
    </div>
)}

// After:
{submitMsg && (
    <div className={`qo-msg qo-msg--${submitMsg.kind}`}>
        {submitMsg.text}
        <button
            type="button"
            className="qo-msg-dismiss"
            onClick={() => setSubmitMsg(null)}
            aria-label="Dismiss"
        >
            <X size={11} strokeWidth={2.4} />
        </button>
    </div>
)}

// And in the submit handler, REMOVE the auto-dismiss setTimeout:
//   setSubmitting(false);
//   // NO setTimeout(() => setSubmitMsg(null), 4000)
```

CSS upgrades:
```css
.qo-msg--ok {
    background: rgba(16, 185, 129, 0.14);   /* was 0.1 */
    border: 1px solid rgba(16, 185, 129, 0.4); /* was 0.3 */
    color: #34d399;
    font-weight: 600;
    animation: qo-msg-in 0.25s ease-out;       /* slide-in */
}
@keyframes qo-msg-in {
    from { opacity: 0; transform: translateY(-4px); }
    to { opacity: 1; transform: translateY(0); }
}
```

**The class-level rule:** any time the user reports "X doesn't work" and the backend is verifiably correct, the bug is almost always **feedback visibility**. Forms that auto-clear success/error messages after 2–4 seconds are easy to miss — the user thinks the action did nothing. Make success messages:
1. **Persistent** — only clear on next submit or explicit dismiss
2. **Animated** — slide-in/fade-in catches the eye
3. **High-contrast** — background + border + text all need to stand out against the surrounding card

This applies broadly: trade confirmations, save toasts, error alerts, "added to cart" notifications — anything where the user is waiting for confirmation of an action.

**Test strategy:** when the user says "X doesn't work" but the backend tests pass, don't debug the handler — debug the feedback. Check if the message is being shown, if it auto-clears too fast, if it's hidden behind another element, if the colors are too low contrast.

---

## Recipe #65 — Reusable trade form: extract from the chart page, share with the home page (added Aug 30 2026)

**Pattern:** when two pages (live chart, home dashboard) both need the same form (symbol picker + BUY/SELL + quantity + SL + TP + submit), don't duplicate — extract once.

```tsx
// src/components/trading/QuickOrderPanel.tsx
export default function QuickOrderPanel({
    defaultSymbol = 'XAUUSD',
    defaultQty = '0.10',
    compact = false,
}: Props) {
    const trading = useTrading();
    const submitOrderCtx = trading?.submitOrder;
    // ... state, submit handler, render ...
}
```

```tsx
// In TradingDashboardView (home page):
<QuickOrderPanel />

// In TradingTerminal (chart page):
<QuickOrderPanel compact />
```

**Why this matters more than "DRY":**

- **Consistent UX**: the user gets the same form on every page that shows prices. They learn it once.
- **Bug fixes land in one place**: when the symbol picker needed search removed + live price added, both pages got the fix automatically.
- **Single source of truth for state shape**: the form's submit handler uses the same `submitOrder` from the TradingContext. No risk of two forms drifting in field names.

**The compact variant** is a CSS class (`qo-card--compact`) that reduces padding + font sizes for embedding in narrower sidebars. Same component, just tighter spacing.

**Pairs with:** the account-source-store concept (where to put shared state when two pages need to switch between real/demo accounts). QuickOrderPanel reads from `useTrading()` which is the same context both pages already use — no new state plumbing required.

---

## Recipe #66 — Infinite scroll via IntersectionObserver sentinel (added Aug 30 2026)

**Pattern:** when a list might have many items (live positions, trade history), show N items initially (e.g. 3), and grow the list by N each time the user scrolls near the bottom.

```tsx
const PAGE_SIZE = 3;
const [visible, setVisible] = useState(PAGE_SIZE);
const sentinelRef = useRef<HTMLDivElement | null>(null);

useEffect(() => {
    const sentinel = sentinelRef.current;
    if (!sentinel) return;
    const observer = new IntersectionObserver((entries) => {
        const [entry] = entries;
        if (entry.isIntersecting) setVisible(v => v + PAGE_SIZE);
    }, { rootMargin: '120px' });
    observer.observe(sentinel);
    return () => observer.disconnect();
}, [list.length, activeSection]);

// Reset if list shrinks (e.g. user closed a position)
useEffect(() => {
    setVisible(prev => prev > list.length && list.length > 0
        ? Math.min(prev, list.length) : prev);
}, [list.length]);

return (
    <div className="list">
        {list.slice(0, visible).map(item => <Row key={item.id} {...item} />)}
        {list.length > visible && (
            <div ref={sentinelRef} className="infinite-scroll-sentinel">
                <Loader2 size={16} className="spin" />
            </div>
        )}
    </div>
);
```

**Why IntersectionObserver instead of scroll listeners:**

- **No scroll event spam** — scroll events fire 60+ times/second during scroll. IntersectionObserver fires only when the sentinel enters/exits the viewport.
- **Predictable trigger point** — `rootMargin: '120px'` triggers 120px before the sentinel is visible, so the user doesn't see the loader.
- **Auto-cleanup** — when `list.length` changes and the sentinel unmounts, the observer disconnects automatically.

**The reset effect** is the key that makes infinite scroll feel stable: when the user closes a position while scrolled deep in the live list, the visible count must shrink to fit the new total. Without this, the page would show an empty list while the user thinks "where did everything go?"

**Pairs with:** mobile layout (Recipe #57) — infinite scroll is most valuable on mobile where rendering all items at once would scroll forever.

---

## Cross-cutting patterns from this session

### A. "Persona-free" demo accounts: ask before adding complexity

The user's first ask was "create demo accounts" with 6 personas × 5 tiers = 30 combinations. I built the persona system. Then they said:

> "No, the user does not pick a persona. It is choose the balance of the amount they want to use for their demo camera. You can remove the whole persona thing. It's not necessary here."

**The lesson:** when the user asks for "demo accounts," the simplest valid answer is **"pick a balance, get a synthetic account"** — not "pick a persona, then pick a balance tier." Personas add visual complexity without behavioral value for a simulator. Ask "is this the right shape?" before building.

### B. i18n exists but nothing wires it up

Earlier sessions documented this for the **plumbed vs wired** distinction (Recipe #56). This session confirmed it again: 13 translation JSONs sat unused, only `LanguageSettings` and `LanguageSwitcher` called `setLanguage`. The user picked Spanish and saw no UI change.

**The fix pattern:** when wiring i18n, work in priority order:

1. Settings page (where the language picker lives) — high impact, small surface
2. The component the user explicitly complained about (here: Settings + Demo Account section)
3. Common strings (`common.*`) — used across many components
4. Section-specific keys as you touch each section

Don't try to translate everything at once. Each component you touch becomes an opportunity to add 1–3 strings.

### C. "Build once, use twice" for trade forms vs inline duplication

The chart page already had an inline Quick Order form (lines 642–696 of TradingTerminal.tsx). When the user asked for the same form on the home page, the choice was:

1. **Duplicate the form** in TradingDashboardView — fastest, but two sources of truth for the same UX
2. **Extract to a shared component** — slight up-front cost, single source of truth

I chose option 2. The chart page's inline form is still there for now (the user's swap to use the shared component is a future cleanup). But the principle: **the first time you copy a form between two places, extract it.** Don't wait for the third copy — by then you've shipped three slightly-different bugs.

### D. Playwright auth testing limitations in this codebase

Three Playwright tests failed against `www.yourdomain.com` even after I confirmed the backend was correct. Every failure showed:

- `Multiple GoTrueClient instances detected`
- `Acquiring exclusive Navigator LockManager lock "lock:sb-<project-ref>-auth-token" timed out`
- `Failed to load resource: 401`

**The cause:** Supabase's `auth.getSession()` uses `navigator.locks` to serialize concurrent reads. Playwright's headless browser shares a lock context across multiple `addInitScript` and `storageState` injections, which causes lock contention that silently returns no session.

**The implication for testing:** Playwright is unreliable for verifying user-facing behavior in this app. Use:

1. **Direct API calls** (`fetch` with the user's bearer token) to confirm backend behavior
2. **Manual browser testing** for UI verification
3. **Stub the auth flow** if Playwright tests are mandatory (set localStorage, disable SSE, etc.)

This was already partially documented in `this skill` Recipe #34 (`useUser() loading=false race + lockManager contention compound`). This session re-confirmed it with `getSession()` specifically.

---

## Files touched this session

| File | Purpose |
|---|---|
| `src/app/api/_demo-account.ts` | NEW: shared `buildDemoAccountData` used by 3 endpoints |
| `src/app/api/broker/account/route.ts` | Demo intercept added |
| `src/app/api/broker/account-data/route.ts` | Local function removed, uses shared helper |
| `src/app/api/realtime/poll/route.ts` | Demo intercept added + extended SELECT |
| `src/app/api/broker/position/[id]/route.ts` | Realized P&L → starting balance on close; auto-close SL/TP via shared helper |
| `src/components/trading/QuickOrderPanel.tsx` | NEW: reusable Quick Order with symbol dropdown + live price |
| `src/components/trading/QuickOrderPanel.css` | Glassmorphic card styles |
| `src/components/trading/TradingDashboardView.tsx` | Removed Copy Trade button; infinite scroll; MT5→"trading account"; QuickOrderPanel embed |
| `src/components/trading/TradingDashboardView.css` | Infinite scroll sentinel styles |
| `src/components/trading/TradingTerminal.tsx` | Live price polling tightened to 3s in demo mode |
| `src/components/trading/AccountConnectionModal.tsx` | Demo account entry (carried over from prior commit) |
| `src/i18n/translations/en.json` + `es.json` | Added `settings.*` + `demoAccounts.*` keys |
| `src/app/dashboard/(main)/trading/settings/page.tsx` | Wired `useLanguage()` + `t()` for tab labels, section titles, demo section |
| `src/components/settings/DemoAccountSection.tsx` | Same — wired translations |
| `src/app/dashboard/(main)/trading/demo-accounts/page.tsx` | Same |
| `src/lib/trading/demo-accounts.ts` | Removed personas, persona-free balance tier catalog |
| `src/lib/trading/account-source-store.ts` | Real ↔ Demo account source toggle (carried) |

---

## Pairs with

- `this skill` Recipe #55 (demo entry-price drift) — Recipe #61 fixes the post-close freeze that resulted
- `this skill` Recipe #62 (realized P&L balance tracking) — Recipe #63 extends this with auto-close
- `this skill` Recipe #56 (i18n wiring vs plumbing) — confirmed again in this session with Spanish on Settings
- `this skill` Recipe #57 (mobile-only layout with mutually-exclusive right-rail content) — calendar/monthly-breakdown reorder
- `this skill` Recipe #54 (TradingTerminal p.pnl.toFixed crash) — Recipe #61's response-shape drift fix
- `nextjs-pwa` skill — Playwright auth testing limitations (Cross-cutting D)
- `user/user-interaction-standards` — feedback visibility (Recipe #64)