# Aug 24 2026 — Onboarding wizard: missing-CSS bug, dashboard-gate gap, infinite-loading fix, 4-step trim

Session drop-in for `this skill's SKILL.md` merge.

This session covered four real production issues, in order:

1. **Missing CSS import bug** (round 6 white-text bug was a CSS bundling issue)
2. **Dashboard-gate gap** (new users could see `/dashboard` even though it should be gated)
3. **"Setting things up…" infinite-loading hang** on `/onboarding` mount effect
4. **Wizard trim** (6 steps → 4 steps; remove the broker connect + push notifications)

New SKILL.md recipes covered in this drop-in:
- **Recipe #29** — Missing CSS import causes white-text bug
- **Recipe #30** — Next.js App Router layout composition: `(route-group)` boundary traps
- **Recipe #31** — `withTimeout` race for mount-effect async calls (iOS PWA IndexedDB hang)

What this session also did (out of scope for these recipes, captured in commit logs):
- Trimmed the onboarding wizard from 6 steps to 4 — the broker connect + push notifications moved out of the wizard
- Added explicit "Save color & theme" / "Save avatar & name" / "I understand & accept" CTAs to steps 1, 2, 3
- Updated SQL trigger `app_onboarding_step_changed` to require 4 keys (was 6)
- New migration `202608240011_trim_to_4_steps.sql` re-creates lifecycle + complete-step RPCs
- Smoke test updated to expect 4 steps (12/12 pass)

## Round 6 white-text bug — root cause

The `/onboarding` page was rewritten from scratch via `write_file` in Round 6. The new page had the entire wizard logic but **no `import './onboarding.css'`**. Next.js/Turbopack only bundles CSS that gets explicitly imported by a page or component — a 42KB `onboarding.css` file sitting next to `page.tsx` does nothing if the import line is missing. The build succeeded (no error), the production HTML had a CSS link tag, but the link pointed to a CSS chunk that did NOT contain the onboarding styles. The user saw raw browser-default text on the dark background.

`tsc` passed clean (TS doesn't check CSS bundling). `next build` passed clean (Webpack drops orphaned files silently).

The fix: re-add the import line. After deploying, fetch `/_next/static/css/<hash>.css` and grep for distinctive class names (`.onb-all-root`, `.onb-all-step`, etc.) to confirm the styles shipped.

Same bug class: any sub-page that gets full-content-replaced via `write_file` should have its CSS import audit run before deploy.

## Round 8 dashboard-gate gap — root cause

After Round 6, the onboarding gate (`OnboardingGateRedirect` + `DashboardGuard`) lived in `/app/dashboard/(main)/layout.tsx`. This wraps:

- `/app/dashboard/(main)/trading/page.tsx` ✅
- `/app/dashboard/(main)/partners/page.tsx` ✅
- `/app/dashboard/page.tsx` ❌ (sibling of `(main)`, not a child)

App Router route groups `(main)` are just organizational. They create layout boundaries but not URL segments. A layout at `(main)/layout.tsx` only affects files in `(main)/`. `/app/dashboard/page.tsx` is a sibling, not a child.

The fix: put the gate at `/app/dashboard/layout.tsx` instead. Now every `/dashboard/*` URL (whether under `(main)` or directly under `/dashboard/`) flows through the gate. Strip the duplicate gate from `(main)/layout.tsx` — that file now handles UI chrome only.

Verified by visiting `/dashboard` with a fresh user — they get redirected to `/onboarding`. Before the fix, they could see the dashboard home.

## Round 8 infinite-loading bug — root cause

The `/onboarding` page had a `useEffect` that chained `supabase.auth.getUser()` → `adminFetch('/api/onboarding/lifecycle')` → `supabase.from('user_accounts').select(...)`. None of these have a default timeout. On iOS PWA (after backgrounding, fast-tapping, cold-start, or IndexedDB contention), `supabase.auth.getUser()` can hang indefinitely on the IndexedDB lock. The mount effect never resolves. `setReady(true)` never fires. The user sees "Setting things up…" indefinitely.

The fix: `withTimeout<T>(promise, ms, fallback)` helper that races each awaited call against a 4-5s timer, plus a 5s safety timer at the effect level that always fires `setReady(true)` even if `Promise.race` itself misbehaves. Code:

```ts
async function withTimeout<T>(promise: Promise<T>, ms: number, fallback: T): Promise<T> {
    let timer: ReturnType<typeof setTimeout> | undefined
    try {
        return await Promise.race([
            promise,
            new Promise<T>((resolve) => { timer = setTimeout(() => resolve(fallback), ms) }),
        ])
    } finally {
        if (timer) clearTimeout(timer)
    }
}

useEffect(() => {
    const safetyTimer = setTimeout(() => setReady((prev) => prev || true), 5000)
    ;(async () => {
        try {
            const r = await withTimeout(
                adminFetch('/api/onboarding/lifecycle', { method: 'GET' }),
                4000,
                new Response(JSON.stringify({ ok: false }), { status: 504 }),
            )
            // ... use r ...
        } catch { /* ... */ } finally {
            clearTimeout(safetyTimer)
            setReady(true)
        }
    })()
}, [router])
```

This pattern should be applied to every Next.js mount effect that does async work, by default. It's three lines per call site.

## Round 9 wizard trim — root cause

User feedback after Round 8 was: "Connect the broker and enable push notifications should be removed from the wizard since the user has to do that inside the profile settings anyway once they download the PWA."

The fix:
- Steps 4 (the broker connect) and 5 (push notifications) removed from the wizard
- Walkthrough (was step 6) renumbered to step 4
- Steps 1, 2, 3 promoted to primary CTAs with explicit Save buttons (previous Round 6 had auto-save on tile click for step 1, secondary-styled save for steps 2 + 3)
- SQL trigger `app_onboarding_step_changed` updated: required_count 6 → 4, required_keys array updated
- `app_get_user_lifecycle` / `app_get_onboarding_progress` / `app_complete_onboarding_step` RPCs recreated with the new 4-key count
- `src/lib/onboarding/steps.ts` array updated to drop connect_broker + enable_push from the wizard (step_keys preserved in DB for legacy rows)
- Sub-pages `/onboarding/avatar`, `/onboarding/connect`, `/onboarding/push` converted to redirect stubs (`router.replace('/onboarding')`) for backwards compat with bookmarks and old email links

New migration: `202608240011_trim_to_4_steps.sql`.

Smoke test updated: 14/14 → 12/12 (the 2 retired step tests removed).

## Commits added

- `8333ac09` Round 7 — application-pending hero + lock overlay + 10s auto-redirect (earlier session)
- `1be7d7de` Round 7.5 — critical: missing CSS import fix for white-text bug (the foundation of Recipe #29)
- `ba793a60` Round 8 — gate /dashboard for incomplete users + kill the "Setting things up" hang (Recipes #30 + #31)
- `92b3e8bf` Round 9 — feat: 4-step wizard with explicit Save buttons
- `d59a7de4` Round 9 — test: smoke test reflects 4-step wizard

Deploy chain: `0a4d92a5` → `ff62aecf` → `7e14737a` (all SUCCESS on Railway).

## What to watch for in the next session

1. **Always check for the CSS import** when rewriting a page with `write_file`. Grep the original file's imports and ensure every CSS import is preserved.

2. **Always check the layout boundary** when adding an auth/permission gate. List every URL the gate should cover and verify each. Don't trust `(route-group)` to mean "everything below".

3. **Always wrap mount-effect async in `withTimeout`** on iOS PWA. The page looks correct in dev but hangs in prod on real users.

4. **When the wizard step count changes**, update the SQL trigger AND the smoke test in the same commit. Otherwise test 7 (lifecycle complete) and test 3 (initial state) become false positives.

5. **Don't strip the gate when trimming the wizard** — the wizard's step count and the auth gate are separate concerns. The trim from 6→4 just changes what counts as "complete," not whether the gate fires.
