# Aug 24 2026 — OnboardingHero done-box polish + Next.js route group pattern for nav scoping

Drop-in for `this skill's SKILL.md` merge.

Two independent patterns from the user's last polish pass.

---

## Recipe #41 — OnboardingHero done-box: match the in-progress layout, not a slim pill

**Symptom:** after a user completes onboarding, the OnboardingHero "done" state renders as a slim pill with a checkmark + "Onboarding complete" + "Open Trading Floor" button. The user closes the PWA, reopens it, and the done state **loses the styled-box feel** — they see a small horizontal pill that doesn't look like a completion card. They had expected the same "box" the in-progress state had (eyebrow badge, title, lede, progress bar, 7 chip strip).

**Root cause:** the original done state was a **slim pill layout** (flex row, 12px padding) while the in-progress state was a **full card layout** (flex column, 22px padding, with progress bar + chips). They used different shapes entirely. On any PWA cold-start, the user expected "the box" and got "a thin line."

```css
/* OLD — done state is a thin pill, not a box */
.onb-hero--done {
    display: flex;
    align-items: center;
    gap: 14px;
    padding: 12px 18px;          /* thin */
    background: rgba(52, 211, 153, 0.06);
    border-color: rgba(52, 211, 153, 0.28);
}
/* no progress bar, no chip strip, no scanline overlay */
```

The in-progress state had a full card:
```css
/* in-progress */
.onb-hero {
    padding: 22px 26px 24px;
    display: flex;
    flex-direction: column;
    gap: 14px;
    background: radial-gradient(...) /* big layered card */;
    border: 1px solid var(--pp-border);
    /* + .onb-hero__bar (progress) + .onb-hero__chips (chip strip) */
}
```

The user wanted the done state to **match the in-progress shape** so refresh doesn't wipe the visual identity.

**The fix — replicate the in-progress card layout for done:**

```tsx
// src/components/onboarding/OnboardingHero.tsx
if (knownOnboarded) {
    return (
        <div className="onb-hero onb-hero--done">
            {/* SAME top section as in-progress */}
            <div className="onb-hero__top">
                <div className="onb-hero__eyebrow onb-hero__eyebrow--done">
                    <Check size={14} strokeWidth={2.4} />
                    <span>Onboarding complete · 7 of 7</span>
                </div>
                <button
                    type="button"
                    className="onb-hero__cta onb-hero__cta--ghost"
                    onClick={() => router.push('/onboarding')}
                    title="Re-open the onboarding checklist any time"
                >
                    View checklist <ChevronRight size={14} />
                </button>
            </div>

            <h1 className="onb-hero__title">
                Your trading floor is open
            </h1>
            <p className="onb-hero__lede">
                You finished the 7-step setup. Trading Floor, OS Points, and all engines are unlocked. You can re-open the checklist any time below.
            </p>

            {/* SAME progress bar (now 100%) */}
            <div className="onb-hero__bar" aria-hidden>
                <div className="onb-hero__bar-fill onb-hero__bar-fill--done" style={{ width: '100%' }} />
            </div>

            {/* SAME chip strip, all with the green Check icon (no empty icons) */}
            <div className="onb-hero__chips" aria-hidden>
                {['profile_basics', 'accent_theme', 'risk_disclaimer',
                  'connect_broker', 'link_broker', 'enable_push',
                  'walkthrough'].map((key) => {
                    const cfg = STEP_LABELS[key]
                    return (
                        <div key={key} className="onb-hero__chip is-done" title={cfg?.label ?? key}>
                            <Check size={11} strokeWidth={2.4} />
                        </div>
                    )
                })}
            </div>

            {/* BOTTOM: two CTAs so the user has options */}
            <div className="onb-hero__doneactions">
                <button
                    type="button"
                    className="onb-hero__donebtn"
                    onClick={() => router.push('/dashboard/trading')}
                >
                    Open Trading Floor <ChevronRight size={14} />
                </button>
                <button
                    type="button"
                    className="onb-hero__donebtn onb-hero__donebtn--ghost"
                    onClick={() => router.push('/onboarding')}
                >
                    View checklist
                </button>
            </div>
        </div>
    )
}
```

```css
/* NEW — done mirrors in-progress */
.onb-hero--done {
    display: flex !important;
    flex-direction: column !important;
    align-items: stretch !important;
    gap: 14px;
    padding: 22px 26px 24px !important;
    background:
        radial-gradient(ellipse at top right, rgba(52, 211, 153, 0.18), transparent 60%),
        radial-gradient(ellipse at bottom left, rgba(34, 211, 238, 0.10), transparent 60%),
        linear-gradient(180deg, rgba(255, 255, 255, 0.03), rgba(255, 255, 255, 0.005)) !important;
    border: 1px solid rgba(52, 211, 153, 0.32) !important;
    position: relative;
    overflow: hidden;
}
.onb-hero--done::before {
    content: '';
    position: absolute;
    inset: 0;
    background: repeating-linear-gradient(
        90deg, rgba(255, 255, 255, 0.014) 0 1px, transparent 1px 14px
    );
    pointer-events: none;
    opacity: 0.5;
}
.onb-hero--done > * { position: relative; z-index: 1; }

.onb-hero__eyebrow--done {
    background: rgba(52, 211, 153, 0.14) !important;
    border-color: rgba(52, 211, 153, 0.40) !important;
    color: #34d399 !important;
}

.onb-hero__bar-fill--done {
    background: linear-gradient(90deg, #34d399, #10b981 60%, #059669) !important;
    box-shadow: 0 0 16px rgba(52, 211, 153, 0.6) !important;
    animation: onb-done-shimmer 3s ease-in-out infinite;
}
@keyframes onb-done-shimmer {
    0%, 100% { filter: brightness(1); }
    50%      { filter: brightness(1.15); }
}

.onb-hero__chip.is-done {
    background: linear-gradient(135deg, #34d399, #10b981) !important;
    color: #04140b !important;
    border-color: #34d399 !important;
    box-shadow: 0 0 0 3px rgba(52, 211, 153, 0.18), 0 4px 12px rgba(52, 211, 153, 0.22) !important;
}

.onb-hero__cta--ghost {
    background: rgba(255, 255, 255, 0.04) !important;
    color: rgba(255, 255, 255, 0.85) !important;
    border: 1px solid rgba(255, 255, 255, 0.12) !important;
    box-shadow: none !important;
}
.onb-hero__cta--ghost:hover {
    background: rgba(255, 255, 255, 0.08) !important;
    color: #fff !important;
    box-shadow: 0 0 0 3px rgba(255, 255, 255, 0.06) !important;
}

.onb-hero__doneactions {
    display: flex;
    align-items: center;
    gap: 10px;
    flex-wrap: wrap;
    margin-top: 4px;
}
.onb-hero__donebtn--ghost {
    background: rgba(255, 255, 255, 0.04);
    color: #fff;
    border: 1px solid rgba(255, 255, 255, 0.12);
    box-shadow: none;
}
```

**The general rule — match the in-progress layout for the done state:**

When a component has three render paths (`loading`, `in-progress`, `done`), the `done` state should reuse the same layout as `in-progress` — same outer container, same primary sections, same vertical rhythm. The differences between in-progress and done should be DATA, not STRUCTURE.

**The shape-vs-data distinction:**

| State | Shape | Data |
|---|---|---|
| In-progress | full card | 3/7, accent_theme pending, lede says "pick up where you left off" |
| Done | SAME full card | 7/7, all chips green, lede says "your trading floor is open" |

If the in-progress card is 22px padding + progress bar + chip strip + CTA, the done card is ALSO 22px padding + progress bar (100%) + chip strip (all green) + CTA. The visual language is consistent.

**The anti-pattern (what was happening before):**

```css
/* in-progress: full card */
.onb-hero { padding: 22px 26px; flex-direction: column; ... }
/* done: thin pill */
.onb-hero--done { padding: 12px 18px; flex-direction: row; ... }
```

The user expected a card and got a thin line. The fix isn't to redesign the done state — it's to make the done state **use the same shape as the in-progress state**.

**When this hits again:** any 3-state component (loading / in-progress / done) where the "done" state was styled as a compact pill. The fix is: make the done state use the same outer container + primary structure as the in-progress state. Only the data (progress percentage, chip completion, headline copy) should differ.

**The diagnostic — is the done state shape-mismatched with the in-progress state?**

```bash
# Read both CSS blocks
rg -A8 '\.onb-hero[^-]' src/components/X.css
rg -A8 '\.onb-hero--done' src/components/X.css

# Compare: do they use the same padding / flex-direction / gap?
```

If the padding is 22px for in-progress but 12px for done (or the flex-direction is column for in-progress but row for done), the user will see a jarring visual transition at completion. Fix: use the same shape, only swap the content.

**The companion rule — the page-level wizard also has a "you're all set" path:**

The user explicitly said: "after a user has completed the onboarding move the card to the get started page below the step by step dub paragraph" — meaning, once onboarding is complete, the wizard at `/onboarding` should ALSO show a "you're all set" card so the user can revisit it as a reference.

**The fix at the page level** (`src/app/onboarding/page.tsx`):

1. Remove the auto-redirect that bounced already-complete users to `/dashboard`:

```tsx
// OLD — bounces them away
useEffect(() => {
    if (lifecycle?.onboarding_complete) {
        router.replace('/dashboard')
    }
}, [lifecycle, router])

// NEW — let them view as a reference
// (the wizard renders the all-done state below)
```

2. Add an `isComplete` flag and a top-of-page banner when complete:

```tsx
const isComplete = !!lifecycle.onboarding_complete

return (
    <>
        {isComplete && (
            <div className="onb-alldone-banner">
                <div className="onb-alldone-banner-icon">
                    <Check size={22} strokeWidth={2.6} />
                </div>
                <div className="onb-alldone-banner-copy">
                    <strong>Onboarding complete</strong>
                    <span>You finished all 7 steps. Your trading floor is open. Use this page any time as a reference.</span>
                </div>
                <div className="onb-alldone-banner-actions">
                    <button onClick={() => router.push('/dashboard/trading')}>
                        Open Trading Floor
                    </button>
                    <button onClick={() => router.push('/dashboard')}>
                        Back to dashboard
                    </button>
                </div>
            </div>
        )}
        <div className="onb-root">
            <header className="onb-hero">
                <span className="onb-hero-kicker">
                    {isComplete ? 'the platform · Onboarding (reference)' : 'the platform · Onboarding'}
                </span>
                <h1>
                    {isComplete
                        ? `Your trading floor is open${userProfile?.firstName ? `, ${userProfile.firstName}` : ''}`
                        : `Welcome${userProfile?.firstName ? `, ${userProfile.firstName}` : ''}.`}
                </h1>
                ...
            </header>
            ...
        </div>
    </>
)
```

3. The bottom CTA row uses a different shape when complete:

```tsx
{isComplete ? (
    <div className="onb-complete-already-done">
        <button onClick={() => router.push('/dashboard/trading')}>
            <Rocket size={16} /> Open Trading Floor
        </button>
        <button
            className="onb-complete-cta onb-complete-cta--ghost"
            onClick={() => router.push('/dashboard')}
        >
            <ArrowLeft size={16} /> Back to dashboard
        </button>
    </div>
) : (
    // ... existing in-progress and locked CTAs
)}
```

The user can navigate from `/dashboard` (via the OnboardingHero's "View checklist" CTA) to `/onboarding` and see the all-done banner + the 7-step grid in reference mode. They can click "Open Trading Floor" or "Back to dashboard" without being forced into a state they don't need.

**The general rule — completed states should be reference-able, not hidden:**

Any wizard / multi-step flow that's "done" should be navigable in a read-only state. Don't auto-redirect completed users away. Let them see the checklist of what they did, in the order they did it, with green checkmarks. This is the difference between "the system shows you a fake onboarding prompt" and "the system is honest about where you are."

**Pair with:** Recipe #35 (OnboardingHero splash glitch). #35 fixes the loading-state claim; #41 fixes the done-state shape. Both contribute to the user's trust: "the dashboard always tells me the truth about where I am."

---

## Recipe #42 — Next.js App Router route group pattern for scoped layouts (BottomDock + MobileNavDrawer on inner pages only)

**Class of work:** the `/dashboard` home page has its own visual treatment (OnboardingHero at top, division chooser, no nav). The inner pages (`/dashboard/trading`, `/dashboard/partners`, `/dashboard/admin`, etc.) need BottomDock + MobileNavDrawer. Both the home and the inner pages live under the same `/dashboard/` path prefix. The current `<DashboardShell>` wrapper sits in `src/app/dashboard/layout.tsx` and applies to every `/dashboard/*` route.

**The problem:** if you want the home page to render WITHOUT the nav, the simplest approach (conditionally render the nav based on `usePathname()`) requires client-side checks on every render. The cleaner approach: **Next.js route groups**.

**The fix — restructure into a `(main)` route group:**

```
src/app/dashboard/
├── page.tsx                          ← /dashboard (no nav)
├── dashboard-landing.css             ← home CSS only
└── (main)/                           ← route group (parentheses, ignored in URL)
    ├── layout.tsx                    ← owns BottomDock + MobileNavDrawer
    ├── trading/page.tsx
    ├── partners/page.tsx
    ├── admin/page.tsx
    ├── customers/page.tsx
    └── ... (22 other inner subroutes)
```

The `(main)` directory is a **route group** in Next.js — the parentheses are a Next.js convention that groups routes without affecting the URL path. So `/dashboard/(main)/trading/page.tsx` is served at `/dashboard/trading` but inherits the `(main)/layout.tsx`.

**The migration recipe (filesystem restructure):**

```bash
cd ~/Projects/the platform/src/app/dashboard

# 1. Create the (main) directory
mkdir -p "(main)"

# 2. Move every inner subroute into (main) — preserve git history
for dir in account admin business calendar changelog community customers \
           education leaderboard guided_account partner-upgrade partners pending plans \
           prime profile sales services sessions tasks trading updates; do
    git mv "$dir" "(main)/$dir"
done

# 3. Move the layout that owns the nav
git mv layout.tsx "(main)/layout.tsx"

# 4. Move the shared CSS for the inner pages
git mv dashboard-styles.css "(main)/dashboard-styles.css"

# 5. Keep the home page (page.tsx) and home CSS (dashboard-landing.css) at /dashboard/
```

**The result:**

- `GET /dashboard` → renders `page.tsx` from `src/app/dashboard/page.tsx` (the home page with OnboardingHero + division chooser). Does NOT inherit `(main)/layout.tsx`. Does NOT render BottomDock / MobileNavDrawer.
- `GET /dashboard/trading` → renders `src/app/dashboard/(main)/trading/page.tsx`, inherits `(main)/layout.tsx`, renders BottomDock + MobileNavDrawer.
- `GET /dashboard/admin` → same as above. Inner-page chrome.
- `GET /dashboard/customers/[id]` → same.

**The verify step (no functional regression):**

```bash
# 1. Build is clean
npx next build 2>&1 | tail -5

# 2. /dashboard returns 200 (home)
curl -sIL https://www.yourdomain.com/dashboard | head -1
# → HTTP/2 200

# 3. /dashboard/trading returns 200 (inner)
curl -sIL https://www.yourdomain.com/dashboard/trading | head -1
# → HTTP/2 200

# 4. /dashboard/admin returns 200 (inner)
curl -sIL https://www.yourdomain.com/dashboard/admin | head -1
# → HTTP/2 200
```

**The diagnostic — was the layout correctly scoped?**

```bash
# View the rendered HTML on /dashboard
curl -sL https://www.yourdomain.com/dashboard -H 'User-Agent: Mozilla/5.0' | grep -E 'BottomDock|MobileNavDrawer|bottom-dock|mobile-nav-drawer'
# Expected: zero hits (the home page doesn't include the nav components)

# View the rendered HTML on /dashboard/trading
curl -sL https://www.yourdomain.com/dashboard/trading -H 'User-Agent: Mozilla/5.0' | grep -E 'BottomDock|MobileNavDrawer'
# Expected: hits (the inner page has the nav)
```

If `/dashboard` shows nav hits, the route group isn't working — the layout is being inherited when it shouldn't be. Check that `src/app/dashboard/page.tsx` is at the top level (not inside `(main)`).

**The general rule — use Next.js route groups to scope layouts:**

When a path prefix has multiple "flavors" (e.g. `/dashboard` home vs `/dashboard/*` inner pages), use a route group to share the path prefix while giving each flavor its own layout. The pattern:

```
section-home/                  ← the home page (e.g. /section)
section-home/(inner)/
  layout.tsx                   ← the inner-page chrome
  page-a/page.tsx              ← /section/page-a
  page-b/page.tsx              ← /section/page-b
```

This avoids conditional `usePathname()` checks and keeps each layout's scope explicit. The Next.js documentation calls these "route groups" and they're a stable feature.

**The companion rule — when the home is the only path that needs special treatment, ALSO consider moving the home into its own group:**

```
section/
  (home)/page.tsx               ← /section
  (home)/home.css
  (inner)/layout.tsx
  (inner)/page-a/page.tsx       ← /section/page-a
```

Both `section/(home)/page.tsx` and `section/(inner)/page-a/page.tsx` work, with `(home)` getting the "no nav" treatment and `(inner)` getting the nav. The URLs are still `/section` and `/section/page-a`.

**The anti-pattern — `usePathname()` checks in the layout:**

```tsx
// ❌ WRONG — client-side check in the parent layout
function DashboardLayout({ children }) {
    const pathname = usePathname()
    return (
        <DashboardGuard>
            <OnboardingGateRedirect />
            <TradingProvider>
                <PointsPopupProvider>
                    <MobileKeyboardHandler />
                    <div className="dashboard-container">
                        {pathname === '/dashboard' ? null : <MobileNavDrawer />}
                        ...
                        {pathname === '/dashboard' ? null : <BottomDock />}
                    </div>
                </PointsPopupProvider>
            </TradingProvider>
        </DashboardGuard>
    )
}
```

This works but is fragile: every page in the app gets a conditional render, the layout file is harder to read, and the test surface is "is the conditional correct for every route?" Route groups are explicit and the layout scope is visible in the filesystem.

**When this hits again:** any path prefix where one route has a different chrome than its siblings. Pattern:
1. Identify the path prefix
2. Identify which child(ren) have different chrome
3. Move those into a `(special)/` route group with its own `layout.tsx`
4. Update imports + verify build

**The trade-off — extra directory nesting vs. runtime conditional checks:**

Route groups add one level of directory nesting. Conditional checks add logic to every render. For a small site with one home + 2 inner pages, either is fine. For a 20+ page inner section, route groups scale better because adding a new inner page requires no layout changes.

**Pair with:** the Next.js docs on route groups: https://nextjs.org/docs/app/building-your-application/routing/route-groups

---

## Hard rules added in this session (Aug 24 2026)

- **Match the in-progress layout shape for the done state.** Same outer container, same primary sections, same vertical rhythm. The differences should be DATA, not STRUCTURE.
- **Make the wizard navigable as a reference for completed users.** Don't auto-redirect away. Let them see the all-done banner + the 7-step grid + the bottom CTAs. The system is honest about where they are.
- **Use Next.js route groups to scope layouts.** When `/section` has different chrome from `/section/*`, move inner pages into `(inner)/` with their own `layout.tsx`. Cleaner than `usePathname()` checks.
- **Two CTAs at the bottom of an all-done state** (primary + secondary). Don't force a single choice — let the user pick "Open Trading Floor" or "View checklist / Back to dashboard."

## Files touched (Aug 24 2026 polish)

- `src/components/onboarding/OnboardingHero.tsx` — done state now mirrors in-progress layout
- `src/components/onboarding/onboarding-hero.css` — `.onb-hero--done` full card + `.onb-hero__doneactions` + `.onb-hero__cta--ghost` + `.onb-hero__bar-fill--done` + `.onb-hero__chip.is-done` overrides
- `src/app/onboarding/page.tsx` — removed auto-redirect, added `isComplete` flag, top banner, two-CTA bottom row
- `src/app/onboarding/onboarding.css` — `.onb-alldone-banner` + `.onb-complete-already-done` + `.onb-complete-cta--ghost`
- Filesystem restructure: `src/app/dashboard/(main)/` route group containing 22 subroutes + `layout.tsx` + `dashboard-styles.css` (all moved via `git mv` to preserve history)
- Production deploy: `d3b462a2` (route group restructure), verified `/dashboard` 200 with no nav, `/dashboard/trading` 200 with nav
