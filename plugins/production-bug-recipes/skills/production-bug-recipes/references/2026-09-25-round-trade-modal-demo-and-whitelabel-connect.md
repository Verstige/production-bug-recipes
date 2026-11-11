# 2026-09-25 — Sep 25-27 round: connect flow, modal cleanup, demo, layout, contract sizes

Twelve commits shipped between Sep 25 and Sep 27 covering the white-label broker connect
flow, the AccountConnectionModal chooser, the balance card empty state, demo
account cleanup, contract-size math, and a CSS layout fix. The recipes below
are the **class-level lessons** — the kind that future sessions will hit
without context if not captured.

## Recipe #76 — `disconnectBroker` silent bail because of dead `v2_user_id` localStorage

**Symptom:** User clicks "Disconnect Account" in the Trading Accounts card.
The confirm dialog appears, the user confirms, the page reloads, the UI
looks disconnected — but the DB row is unchanged. Reconnect attempts
land on the same stale white-label broker session and fail with a confusing flow.

**Root cause:** `disconnectBroker()` in `src/context/TradingContext.tsx`
read the user id from `localStorage.getItem('v2_user_id')` and returned
silently when it was null. `v2_user_id` is dead code from the pre-Supabase
custom-auth era and has **never been set anywhere** in the codebase.
`grep -rn "v2_user_id" src --include='*.ts' --include='*.tsx'` shows only
**reads**, never writes. The function bailed, the localStorage clears ran
anyway (false-positive "looks disconnected"), the fetch never fired, the
DB stayed stale.

**Fix:** `supabase.auth.getSession()` to pull the real `access_token`,
send it as a Bearer header, route resolves the user server-side via
`createServiceClient().auth.getUser(token)`. The endpoint's `getUserId()`
already supported Bearer-token resolution — only the client was stuck
on the dead localStorage pattern.

```ts
// WRONG (silent bail):
const userId = localStorage.getItem('v2_user_id');
if (!userId) return;
await fetch(`/api/broker/disconnect`, { ... body: { user_id: userId } });

// RIGHT:
const { data: sbSessionData } = await supabase.auth.getSession();
const sbToken = sbSessionData?.session?.access_token ?? '';
if (!sbToken) throw new Error('Sign in required');
const res = await fetch(`/api/broker/disconnect`, {
  method: 'POST',
  headers: { Authorization: `Bearer ${sbToken}` },
  body: JSON.stringify({}),
});
```

**Detection recipe:** if a context function silently returns early, the
first thing to check is whether it depends on `localStorage` keys that
nothing writes. `localStorage` is a code smell in a Supabase-auth era —
the auth state lives in `sb-<project>-auth-token` cookies and
`supabase.auth.getSession()`, not in hand-rolled keys.

**Surface area audit:** `src/components/trading/SwipeSignalCard.tsx:280`
also reads `v2_user_id`. Likely dead there too. Don't fix it preemptively
until something breaks.

## Recipe #77 — Login → onboarding → dashboard redirect loop: `onboarding_complete` not set on admin approval

**Symptom:** Admin approves a user's application. User logs out, logs back
in. Login page probes `/user_accounts` and sees `onboarding_complete !== true`,
so redirects to `/onboarding`. The onboarding page calls
`supabase.auth.getUser()` with a 4-second timeout. If the auth client
hiccups → bounces back to `/login`. User is stuck in a loop.

**Root cause:** The SQL trigger `app_complete_onboarding_step` is what sets
`onboarding_complete=true`. It fires when the user completes all 7 wizard
steps. But the wizard **locks at step 6** ("Submit application") until
admin approves. So for users who go through the application flow, the
trigger **never fires**. Admin approval only sets `application_status='approved'`
+ `is_active=true`, leaving `onboarding_complete=false` indefinitely.

**Fix:** The admin approval UPDATE in `/api/admin/applications/route.ts`
must set `onboarding_complete: true` explicitly. Belt-and-suspenders:
also bumped onboarding page timeout 4s → 8s with a single retry so
transient auth-client hiccups don't kick the user back to `/login`.

**Detection recipe:** when "user just logged in but landed on /onboarding
or /login unexpectedly," check whether the relevant flag on `user_accounts`
is true. The flags that need verification are `onboarding_complete`,
`application_status`, `is_active`, `onboarding_step`. Each has a different
caller that sets it — if any one of them is set in the wrong code path
(e.g. approval sets `application_status` but not `onboarding_complete`),
the user gets stuck in the wrong state.

## Recipe #78 — Modal popup auto-fired when user lands on `/dashboard/settings?connectAccount=1`

**Symptom:** User clicks "Connect Account" on the balance card → gets
redirected to settings page → AccountConnectionModal **immediately pops
up over the half-loaded settings page**. User can't tell what they
clicked; feels like a bug.

**Root cause:** The settings page had a `useEffect` that detected
`?connectAccount=1` and called `openAccountConnect()` on mount. This was
implemented as a "user-friendly shortcut" but the modal opening
immediately on landing was jarring — and worse, the back button couldn't
close it because the modal isn't in the URL stack.

**Fix:** Removed the `openAccountConnect()` call. Now the settings page
just sets `activeTab='trading'`. The Trading tab's empty state already
has explicit "Demo Account / + the white-label broker / + the CFD broker" buttons
that open the modal intentionally when clicked. **Two clicks instead of
one** but the second click is informed, not surprising.

**General pattern:** never auto-trigger a modal/popup as a side effect of
a navigation. The user's mental model is: I navigated, I'm here, I see
the page. Modal popups break that model. Let the user explicitly opt in.

## Recipe #79 — "Choose your broker v2" modal page is redundant when entry surfaces already pre-pick

**Symptom:** User clicks "+ the white-label broker" from the Trading tab empty
state. The modal opens with a chooser showing the broker / MetaTrader 5 /
DXTrade / Demo Account. The user already picked the white-label broker — why are
they being asked to choose again?

**Root cause:** `AccountConnectionContext.openAccountConnect({ initialBroker })`
was designed to take an `initialBroker` parameter that pre-selects the
broker. But the modal still rendered the chooser view when:
- The caller passed `initialBroker='demo'` (had to land on the chooser so
  the user could click "Demo Account" inside)
- The caller didn't pass `initialBroker` at all (defensive fallback)

The trading tab's empty state already passes `initialBroker='whitelabel'` /
`'cfd_broker'` / `'demo'` correctly. So the chooser was dead UX surface.

**Fix:** Always default view to `'login'`. For `initialBroker='demo'`,
auto-fire `handleConnectDemo()` in a mount-time `useEffect` (the demo
flow is one-click — no need for a form). The user sees the success state
for 1.4s then the modal closes. **Zero clicks** for the demo path.

The "Back to broker selection" / "Change broker" buttons in the modal
were repurposed to "Cancel" (close the modal) — there's no chooser to
go back to anymore. `reset()` was updated to route to `login` or `whitelabel`
based on `initialBroker` instead of always routing to the now-gone
`'broker'` view.

**General pattern:** When an entry surface pre-picks a choice, the
downstream modal/menu/wizard should **skip** the chooser step. Carrying
the chooser forward means the user is asked the same question twice.

## Recipe #80 — Device back button on mobile bypasses the modal's Escape handler

**Symptom:** Mobile users open the modal, press the device's back button
(iOS Safari swipe-back / Android Chrome system-back). Instead of
dismissing the modal, the browser does history navigation, landing the
user on whatever the prior URL was — typically the trading tab empty
state. On the trading tab that meant the user got dumped onto the
chooser (now fixed by Recipe #79). On other pages they lost their place.

**Root cause:** The modal's `useEffect` listened for `keydown` (Escape)
but not `popstate` (browser-back). On mobile, system-back fires
`popstate`, not `keydown`.

**Fix:** Push a sentinel `history.pushState({ accountConnectModal: true }, '')`
on modal open. Add a `popstate` listener that calls `onClose()` and
removes itself. In the cleanup function, if the modal is being closed
without a popstate (X-button / success / Escape), do `history.back()` to
roll the sentinel out so the URL stack stays clean. Track
`closedViaPopstate` to distinguish the two paths.

```ts
let pushedSentinel = false;
let closedViaPopstate = false;
try {
  window.history.pushState({ accountConnectModal: true }, '');
  pushedSentinel = true;
} catch { /* SSR / private mode */ }
const onPop = () => {
  closedViaPopstate = true;
  onClose();
  window.removeEventListener('popstate', onPop);
};
window.addEventListener('popstate', onPop);
return () => {
  document.body.style.overflow = prevOverflow;
  window.removeEventListener('keydown', onKey);
  window.removeEventListener('popstate', onPop);
  if (pushedSentinel && !closedViaPopstate) {
    try { window.history.back(); } catch { /* ignore */ }
  }
};
```

**Detection recipe:** if a mobile-only complaint involves "modal won't
close" / "back button does the wrong thing," the modal probably listens
for keydown but not popstate.

## Recipe #81 — Demo accounts seeded 3 fake trades; user wanted clean slate

**Symptom:** User creates a demo account → lands on the dashboard with
3 pre-seeded open positions (EURUSD BUY +X pips, XAUUSD SELL −Y pips,
NAS100 BUY +Z pips). The user did not place these trades. The synthetic
P&L drift from current prices was confusing — "is this real money?"

**Root cause:** `src/lib/trading/demo-accounts.ts:getStartingPositions()`
returned three hand-coded positions. `src/app/api/broker/connect-demo`
called `getStartingPositions()`, fetched live prices for each, and
inserted them into `position_snapshot`. The user got a "populated"
demo but couldn't tell real from synthetic.

**Fix:**
- `getStartingPositions()` returns `[]`. Function kept (used by the
  picker preview) but always returns empty.
- `connect-demo` route: removed the live-price fetch, the
  `positionRows.map()` build, and the `position_snapshot.insert`
  call. `totalEquity = tier` (was `tier + sum(position unrealized_pnl)`).
- Removed unused imports (`getDemoPrice`, `demoPipSize`, `demoPipValue`).
- `positionsInserted: 0` in the response. `metadata.starting_positions_count: 0`.
- Demo picker UI: replaced "Starting Positions" stat with "Starting Balance",
  "With Starting P&L" → "Available Equity". Feature copy updated.
  Success toast dropped the "{N} starting positions" qualifier.

**Detection recipe:** if a user complains about "fake" or "synthetic"
content showing up as if they placed it themselves, check whether the
system is seeding placeholder data on the user's first paint. The
fix is almost always: don't seed.

## Recipe #82 — Empty-state CSS cramped because `.sv-empty` was horizontal flex

**Symptom:** The Trading Accounts empty state rendered with the message
"No trading accounts connected. Pick Demo Account or the white-label broker
below to start." cramped into one row alongside the Demo/white-label broker buttons.
On mobile the text wrapped across 4 awkward italic lines next to the
buttons.

**Root cause:** `.sv-empty` was `display: flex; align-items: center; gap: 10px`
(horizontal flex) with all children forced into one row.

**Fix:** Switched to `flex-direction: column; align-items: flex-start;
gap: 12px`. Made `.sv-empty-add-row` full-width (`width: 100%;
max-width: 360px`) and its children `width: 100%; justify-content: center`
so the buttons are full-width on mobile.

**General pattern:** horizontal flex on a "message + actions" container
**always** looks cramped on mobile. Default to column-flex for any
container that holds both descriptive text and action buttons.

## Recipe #83 — the broker's server-name casing: whitelabel vs WHITELABEL

**Symptom:** User reported "users having issues connecting their white-label broker
account." Investigation showed the broker-server-name dropdown was
sending `'white-label broker'` (capital P) to the broker's `/auth/jwt/token`. The broker
is case-sensitive on the `server` field — wrong case → 401.

**Root cause:** The dropdown's options array was `['white-label broker', 'the broker-Demo']`
with the case I'd inherited. The broker's canonical broker-server-name
mapping is case-sensitive and `'whitelabel'` (lowercase) wasn't accepted.

**Fix:** Changed to `['WHITELABEL', 'CFDBROKER', 'the broker-Demo']` — all caps
matches the canonical names as the broker presents them. The user
initially asked for lowercase based on a hypothesis I couldn't verify
(the broker returns 401 for both wrong creds AND wrong case, masking
the real cause). They then asked for all-caps. Both directions had
risk; the final canonical form is uppercase.

**Detection recipe:** if a broker auth 401 is reported but the
creds are correct, the broker-server-name is the next thing to check.
Try the canonical names as the broker displays them — usually uppercase
or title-case, never lowercase. The error message "Incorrect email or
password" is the same for both wrong creds and wrong server.

## Recipe #84 — `/get-started` route deleted by mistake, restored from git history

**Symptom:** External marketing links to `/get-started` returned 404.
Internal Navbar/Footer links to `/get-started` went 404.

**Root cause:** A previous refactor (commit `8845210c`) deleted
`src/app/get-started/page.tsx` + `src/styles/pages/GetStarted.css` +
related components because they were "redundant with the new /guide
broker setup walkthrough." But `/get-started` was the **front-end
application form** for unauthenticated visitors (3 steps: Personal /
Trading / Review) — different purpose from `/guide`'s broker setup for
already-signed-in users.

**Fix:** Restored from `git checkout 8845210c^ -- src/app/get-started/page.tsx
src/styles/pages/GetStarted.css`. Also fixed an earlier typo where
`router.push('/api/get-started')` was used instead of
`router.push('/get-started')`. The route is back to the original
587-line signup wizard + 881-line CSS.

**Detection recipe:** if a marketing link returns 404, check the most
recent big refactor for routes that were in the diff. Search git log
for the route path. `git checkout <prev-commit>^ -- <file>` restores
from history. **Don't** invent a replacement — restore the original.

## Recipe #85 — Patch tool indentation mismatch on multi-line JSX comments

**Symptom:** Patches that touched JSX blocks with surrounding comments
frequently failed or applied with extra whitespace, producing syntax
errors like `Unexpected token` on lines that should be valid. TS errors
referenced line numbers that were off-by-2 or off-by-4 from the actual
problem.

**Root cause:** The patch tool requires exact whitespace match for
`old_string`. JSX blocks often have 16- or 20-space indentation. When
the patch's old_string had 20 spaces but the file had 24 (or vice
versa), the patch either failed silently or matched the wrong location.

**Fix:** Always read the file with `read_file(offset, limit)` and copy
the exact whitespace from the actual file content into the patch's
`old_string`. For large blocks, use `read_file` to capture the precise
indentation rather than guessing. When a patch fails multiple times,
re-read the file with the line numbers printed in the error to confirm
the actual whitespace.

This pattern burned roughly 6 round trips in the Sep 25-27 round —
worth flagging because it adds up fast on multi-file refactors.

## Recipe #86 — Server casing direction reversed twice — capitalize the user's correction as policy

**Symptom:** I lowercased `'white-label broker'` → `'whitelabel'` based on a hypothesis
that the broker wants lowercase. The user then corrected with "change
whitelabel to WHITELABEL all caps" — meaning they'd been right the first time
and my hypothesis was wrong.

**Root cause:** When the user reverses direction, it's often because
they have more context than I do. My instinct to verify before changing
was right; my follow-up to defend the lowercase hypothesis when the
user corrected me was wrong. I should have just changed it.

**Fix:** When the user reverses a direction, **just make the change**.
Don't re-justify the prior position. Don't ask "are you sure?" They
have more context than I do about their broker, their UI, their
preferences. The cost of asking is another round trip; the cost of
changing is one git commit.

**General pattern:** trust the user more than your hypothesis when the
two conflict, especially on details where you can't verify
independently (broker conventions, UI preferences, naming).
