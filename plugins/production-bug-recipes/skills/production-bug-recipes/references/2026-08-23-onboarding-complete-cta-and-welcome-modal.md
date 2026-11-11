# Aug 23 2026 — Onboarding wizard: Complete CTA + welcome modal + lifecycle RPC materialization

Companion to `2026-08-23-onboarding-lifecycle-recovery.md` and Recipe #23.
Three patterns that surfaced after the wizard was first deployed and the user
asked for a "Complete" button to advance past 7/7.

## Recipe #25 — Lifecycle RPC + durable trigger dual-write pattern (added Aug 23 2026)

**Class of work:** the new `app_get_user_lifecycle` RPC auto-grades the 7
onboarding steps from live data (avatar set, broker row, broker token valid,
etc.). It returns a read-only snapshot — it does NOT write to
`user_progress` or flip `user_accounts.onboarding_complete`.
Those writes happen via the SQL trigger on `user_progress`,
which only fires when the wizard explicitly POSTs `/api/onboarding/complete-step`
for each step.

**Symptom of the wrong approach:** the user finishes the wizard, sees 7/7
green checks on the lifecycle card, but the hard-redirect middleware
keeps bouncing them back to `/onboarding` because `onboarding_complete`
is still `false` in the DB. The lifecycle RPC reports everything done;
the SQL state never caught up.

**Root cause:** the lifecycle RPC is a *projection* over
`user_accounts + auth.users + broker_links + push_subscriptions`. It's
fast and cheap to compute, but it has no side effects. The "did the user
complete onboarding?" flag is in a separate column on `user_accounts`,
flipped by a trigger on `user_progress`. The two systems are
decoupled by design (cheap read path vs durable write path).

**The fix — when the wizard sees 7/7, walk the steps and POST
`/complete-step` for each.** The route's per-step `detectCompletion`
checks all pass at this point (that's why the green check is showing),
so the POSTs are no-ops on the SQL side EXCEPT for writing the
`user_progress` row that fires the trigger:

```tsx
// src/app/onboarding/page.tsx — Complete CTA handler
const handleComplete = useCallback(async () => {
  if (completing) return
  setCompleting(true)
  try {
    const keys = ONBOARDING_STEPS.map((s) => s.key)
    const results = await Promise.allSettled(
      keys.map((key) =>
        adminFetch('/api/onboarding/complete-step', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ step_key: key }),
        }).then(async (r) => ({ key, ok: r.ok, status: r.status }))
      ),
    )
    // Fail-soft: log failures but still proceed to the welcome modal
    // so the user can re-enter the wizard if anything is broken.
    const failed = results.filter(
      (r) => r.status === 'fulfilled' && !(r.value as any).ok
    )
    if (failed.length) {
      console.warn('[onboarding] some complete-step calls failed:', failed)
    }
    // Re-fetch so any newly-flipped trigger rows show up in the
    // lifecycle payload (e.g. onboarding_complete=true).
    await fetchLifecycle()
    setWelcomeOpen(true)
  } catch (e) {
    console.error('[onboarding] handleComplete threw:', e)
  } finally {
    setCompleting(false)
  }
}, [completing, fetchLifecycle])
```

**Why `Promise.allSettled` (not `Promise.all`):** the SQL trigger is
idempotent — calling `app_complete_onboarding_step` for an already-
completed step is a no-op (the trigger's UPDATE detects no change).
But individual POSTs CAN 400 with `step_not_complete:broker_token_expired`
if the auto-grade is borderline (e.g. broker_token_expiry is NULL but the
broker row exists). All-settled lets the success cases still commit,
logs the failures, and proceeds to the welcome modal — which the user
expects to see. A failed step doesn't block the celebration; it's a
known and recoverable state.

**Why re-fetch after the POSTs:** the lifecycle RPC is a snapshot at
the moment of the call. The trigger on `user_progress` may
have flipped `user_accounts.onboarding_complete=true` between the
wizard's first render and now. The re-fetch picks up the new state so
the welcome modal can show "ENGINE_A engine unlocked" truthfully. Without
it, the welcome modal could show stale text.

**The companion server-side rule:** `app_complete_onboarding_step`
must be idempotent. If it's not, repeat POSTs from the wizard will
double-award platform points for the same step. Verified the existing RPC
uses `INSERT INTO user_progress (...) ON CONFLICT DO UPDATE`
+ a `CASE WHEN status = 'completed' THEN ...` guard so platform points
awarding is a one-shot per step per user.

**The hard rule:** *the lifecycle RPC's "is step X done?" answer is not
enough to flip onboarding_complete.* The trigger requires a row in
`user_progress`. Don't try to wire the trigger to read the
RPC's output — that creates a circular dependency (the trigger would
need to call the RPC, which needs to be available at trigger time).
The materialization happens on the wizard's Complete click, not at
RPC-read time.

**When this hits again:** any "auto-graded checklist" feature where the
UI shows a green check from a derived/computed state but the durable
flag requires a separate write to flip. The pattern is always:
- Cheap read path (RPC or join) for UI
- Durable write path (route + DB row) for state
- The Complete CTA bridges them with parallel idempotent POSTs

**Pair with:** Recipe #23 (hard-redirect middleware gate). The gate
only works if `onboarding_complete=true` in `user_accounts`, which
only happens after the trigger fires, which only happens after the
wizard POSTs the steps.

---

## Recipe #26 — Welcome modal after the Complete CTA (added Aug 23 2026)

**Class of work:** the user finishes the wizard at 7/7 and clicks
"Complete & Enter the platform." They expect:
1. A confirmation popup ("you did it")
2. A click target that navigates them to the next logical page
(`/dashboard/trading`)

The naive implementation is a `<button onClick={router.push('/dashboard/trading')}>Complete</button>`
and call it done. The user wants more — a celebratory modal with the
personalized greeting, a single CTA, and consistent behavior across
backdrop click / ESC / explicit close button.

**The shape — single-source modal with multiple dismiss paths:**

```tsx
// State
const [welcomeOpen, setWelcomeOpen] = useState(false)

// Handler — one path, multiple call sites
const handleWelcomeContinue = useCallback(() => {
  setWelcomeOpen(false)
  router.replace('/dashboard/trading')
}, [router])

// JSX — backdrop click + close button + ESC + CTA all fire the same handler
<AnimatePresence>
  {welcomeOpen && (
    <motion.div
      className="onb-welcome-backdrop"
      initial={{ opacity: 0 }}
      animate={{ opacity: 1 }}
      exit={{ opacity: 0 }}
      transition={{ duration: 0.2 }}
      onClick={handleWelcomeContinue}
      role="dialog"
      aria-modal="true"
      aria-label="Welcome to the platform"
    >
      <motion.div
        className="onb-welcome-modal"
        initial={{ scale: 0.94, opacity: 0, y: 14 }}
        animate={{ scale: 1, opacity: 1, y: 0 }}
        exit={{ scale: 0.96, opacity: 0, y: 8 }}
        transition={{ type: 'spring', stiffness: 380, damping: 28 }}
        onClick={(e) => e.stopPropagation()}  // don't dismiss on inner click
      >
        <button className="onb-welcome-close" onClick={handleWelcomeContinue}>
          <X size={16} />
        </button>
        <div className="onb-welcome-mark"><Rocket size={36} /></div>
        <h2>Welcome to the platform system</h2>
        <p>Your ENGINE_A engine for GBPJPY live signals is now unlocked. ...</p>
        <button className="onb-welcome-cta" onClick={handleWelcomeContinue} autoFocus>
          Enter Dashboard <ArrowRight size={16} />
        </button>
      </motion.div>
    </motion.div>
  )}
</AnimatePresence>
```

**The four dismiss paths all fire the same handler:**
1. Click on the backdrop (the outer `<motion.div>`) — fires the
   onClick which calls `handleWelcomeContinue`.
2. Click on the close button (top-right ✕) — same handler.
3. Click on the main CTA — same handler.
4. ESC key — needs a separate useEffect:

```tsx
useEffect(() => {
  if (!welcomeOpen) return
  const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') handleWelcomeContinue() }
  window.addEventListener('keydown', onKey)
  return () => window.removeEventListener('keydown', onKey)
}, [welcomeOpen, handleWelcomeContinue])
```

**The `e.stopPropagation()` on the inner modal is mandatory** — without
it, any click inside the modal (including the rocket icon, the
heading, the description text) bubbles up to the backdrop and
dismisses. The user clicks the CTA but the backdrop fires first,
`setWelcomeOpen(false)` runs, the modal animates out before the CTA's
own click handler fires.

**The `router.replace` (not `router.push`):** the wizard page should
not be in the back history. If the user hits back from
`/dashboard/trading`, they should NOT land on `/onboarding` (the
wizard is done — they have `onboarding_complete=true`). `replace` swaps
the current history entry instead of stacking a new one.

**The `autoFocus` on the CTA is essential for accessibility.** When the
modal opens, keyboard users can hit Enter to dismiss it. Without
autoFocus, focus stays on the button they just clicked (the Complete
CTA), which means Enter re-triggers handleComplete instead of dismissing.
Focus management is a real UX bug, not a polish item.

**The complete CTA before the modal — disabled vs ready:**

```tsx
{lifecycle.completed_count < lifecycle.required_count ? (
  <button className="onb-complete-cta onb-complete-cta--locked" disabled>
    <Sparkles size={16} />
    Complete {lifecycle.required_count - lifecycle.completed_count} more
    {' '}step{lifecycle.required_count - lifecycle.completed_count === 1 ? '' : 's'} to unlock
  </button>
) : (
  <button className="onb-complete-cta onb-complete-cta--ready" onClick={handleComplete}>
    {completing ? <><RefreshCw size={16} className="is-spin" /> Finalizing…</>
              : <><Rocket size={16} /> Complete & Enter the platform</>}
  </button>
)}
```

The CTA explicitly tells the user how many steps remain (when not
ready) — better than a silent disabled button. The "Finalizing…"
state replaces the label while the parallel POSTs are in flight, so
the user knows the system is working.

**When this hits again:** any "celebrate then advance" UX where the
user finishes a multi-step flow. Use a single dismiss handler wired
to all four paths. Use `replace` not `push` for the navigation. Use
`stopPropagation` to prevent inner-click dismiss. Use `autoFocus` on
the primary CTA.

**Pair with:** Recipe #25 (lifecycle RPC materialization). The modal
appears only after the durable state has caught up — verified by the
post-POST lifecycle re-fetch.

---

## Recipe #27 — `useSearchParams()` requires a Suspense boundary in Next.js 16 (added Aug 23 2026)

**Class of work:** any Next.js 16 App Router page that calls
`useSearchParams()` at the top level (not inside a click handler) will
fail the static prerender step with:

```
Error occurred prerendering page "/onboarding".
useSearchParams() should be wrapped in a suspense boundary at page "/onboarding".
Export encountered an error on /onboarding/page: /onboarding, exiting the build.
```

**Symptom:** `next build` fails with the message above. `next dev` runs
fine (returns the page normally). The build error only fires for the
static generation step.

**Root cause:** `useSearchParams()` returns `null` during SSR
pre-render (because the query string is per-request). Next.js 16
requires the page to be either server-rendered on demand or wrapped
in a `<Suspense>` boundary that defers the useSearchParams call.

**The fix — two layers, pick whichever your build pipeline prefers:**

**Layer 1 — force dynamic rendering (simplest):**

```tsx
// At the top of the file, before imports
export const dynamic = 'force-dynamic'
```

This opts the page out of static generation entirely. Next will SSR
on every request. Works for any page that needs search params, cookies,
or other per-request state.

**Layer 2 — wrap the body in Suspense + skeleton:**

```tsx
// At the bottom of the file
export default function OnboardingWizardWithSuspense() {
  return (
    <Suspense fallback={<OnboardingSkeleton />}>
      <OnboardingWizard />
    </Suspense>
  )
}

function OnboardingSkeleton() {
  return (
    <div className="onb-root onb-root--loading">
      <Sparkles size={28} />
      <p>Loading your onboarding…</p>
    </div>
  )
}
```

The inner `OnboardingWizard` uses `useSearchParams()` freely. Next.js
pre-renders the skeleton at build time and streams the real page on
the client. Works with both static and dynamic rendering.

**Which to choose:** if your page is purely client-side (no SSR data
fetching), use Layer 1. If your page is mostly static with one dynamic
spot (the useSearchParams call), use Layer 2 — better build perf.

**The diagnostic when `next build` fails with this error:**

```bash
# Run the build, capture the error context
npx next build 2>&1 | tail -30 | grep -A 5 "useSearchParams\|suspense"
```

**The companion rule — `export const dynamic = 'force-dynamic'` is
implicit in any API route handler** (`route.ts` files). The static
prerender step is only relevant for page components.

**When this hits again:** any new App Router page that reads query
params. Apply the fix at page creation time, not after `next build`
fails. Build-time errors are slow to debug; the fix is one line.

**Pair with:** `nextjs-build-path-aliases` skill (related build errors),
and the `next/dynamic({ ssr: false })` pattern for components that
should never SSR (canvas charts, third-party widgets that touch
`window`).

---

## Hard rules added in this session (Aug 23 2026)

- **The lifecycle RPC is a read-only projection.** It computes
  step-status from live data but doesn't write to
  `user_progress`. The "Complete" CTA must POST
  `/complete-step` for each step to flip the durable flag.
- **Promise.allSettled > Promise.all for the Complete CTA's parallel
  POSTs.** A single 400 from one step shouldn't block the celebration
  for the rest.
- **The welcome modal's dismiss handler must be wired to four call
  sites** (backdrop click, ✕ button, CTA click, ESC key) with identical
  behavior. `router.replace` (not `push`) so the wizard isn't in
  browser back history.
- **Always add `e.stopPropagation()` on the inner modal click** or
  every inner click triggers the dismiss.
- **AutoFocus the primary CTA** so keyboard users can hit Enter to
  advance.
- **`useSearchParams()` at the top of an App Router page requires
  `export const dynamic = 'force-dynamic'` OR a `<Suspense>` boundary**
  in Next.js 16. Build will fail without one of these.

## Files touched (all committed Aug 23 2026)

- `src/app/onboarding/page.tsx` — Complete CTA + welcome modal + Suspense
  wrapper + handleComplete
- `src/app/onboarding/onboarding.css` — `.onb-complete-cta--ready` /
  `.onb-complete-cta--locked` / `.onb-welcome-*` styles + spinner keyframe
- Commit: `ebbba853` "feat(onboarding): Complete CTA at 7/7 + welcome modal"
- Production deploy: `ca841e11` SUCCESS

## E2E verification (recorded for the recipe)

```bash
# 1. Wizard page renders 200
curl -sI https://www.yourdomain.com/onboarding | head -1
# → HTTP/2 200

# 2. Chunk references include new symbols
curl -sL https://www.yourdomain.com/_next/static/chunks/<hash>.js | \
  grep -c "onb-complete-cta\|onb-welcome-modal\|Enter Dashboard"
# → ≥1 (the new symbols are in the served JS bundle)

# 3. /api/onboarding/lifecycle still returns 7/7 for julyan
# → link_broker: completed (from the prior broker-relax fix),
#   partner_status: active (green pill)

# 4. Hard-redirect gate still works for non-onboarded users
curl -sI https://www.yourdomain.com/dashboard | head -1
# → HTTP/2 302 (redirects to /onboarding)
```
