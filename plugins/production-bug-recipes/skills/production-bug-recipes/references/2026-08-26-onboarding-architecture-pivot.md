# Aug 26 2026 — Onboarding wizard: the GoTrueClient + missing-route silent-abort architecture pivot

Session drop-in for `this skill's SKILL.md`.

This session shipped **four commits** that together converted the
onboarding wizard from "structurally fragile, depending on which
GoTrueClient singleton fires first" to "all writes go through one
SERVICE_ROLE endpoint, no client-side supabase.auth writes." It
closes Bug A (Round 1, saveRisk skips /risk-ack) and discovers
two new sibling bugs in the same wizard.

## The new recipes this session

- **Recipe #38** — `saveAccentTheme` silently aborts after
  `supabase.auth.updateUser(...)` (TurboBundle creates TWO
  GoTrueClient instances, second-line-of-code never runs).
- **Recipe #39** — `saveProfile` POSTs to `/api/profile/me` which
  doesn't exist on the server; the 404 throws and `markStep`
  never fires. Same bug shape as Bug A, different cause:
  prerequisite-route-is-missing rather than prerequisite-call-is-missing.
- **Recipe #40** — `handleFinish` calls
  `supabase.auth.refreshSession()` then `router.push('/dashboard')`;
  refreshSession stalls (same TurboBundle lock), navigation never
  happens, user is bounced back to `/onboarding`. Fix: skip
  refreshSession entirely and use `window.location.href`.
- **Recipe #41** — All four wizard steps now persist in production;
  add a wizard walkthrough script as a regression guard.
  Commit history: `933d69c1` → `722ed178` → `84490035` → `26b2a444`.

## Why the new bugs were not caught by `smoke_onboarding.mjs`

`scripts/smoke_onboarding.mjs` calls `/api/onboarding/complete-step`
*directly* via the service-role key. It short-circuits the React
wizard entirely. Every step appears "done" because we set the
column directly. **None of the React save handlers are exercised.**

To catch wizard UX bugs you need a *browser* walkthrough that
clicks the Save button for each step. That script now lives in
`skills/software-development/nextjs-supabase-admin-auth/a wizard walkthrough script`
(mirrored from the untracked working copy). Run it against any
wizard-touching PR.

## Recipe #38 — TurboBundle creates two GoTrueClients; second-line-of-code silently aborts

**Symptom:** a save handler that looks like

```ts
await supabase.auth.updateUser({ data: { theme_accent, theme_mode } })
await adminFetch('/api/onboarding/complete-step', ...)
markStep('accent_theme')
```

shows the PUT returning 200 in the network tab. The next line
NEVER runs. No thrown exception, no console error, no failed
fetch. The user clicks Save, sees "Saving…" briefly, then nothing.
`markStep` doesn't fire. UI stays at "step not done."

**Root cause:** Next.js (Turbopack and webpack with split chunks)
inlines modules per-chunk. `src/lib/supabase/browser.ts` exports
a `clientInstance` singleton via module-level state. When
`UserContext.tsx` and `src/app/onboarding/page.tsx` each get their
own copy of the module baked into separate chunks, each chunk's
`clientInstance` is its own variable. First call in each creates
its own GoTrueClient. Two GoTrueClients now live in the same
browser context, both racing on
`localStorage[sb-<project>-auth-token]`.

The browser fires the warning at runtime:

```
GoTrueClient@sb-<project-ref>-auth-token:1 (2.96.0)
Multiple GoTrueClient instances detected in the same browser context.
```

When `updateUser` writes the new JWT to localStorage, it
acquires the Navigator LockManager lock, which times out at 10s. The PUT resolves on the wire
(server saw the old token, accepted the metadata change) but the
microtask continuation on the client side has the next line of
code in a state that never executes — exactly the same shape as
the original lockManager hang, but with a different visible
behavior: PUT works, next line doesn't.

**Fix:** don't call `supabase.auth.updateUser` /
`supabase.auth.refreshSession` from inside save handlers.
Auth-mutations that need to land server-side should go through a
server route that holds SERVICE_ROLE. The new endpoint
`/api/onboarding/profile` accepts `theme_accent + theme_mode +
full_name + avatar_url` and writes them through
`svc.auth.admin.updateUserById(...)`. The full diagnosis of that race is
below: a client bundle that holds a stale auth client and a server
component that holds a fresh one.

```ts
// Was:
const supabase = getSupabaseBrowserClient()
await supabase.auth.updateUser({ data: { theme_accent, theme_mode } })
await adminFetch('/api/onboarding/complete-step', ...)

// Now:
await adminFetch('/api/onboarding/profile', {
    method: 'POST',
    body: JSON.stringify({ theme_accent: a, theme_mode: m }),
})
await adminFetch('/api/onboarding/complete-step', ...)
```

**Detection — same as before:** if the network tab shows the
prerequisite PUT/POST returning 200 but no subsequent calls land,
you have this bug class. Open the JS console, look for the
"Multiple GoTrueClient instances detected" warning.

## Recipe #39 — Prerequisite route is missing from the server entirely

This is Bug A's sibling, with a different cause. `saveProfile` was
calling `PATCH /api/profile/me` to write `full_name + avatar_url`
into `user_accounts`. That route does not exist on the server
(no handler under `src/app/api/profile/` other than
`avatar/upload`). The 404 from `adminFetch` threw, the catch set
the error toast, `markStep('profile_basics')` never fired.

**Fix:** create the missing route at
`src/app/api/onboarding/profile/route.ts` (don't create a new
top-level route directory; reuse an existing one to keep the API
surface flat). Update `saveProfile` to point at it.

**Detection — same as Bug A:** smoke tests that hit the
`/api/onboarding/complete-step` endpoint directly do not catch
this, because the React save handler is the layer that's broken.
The browser walkthrough (a wizard walkthrough script) catches it
because step 2's `logLifecycle('step2')` shows `completed_count ===
2/4` after the click on "Save avatar & name".

## Recipe #40 — `handleFinish` refreshSession + router.push bounce-back

After all 4 steps persisted, clicking "Enter the trading floor"
should land on `/dashboard`. Instead, the user was bounced back
to `/onboarding`. Same TurboBundle race — this time
`supabase.auth.refreshSession()` in `handleFinish` stalled for the
same lockManager reason.

Worse, even when refreshSession resolved, the
`router.push('/dashboard')` didn't trigger a real navigation;
the server's onboarding gate saw a stale `onboarding_complete`
state and pushed the user back to `/onboarding`.

**Fix:**
```ts
// Was:
const supabase = getSupabaseBrowserClient()
await supabase.auth.refreshSession()
router.push('/dashboard')

// Now:
// 1. Skip refreshSession — the trigger already flipped
//    onboarding_complete in the same transaction.
// 2. Soft auth-refresh broadcast via the existing /api/auth/me.
// 3. Force a full reload via window.location.href so middleware
//    re-runs against the freshly-updated DB column.
try { await adminFetch('/api/auth/me', { method: 'GET' }) } catch {}
window.location.href = '/dashboard'
```

`window.location.href` (instead of `router.push`) is the fix because
the Next.js router's internal navigation can be intercepted by
middleware/server components in a way that doesn't re-evaluate
the just-flipped column. A hard reload always does.

**Detection:** the wizard walkthrough's `final: ...` step logs
the URL after the click. If the URL stays at `/onboarding`, the
bug is the `refreshSession + router.push` combo or the
`router.push` re-evaluation failure. The trace should show a
`POST /auth/v1/token?grant_type=refresh_token` call right before
the click, indicating refreshSession resolved — but the click
navigates nowhere.

## Recipe #41 — Add a wizard walkthrough script as a regression guard

Add it as a sibling to `scripts/smoke_onboarding.mjs`, NOT as a
replacement. The smoke test catches API wiring; the walkthrough
catches UI wiring. Both are needed. Walkthrough lives in
`software-development/nextjs-supabase-admin-auth/scripts/` (it
uses Playwright which is project-level); copy to
a wizard walkthrough script if your project doesn't have
Playwright in the next core node_modules.

The walkthrough creates a fresh user via the Supabase admin auth
API (writes creds to `/tmp/wizard_test_creds.json`), logs into
the production wizard, drags the SwipeToApprove gesture, clicks
each Save button, and reports the lifecycle `completed_count`
after each. **Any step that doesn't bump the count has a broken
save handler.** That's the asymmetric signal that's impossible to
get from a service-role API test alone.

## Companion skills (cross-links)

- the Turbopack auth-client race — full diagnosis for the silent-abort
  behavior.
- the wizard save handler and its missing prerequisite — Bug A + Bug B side
  by side.
- the LockManager / `getSession` hang — same root cause as the wizard bug
  but a different symptom.
- the router navigation cookie mirror — why `router.push` after a
  server-side flag flip can still bounce.

## What was NOT done

- `app_get_user_lifecycle` migration (`202608250001/250002/250003`)
  is not applied to production. The lifecycle endpoint falls back
  to `app_get_onboarding_progress`, sets `_migration_pending: true`,
  and reports correct counts because the legacy function includes
  all 4 steps + auto-ticks `application_approved`. The wizard works
  either way; the migration must be applied for `application_status`
  to be surfaced to the wizard (so Round 7's lock fires for
  genuinely-pending users).
- Login UX: "SWIPE TO ACCESS" gesture on `/login` is
  mouse-inaccessible on desktop. Separate ticket.
- The React `completed` Set can lag behind the SQL state. The
  walkthrough handles this by polling `/api/onboarding/lifecycle`
  instead of relying on the wizard's local state.
