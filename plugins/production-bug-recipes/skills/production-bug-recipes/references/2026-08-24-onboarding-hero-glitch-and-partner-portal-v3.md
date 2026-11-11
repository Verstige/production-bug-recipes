# Aug 24 2026 — OnboardingHero splash glitch, JSX-reference analysis technique, CSS-only redesign preserving JSX

Drop-in for `this skill's SKILL.md` merge.

Three independent patterns discovered on Aug 24 2026:

---

## Recipe #35 — `OnboardingHero` shows the wizard on a stale-data mount (closed-PWA reload shows "Welcome" + "Open wizard" CTA when user is already complete)

**Symptom:** a user who has already completed onboarding closes their PWA and reopens it. They land on `/dashboard`. The OnboardingHero at the top of the page shows:
- Eyebrow: `Setup · loading`
- Title: `Welcome to the platform`
- Lede: `A quick checklist to set up your platform setup, your risk profile, and your broker connection. Built for everyone — no jargon, no rush.`
- Big CTA button: `Open the onboarding wizard →`

The user is **already complete** — DB has `onboarding_complete=true`. But the hero claims they need to onboard. The CTA is misleading and the page "glitches out."

**Root cause:** OnboardingHero had three render paths, and the loading path was misleading:

```tsx
// OLD — buggy version
if (!lifecycle) {
    return <FullHero with "Welcome to the platform" + "Open wizard" CTA />
}
if (lifecycle.onboarding_complete) return <DonePill />
return <FullHero with "X/7 complete" + CTA />
```

The `if (!lifecycle)` branch (no data yet) renders the FULL hero with the misleading CTA. The user sees this branch whenever the `useEffect`-triggered `/api/onboarding/lifecycle` fetch hasn't resolved yet.

On a PWA cold-start (close + reopen), the fetch goes through `adminFetch` (reads token directly from localStorage). But:
- `supabase-js`'s internal `getSession()` was never called by this component (it uses adminFetch, not supabase)
- The `useUser()` hook in the parent DID call `supabase.auth.getSession()`
- The lockManager contention (Recipe #15) makes `useUser()` slow
- The `profile` from `useUser()` may not have resolved yet either

So on PWA cold-start, both `useUser()` AND `fetchLifecycle()` are slow, and the hero shows the misleading full state while waiting for both.

The user's confusion is valid: the wizard looks like a real prompt, not a "still loading" state. They click "Open wizard" and end up on `/onboarding` — which has a `useEffect` that auto-redirects them to `/dashboard` after 3s if they're complete, but only if they wait it out.

**The fix — use `useUser()` as the synchronous source of truth:**

```tsx
// src/components/onboarding/OnboardingHero.tsx
'use client'
export function OnboardingHero() {
    const router = useRouter()
    const { profile, loading: userLoading } = useUser()
    const knownOnboarded = profile?.onboardingComplete === true

    const [lifecycle, setLifecycle] = useState<LifecycleResponse | null>(null)

    // ONLY fetch lifecycle if we know the user is NOT onboarded.
    // If we know they ARE onboarded, skip the fetch entirely.
    useEffect(() => {
        if (knownOnboarded) return
        // ... fetchLifecycle (Recipe #34 pattern) ...
    }, [knownOnboarded])

    // Path 1: User is confirmed onboarded → DONE PILL, no fetch needed
    if (knownOnboarded) {
        return <DonePill />
    }

    // Path 2: Loading (UserContext or lifecycle in flight) → SHIMMER
    // Never claims \"Welcome to the platform\". No CTA. Just placeholder.
    if (userLoading || !lifecycle) {
        return (
            <div className=\"onb-hero onb-hero--skeleton\" aria-busy=\"true\">
                <div className=\"onb-hero__skel-eyebrow\" />
                <div className=\"onb-hero__skel-title\" />
                <div className=\"onb-hero__skel-lede\" />
                <div className=\"onb-hero__skel-bar\" />
            </div>
        )
    }

    // Path 3: User is confirmed NOT onboarded → full hero with CTA
    return <FullHero ... />
}
```

The shimmer placeholder has:
- Same vertical footprint as the full hero (preserves layout)
- No headline text — doesn't claim anything
- No CTA button — doesn't prompt any action
- Subtle 2s shimmer animation (`background-position: -200% → 200%`)
- `aria-busy="true"` for assistive tech

When data lands, the hero resolves to either the done pill or the wizard. Never the misleading middle state.

**The shimmer CSS:**

```css
.onb-hero--skeleton {
    padding: 22px 26px;
    border-radius: 18px;
    background:
        radial-gradient(ellipse at top right, rgba(255, 255, 255, 0.04), transparent 60%),
        linear-gradient(180deg, rgba(255, 255, 255, 0.025), rgba(255, 255, 255, 0.005));
    border: 1px solid rgba(255, 255, 255, 0.06);
    display: flex;
    flex-direction: column;
    gap: 12px;
    min-height: 200px;
    position: relative;
    overflow: hidden;
}
.onb-hero--skeleton::before {
    content: '';
    position: absolute;
    inset: 0;
    background: linear-gradient(90deg, transparent, rgba(255, 255, 255, 0.04), transparent);
    background-size: 200% 100%;
    animation: onb-skel-shimmer 2s ease-in-out infinite;
}
@keyframes onb-skel-shimmer {
    0%   { background-position: -200% 0; }
    100% { background-position:  200% 0; }
}
.onb-hero__skel-eyebrow { width: 100px; height: 18px; border-radius: 999px; background: rgba(255, 255, 255, 0.06); }
.onb-hero__skel-title   { width: 65%;   height: 36px; border-radius: 12px;  background: rgba(255, 255, 255, 0.05); }
.onb-hero__skel-lede    { width: 90%;   height: 14px; border-radius: 6px;   background: rgba(255, 255, 255, 0.04); }
.onb-hero__skel-bar     { width: 100%;  height: 6px;  border-radius: 3px;   background: rgba(255, 255, 255, 0.04); margin-top: 8px; }
```

**The general rule — three states, never two:**

Any UI that gates on async data must have THREE render paths, not two:

| State | What to render |
|---|---|
| Loading | Shimmer placeholder — same footprint, no headline, no CTA, no claim |
| Data confirmed present | Full UI |
| Data confirmed absent | Empty / error / CTA |

A common bug is to merge \"loading\" and \"data absent"\" into a single branch. That's wrong because the user can't tell whether the system is slow or whether the data is genuinely missing. Split them. The loading branch must:
- Have the SAME vertical footprint as the full UI (no layout shift on resolve)
- NOT include any claim (\"Welcome\", \"X/N complete\", etc.)
- NOT include any action button (no CTAs while uncertain)
- Animate subtly so the user knows the system is alive

**The companion rule — use the synchronous context as the source of truth:**

When the parent context already has the answer (e.g. `useUser().profile.onboardingComplete`), don't wait for the child component's own fetch. Read the context first. Only fetch granular details (the lifecycle, the checklist) when the context says \"user is NOT in the complete state.\" This is the React equivalent of "check the parent first, then the child."

```tsx
// Right pattern — use context synchronously, then fetch for detail
const knownOnboarded = useUser().profile?.onboardingComplete === true
if (knownOnboarded) return <DonePill />
// Only NOW do we need lifecycle (for granular step state)
const lifecycle = useFetch('/api/onboarding/lifecycle', { skip: knownOnboarded })
```

**The diagnostic — is the bug present?**

```bash
# Find any component that renders a CTA while lifecycle is null
rg -A3 \"if \\(!lifecycle\\)\" src/components/
```

If the matching JSX block contains a button or headline, the component has the bug. Replace with the shimmer pattern.

**When this hits again:** any onboarding-style wizard component that fetches its own progress on mount. Or any \"should I show feature X to user Y?\" component that shows feature X while the answer is in flight. The fix is always the same: use the parent context synchronously, fetch only for detail, show a shimmer while waiting.

**Pair with:** Recipe #34 (useUser loading=false race + lockManager contention). Recipe #35 is the specific case where the loading-state component renders misleading content during the race. The general fix from #34 is the parent provider; #35 is the consumer.

---

## Recipe #36 — JSX reference analysis technique: find missing imports in Turbopack-bundled chunks before runtime

**Class of work:** Next.js with Turbopack bundles components into hashed chunks. When a JSX file references a symbol that's NOT imported (or fails to resolve), the bundler may still produce output — but at runtime the component throws `ReferenceError: <symbol> is not defined`. TypeScript catches SOME of these (missing imports for components used as JSX), but not all (e.g. when the import path is wrong but the file exists, or when the component is imported but its chunk is split into a separate lazy-loaded module that hasn't loaded yet).

**The technique — search the deployed chunks before reporting back to the user:**

```python
# 1. Find the chunk(s) loaded on the page
import re
body = _get('https://www.yourdomain.com/<page>', headers={'User-Agent': 'Mozilla/5.0'})
chunks = list(set(re.findall(r'_next/static/chunks/([^\\\"\\']+\\.js)', body)))

# 2. For each chunk, check for the symbols referenced in JSX
for chunk in chunks:
    cb = _get(f'https://www.yourdomain.com/_next/static/chunks/{chunk}')
    print(f\"{chunk}: {len(cb)}b\")

# 3. Search for JSX component references
# Pattern: (0, s.jsx)(IDENT, {...})
import re
matches = re.findall(r'\\(0,s\\.jsx[s]?\\)\\((\\w+),\\{', chunk_body)
used = set(matches)

# 4. Find what functions are declared in the chunk
funcs = set(re.findall(r'function (\\w+)\\s*\\(', chunk_body))

# 5. Cross-reference
undeclared = used - funcs - {'s', 'a', 'r', 't', 'n', 'i', 'l', 'c', 'o', 'd', 'p', 'h', 'm', 'x', 'u', 'g', 'j', 'b', '_', 'f', 'v', 'y', 'N', 'k', 'w'}  # common minified single-letter imports
print(f\"UNDEFINED JSX idents: {undeclared}\")
```

**The signal:** any `undeclared` that doesn't match a Turbopack-import alias (`e.i(N)` for module N) is a missing reference.

For Turbopack, imports look like:
```js
var s = e.i(43476), a = e.i(71645), r = e.i(22016), ...
let ea = (0, w.default)(\"network\", [...])  // ea is minified name for Network icon
```

So the chunk DOES have:
```js
var w = e.i(75254)
let ea = (0, w.default)(\"network\", [...])
```

And the JSX uses `(0, s.jsx)(ea, {...})` — `ea` is defined. No bug.

But if the JSX uses `(0, s.jsx)(foo, {...})` and `foo` is NOT declared anywhere in the chunk, the bundler will still produce output, and the runtime will throw.

**Companion check — e.i(N) declarations:**

```python
# Find module IDs used in the chunk
import re
used_ids = set(re.findall(r'e\\.i\\((\\d+)\\)', chunk_body))
# Find which IDs are declared (top of chunk)
initial_map = re.search(r'var \\w+=e\\.i\\(\\d+\\)(?:,\\w+=e\\.i\\(\\d+\\))*', chunk_body[:3000])
declared_ids = set(re.findall(r'e\\.i\\((\\d+)\\)', initial_map.group(0)) if initial_map else [])
undeclared = used_ids - declared_ids
# Anything not declared in the initial map is declared LATER in the chunk
# (Turbopack splits var declarations across the file). So this check
# is \"any import that doesn't appear ANYWHERE in the chunk.\"
```

**The diagnostic output for an actual bug** (Aug 24 2026, PartnerPortal redesign v1):

```
Symbol references: 0
  ✗ the CFD brokerIBPanel: NOT FOUND in any loaded chunk
  ✗ CommissionCalculator: NOT FOUND in any loaded chunk
  ✗ LifecycleDrawer: NOT FOUND in any loaded chunk
  ✗ PartnerOnboardingModal: NOT FOUND in any loaded chunk
```

`LifecyclePill` was referenced in the JSX (`<LifecyclePill lifecycle={d.lifecycle} onClick={...} />`) but never imported. The bundler had let it through because the import statement was missing. At runtime, `ReferenceError: LifecyclePill is not defined` → \"Application error: a client-side exception has occurred.\"

**The fix — when JSX references a component that's not declared in the chunk:**

1. Check if the component exists in the codebase:
   ```bash
   find src -name \"LifecyclePill*\" -o -name \"LifecycleDrawer*\"
   ```

2. If it exists but isn't exported, define it locally in the consumer or export it.

3. If it doesn't exist, define a stub component matching the JSX props.

**The general rule — never trust \"TypeScript clean\" as proof of correctness for JSX-bound components.**

`tsc --noEmit` passing is necessary but not sufficient. Turbopack's bundler is more lenient than TypeScript in some ways (it doesn't always catch missing JSX references that compile cleanly to `s.jsx(COMPONENT, ...)`). The runtime check is the source of truth.

**The verification before claiming a component is production-ready:**

```python
# Pull the deployed chunk, check every JSX ident has a definition
import re
chunk_body = _get(...)
used = set(re.findall(r'\\(0,s\\.jsx[s]?\\)\\((\\w+),\\{', chunk_body))
funcs = set(re.findall(r'function (\\w+)\\s*\\(', chunk_body))
undeclared = used - funcs - single_letter_imports
if undeclared:
    print(f\"BEFORE claiming deploy is good, fix: {undeclared}\")
```

**When this hits again:** any new component that imports other components. Any redesign that touches JSX imports. Any refactor that pulls a component from one file to another. Always run the cross-reference check before claiming \"shipped, no errors.\"

**Companion rule — when something is \"imported\" but the chunk doesn't reference it, that import was bundled into a separate chunk that loads async.**

```bash
# Look for e.i(N) imports that are declared LATER in the chunk (not in initial map)
rg \"var [A-Z]+=e\\.i\\((\\d+)\\)\" <chunk>
```

If a component's module ID appears in the chunk but isn't in the initial var declarations, Turbopack is doing code-splitting. The component is in a separate chunk. If the page doesn't `await` that chunk (e.g. uses `React.lazy()`), the runtime throws.

**The deeper lesson — when a chunk has \"0 references\" to a sub-component that's statically imported, the bundler may have hoisted the import to a sibling chunk.** That's fine if the consumer wraps in `React.lazy()` or uses dynamic `import()`. It's a bug if the consumer treats it as statically available.

---

## Recipe #37 — CSS-only design overhaul that preserves JSX structure (when the user wants a \"redesign\" but JSX rewrites break things)

**Class of work:** the user asks for \"another redesign\" or \"gorgeous upgrade\" or \"v3 of the partner portal.\" The previous redesign (which rewrote JSX) shipped a runtime exception that took 5+ fixes to track down. The user is frustrated. The safest path is a CSS-only overhaul.

**The technique — keep all JSX, restyle with CSS Grid + visual reordering:**

1. **Audit the existing JSX render order.** Identify which children exist and what they render:
   ```bash
   # Identify the JSX render path in the page component
   rg -A2 \"return \\(\" src/components/<page>.tsx | head -30
   ```

2. **Map JSX children to grid areas via nth-child selectors.** The DashboardShell renders as `<div id="..." class="ds-shell"><div class="ds-grid-bg"/><div class="ds-glow--1"/><div class="ds-glow--2"/><div class="ds-scanlines"/><div class="ds-shell-content">{children}</div></div>`. Target the children of `.ds-shell-content`.

   ```css
   #partner-portal > .ds-shell-content {
     display: grid;
     grid-template-columns: minmax(0, 1fr) 320px;
     grid-template-areas:
       'header    header'
       'kpis      kpis'
       'tabs      tabs'
       'content   sidebar';
     gap: 18px;
   }
   #partner-portal > .ds-shell-content > :nth-child(1) { grid-area: header; }
   #partner-portal > .ds-shell-content > :nth-child(2) { grid-area: kpis; }
   #partner-portal > .ds-shell-content > :nth-child(3) { grid-area: sidebar; }
   #partner-portal > .ds-shell-content > :nth-child(5) { grid-area: tabs; }
   #partner-portal > .ds-shell-content > :nth-child(n+6) { grid-area: content; }
   ```

3. **Re-style each existing class with the new visual language.** All existing classes (`.ds-tab`, `.pp-rank-block`, `.pp-share`, `.ds-card`, etc.) keep their JSX references but — are overridden via cascade to match the new design tokens:

   ```css
   .ds-tab.active {
     background: linear-gradient(135deg, rgba(var(--pp-accent), 0.18), rgba(var(--pp-accent), 0.04));
     border-color: rgba(var(--pp-accent), 0.32);
     color: var(--pp-accent);
     box-shadow: 0 0 0 3px rgba(var(--pp-accent), 0.10), 0 8px 20px rgba(var(--pp-accent), 0.22);
   }
   ```

4. **Test that the JSX order didn't change.** The visual re ordering happens entirely via CSS Grid `grid-area`. The actual DOM order is preserved (good for accessibility — screen readers read the elements in DOM order, not visual order).

5. **Keep all data flows, hooks, components, and effects untouched.** The component still calls `useUser()`, still mounts `the CFD brokerIBPanel`, still uses `<DashboardCard>` and `<DashboardPageHeader>`. Just the visual layer changes.

**Why this works better than a JSX rewrite for a \"redesign\":**

| Aspect | JSX rewrite | CSS-only |
|---|---|---|
| Time to ship | Hours (lots of file edits, build risks) | 30 min (one CSS file rewrite, no TS risk) |
| Runtime exception risk | HIGH — new JSX, new imports, new bundler splits | LOW — same JSX, same imports, same chunks |
| Type-check | Often catches missing imports | Same |
| Visual reordering | Easy via DOM reorder | Easy via CSS Grid `grid-area` |
| Accessibility | DOM order = visual order (typical) | DOM order preserved (screen-reader friendly) |
| Visual identity shift | Total — JSX shape determines layout | Total — CSS shape determines layout |
| Reversibility | Hard — JSX is committed | Easy — revert the CSS file |

**The CSS-only restriction that bites sometimes:**

You can't reorder ARIA landmarks or focus order (DOM order = focus order). For most marketing/dashboard pages this doesn't matter — the user navigates by clicking nav items, not by tabbing through sections. If the page is form-heavy (text inputs, modals), CSS-only might disrupt focus flow.

**The hybrid pattern — CSS Grid + a few key DOM swaps:**

If visual reordering via CSS Grid isn't enough, identify the SPECIFIC children that need to swap, and swap ONLY those via React Fragments:

```tsx
// Before — children rendered in DOM order that doesn't match visual intent
return (
  <DashboardShell id=\"partner-portal\">
    <DashboardPageHeader />
    <DashboardDataStrip />
    <DashboardCard className=\"pp-hero-card\">...</DashboardCard>   {/* sidebar */}
    <DashboardCard className=\"pp-share-card\">...</DashboardCard>    {/* sidebar */}
    <nav className=\"ds-tabbar\">...</nav>
    {tab === 'overview' && <OverviewContent />}
    {tab === 'commissions' && <CommissionsContent />}
  </DashboardShell>
)

// After — keep children, let CSS Grid do the reordering
return (
  <DashboardShell id=\"partner-portal\">
    <DashboardPageHeader />
    <DashboardDataStrip />
    <DashboardCard className=\"pp-hero-card\">...</DashboardCard>
    <DashboardCard className=\"pp-share-card\">...</DashboardCard>
    <nav className=\"ds-tabbar\">...</nav>
    {tab === 'overview' && <OverviewContent />}
    {tab === 'commissions' && <CommissionsContent />}
  </DashboardShell>
)
// ↑ Identical JSX! Only CSS Grid selectors change.
```

**The audit before claiming a CSS-only redesign is done:**

```bash
# 1. The file count that changed (should be just CSS, maybe JSX for ARIA landmarks)
git diff --stat HEAD~1
# Expected: src/components/.../X.css (only)

# 2. The TS check is still clean
npx tsc --noEmit

# 3. The build is clean
npx next build 2>&1 | tail -5

# 4. Verify the deployed chunks have the OLD JSX hash (not a new one)
# (a new JSX hash would mean the JSX actually changed)
```

**When this hits again:** any \"redesign\" or \"v3\" request after a JSX rewrite already broke things. Default to CSS-only. Reach for JSX changes only when the user explicitly needs new functionality (a new step in the wizard, a new field, a new API call).

**Pair with:** Recipe #36 (JSX reference analysis technique) — before claiming the CSS-only deploy is good, run the chunk cross-reference check to verify all JSX idents are defined.

---

## Hard rules added in this session (Aug 24 2026)

- **Three render paths for any async-data component: loading shimmer, data present, data absent.** Never merge loading with \"data absent\" — the user can't tell whether the system is slow or whether the data is missing.
- **Use the synchronous parent context as source of truth before fetching for detail.** `useUser().profile.onboardingComplete` is the answer for many components; the lifecycle fetch is for granularity.
- **CSS-only redesign is the safer default after a JSX rewrite has caused runtime exceptions.** Visual reordering via CSS Grid + class restyling preserves JSX, hooks, data flow, and runtime stability.
- **Never trust \"TypeScript clean\" as proof of runtime correctness for JSX-bound components.** Run the chunk cross-reference check before claiming any deploy is good.
- **The shimmer placeholder must preserve layout footprint and never include a CTA or claim.** Same height, same width, no buttons, no text.

## Files touched (Aug 24 2026)

- `src/components/onboarding/OnboardingHero.tsx` (REWRITTEN) — useUser as source of truth, three-state render paths
- `src/components/onboarding/onboarding-hero.css` (appended) — `.onb-hero--skeleton` + shimmer keyframes
- `src/components/partners/PartnerPortal.css` (rewritten, CSS-only v3 redesign) — CSS Grid layout, per-rank theming, sidebar widgets
- Production deploys: `8200e304` (ENGINE_A), `84d9fa5c` (page-level gate), `89bca7f4` (LifecyclePill), `d9299165` (gorgeous CSS), `e16e235c` (portal v3), `30db9739` (useUser-as-truth), `f8b85b6e` (changelog backfill), `79534faa` (splash self-recovery)

## E2E verification

```bash
# 1. OnboardingHero no longer claims Welcome while loading
curl -sL https://www.yourdomain.com/dashboard | grep -c \"onb-hero--skeleton\"
# → at least 1 (skeleton class present in CSS bundle)

# 2. Partner Portal renders v3 layout
curl -sL https://www.yourdomain.com/dashboard/partners | grep -c \"ds-shell-content\"
# → at least 1

# 3. CSS Grid selectors in deployed CSS
curl -sL https://www.yourdomain.com/_next/static/chunks/<hash>.css | grep -c \"grid-area\"
# → at least 6 (header, kpis, sidebar, tabs, content rows)

# 4. Old pp-canvas-hero / pp-rail (v2 leftovers) absent from production
curl -sL https://www.yourdomain.com/_next/static/chunks/<hash>.css | grep -E \"pp-canvas-hero|pp-rail\"
# → zero hits
```


## Related class-level recipes (added Aug 24 2026)

The work in this reference file also produced four new class-level recipes in the parent `SKILL.md`:

- **Recipe #25 — Client-side auth/permission gates must require DECISIVE state, not undefined** — the `useOnboardingGate` `OnboardingGateRedirect` bug that caused the "redirect-bounce" pattern. The fix pattern (explicit `hasDecisiveStatus` boolean check before any redirect) generalizes to every client-side permission gate that reads from UserContext.

- **Recipe #26 — Never hardcode business rules that are stored in the database** — the lesson-progress 80% hardcoded threshold bug. The pattern generalizes to every place where a value varies by row/category but the code hardcodes a single value.

- **Recipe #27 — SQL `WHERE col=*** is case-sensitive; reason keys must match the case the code passes** — the bug that bypassed daily/weekly/lifetime caps because the DB stored reasons UPPERCASE while the code passed lowercase. The pattern generalizes to every registry table (statuses, types, categories).

- **Recipe #28 — Customer-facing copy: describe what's there, don't push actions or expose internals** — the three rounds of /guide walkthrough copy edits. The pattern generalizes to every first-run, onboarding, and walkthrough surface.
