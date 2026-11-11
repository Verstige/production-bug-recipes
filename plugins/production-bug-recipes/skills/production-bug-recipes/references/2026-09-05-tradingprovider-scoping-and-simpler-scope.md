# 2026-09-05 — TradingProvider scoping crash + the "are we getting ahead of ourselves" workflow correction

## What broke
The settings `Trading Accounts` card had broken `<a href>` links that jumped the user to the KYC onboarding wizard.  I shipped a refactor (`2abfc0fd`) that:
1. Created a global `AccountConnectContext`
2. Rendered the modal once at the root layout via `<AccountConnectionModalRoot />`
3. Added `openAccountConnect(opts)` to the settings card so it could open the modal from there

**It crashed at runtime:** "Application error: a client-side exception has occurred while loading www.yourdomain.com" — the moment the user clicked `+ white-label broker` or `+ CFD broker` in settings.

## Root cause (one-line answer)
`useTrading()` inside `AccountConnectionModal` was reaching for `TradingContext`, but `TradingProvider` is only mounted inside the **dashboard segment layout** (`src/app/dashboard/(main)/layout.tsx`) — NOT the root layout. Settings is outside that segment, so opening the modal from settings = no `TradingProvider` = `useTrading()` throws = React error boundary trips.

I should have checked provider scoping before pushing. I didn't. The user came back with: *"when I press the + whitelabel or CFD broker button I get this error code"*, then the trade-off prompt: *"what if we just add a small disconnect button on the balance card? Would that be easier?"*

## The lesson (operational)

**Before moving any global state or rendering any component at the root layout, trace every Provider it depends on and confirm that Provider is also mounted at the root — or at a level that wraps both the dashboard segment AND every other surface that will render the component.**

Concrete pre-flight check:
```bash
# 1. Find every Provider in the project
grep -rn "Provider>" src/ | grep -v node_modules

# 2. For each candidate global component (e.g. <ModalRoot/>), list the hooks/state it consumes:
grep -rn "use\(Trading\|User\|Language\|Account\)" src/components/<candidate>

# 3. For each hook called, find which Provider supplies it and trace WHICH layouts wrap:
grep -l "use\(Trading\|User\|Language\|Account\)" src/ -r | while read f; do
  # Find what <ComponentContext.Provider> wraps it
  echo "$f:"
  grep -A2 "Provider>" "$f" | head -5
done

# 4. Confirm the Provider chain is unbroken from root → candidate render point.
#    If ANY Provider is dashboard-segment-scoped (e.g. under src/app/dashboard/(main)/layout.tsx),
#    the candidate can ONLY render from inside that segment.
```

If you find a Provider that's segment-scoped (TradingProvider is), don't try to make a sibling component global — either (a) accept the segment scope, (b) rewrite the consuming component to drop the segment-scoped hook, or (c) lift the Provider to root and audit every consumer for cascading effects. Each of these takes 30min–2h. Pick the cheapest; don't push without checking.

## The simpler-scope pattern that actually shipped
After reverting the global modal, I added a small **Disconnect button inline with the "Connected" / "Demo Active" pill on the home balance card**:

```tsx
{brokerConnected && (
    <div className="account-connected-status">
        <span className="account-connected-dot" />
        <span className="account-connected-label">
            {(brokerData as any)?.demo ? 'Demo Active' : 'Connected'}
        </span>
        <button
            type="button"
            className="account-disconnect-btn"
            onClick={disconnectBroker}
            aria-label="Disconnect account"
        >
            <LogOut size={11} /> Disconnect
        </button>
    </div>
)}
```

CSS that goes with it (`TradingDashboardView.css`):
```css
.account-disconnect-btn {
    margin-left: 6px;
    display: inline-flex; align-items: center; gap: 4px;
    padding: 3px 8px; border-radius: 6px;
    border: 1px solid rgba(255, 255, 255, 0.1);
    background: rgba(255, 255, 255, 0.04);
    color: rgba(255, 255, 255, 0.55);
    /* etc */
}
.account-disconnect-btn:hover {
    background: rgba(239, 68, 68, 0.12);     /* red on hover */
    border-color: rgba(239, 68, 68, 0.45);
    color: rgba(239, 68, 68, 0.95);
}
```

Same `disconnectBroker` handler that the Settings page uses.  Zero provider scoping concerns (it lives on the home balance card, inside the TradingProvider).  12 lines of JSX + 30 lines of CSS.  Done in one commit (`a2347cee`).

## The settings card after the rollback
The `+ white-label broker / + CFD broker / + Broker Direct` buttons in the settings card were also reverted from the broken modal triggers back to plain navigation links:

```tsx
<a href="/dashboard/trading?connect=broker">the broker Direct</a>
<a href="/dashboard/trading?connect=cfd_broker">the CFD broker</a>
<a href="/dashboard/trading?connect=whitelabel">the white-label broker</a>
```

User clicks → navigates to `/dashboard/trading` → home balance card's Connect button opens the modal that already works.  Settings card stays a list + switcher only.  Connection happens on the home balance card where it always has.

The `?connect=` query param is currently ignored by the modal — the modal opens with the broker chooser.  To make the param actually pre-select a broker (white-label broker / CFD broker / Broker Direct), that's a small follow-up that only needs a `useSearchParams()` read at the top of `TradingDashboardView`.  Deferred — out of scope for the simpler-scope fix.

## Workflow correction: "are we getting ahead of ourselves?"

User said:
> *"Or maybe we are getting ahead of ourselves, what if we just add a small disconnect button on the balance card? Would that be easier?"*

This is the second-class signal I missed: **the user is giving permission to scope down**.  Their mental model is "Disconnected = bad state I want to fix now" — and a single button on the balance card solves that.  The full "make modal openable from anywhere" refactor is a larger fix that solves a *different* (still real) problem.  I mixed them.

**The correct read:**
- Disconnect button on balance card → 30min, ships immediately, no scoping drama
- Modal-from-settings → needs provider refactor → 2-4h plus audit, deferred

Ship the smaller one. Note the bigger one. Move on.

## Pattern: when the user asks for the simple version
If the user proposes a simpler approach AND your current solution is more complex, **adopt the simpler one unless you have a strong reason otherwise.**  Reasons to overrule: prevents user-stated regression, would re-create a known bug.  Neither applied here.  Adopt.
