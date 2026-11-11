# 2026-09-14 — Supabase browser/server cookie format mismatch + `.toUpperCase()` landmine class

Both bugs surfaced on the same day after a weeks-long auth debug arc. The order they were fixed in is informative — the auth cookie mismatch was found by reading the source code, the `.toUpperCase()` landmines were found by adding a stack-surfacing error boundary and waiting for the next crash.

## 1. Supabase browser/server cookie format mismatch

**Symptom:** Every browser-originated API route returns `401 Not authenticated` even though the page renders the user's data correctly. `useUser()` works (client-side `localStorage` hydration succeeds), server-side `supabase.auth.getSession()` returns null. Toast shows "Not authenticated" or "Partner access required" depending on route logic.

**Root cause:** `getSupabaseBrowserClient()` returned `@supabase/supabase-js`'s `createClient` with a custom `localStorage` shim that ALSO wrote to `document.cookie`. The server used `@supabase/ssr`'s `createServerClient`. **The two libs disagree on cookie format.**

`@supabase/ssr@0.8`'s `combineChunks` reads cookies as:
- Cookie named exactly `sb-<project>-auth-token` containing URL-encoded JSON, OR
- Chunked cookies named `sb-<project>-auth-token.0`, `.1`, `.2`, ...

The custom shim wrote `btoa(JSON).autorefresh` — btoa-wrapped value with a `.autorefresh` suffix. `combineChunks` doesn't recognize either pattern → returns null server-side.

### Three-stage fix that's worth understanding

| Stage | Change | Outcome |
|---|---|---|
| 1. Add `encodeURIComponent(JSON)` instead of `btoa(JSON)` | URL-encoded, looks right | Still broken — JSON.parse fails because content starts with `%` |
| 2. Switch to `@supabase/ssr`'s `createBrowserClient` | Writes in chunked `base64-` format by default | Works — symmetric by construction |
| 3. Add `client.auth.setSession(...)` migration on first load | Hydrates SSR-format cookie for users with stale localStorage | No one gets logged out by the upgrade |

### Code: the only fragment that mattered

```ts
// src/lib/supabase/browser.ts
import { createBrowserClient } from '@supabase/ssr'

export function getSupabaseBrowserClient(): SupabaseClient {
  if (clientInstance) return clientInstance
  if (!supabaseUrl || !supabaseAnonKey) {
    throw new Error('[supabase] NEXT_PUBLIC_SUPABASE_URL / _ANON_KEY missing...')
  }
  clientInstance = createBrowserClient(supabaseUrl, supabaseAnonKey)

  // Migrate legacy localStorage sessions into SSR-format cookies.
  if (typeof window !== 'undefined') {
    const stored = localStorage.getItem(SUPABASE_AUTH_KEY)
    if (stored) {
      try {
        const parsed = JSON.parse(stored)
        if (parsed?.access_token && parsed?.refresh_token) {
          clientInstance.auth.setSession({
            access_token: parsed.access_token,
            refresh_token: parsed.refresh_token,
          }).catch(() => {})
        }
      } catch {}
    }
  }
  return clientInstance
}
```

### Why the earlier attempts failed (and the lesson)

When I was wrong, **my hypothesis was right but the fix was wrong.** The cookie format mismatch was real, but writing `encodeURIComponent(JSON)` looked plausible: the cookie went in, the server read it, but `combineChunks` returned a URL-encoded string, `JSON.parse` failed, session was null. The fix wasn't about which encodings to use — it was about using the SAME library on both sides.

**Discipline:** before adding a custom storage shim "to make localStorage work as cookies," read `node_modules/@supabase/ssr/dist/main/utils/chunker.js` and confirm what `combineChunks` actually parses. If your write side doesn't match, no amount of encoding-swapping fixes it.

### Files touched

- `src/lib/supabase/browser.ts` — rewrote to use `createBrowserClient` from `@supabase/ssr`
- API routes didn't need logic changes once cookies flowed correctly

---

## 2. `.toUpperCase()` is a class of landmine — guard every callsite or wire a boundary

**Symptom:** `TypeError: undefined is not an object (evaluating 'e.toUpperCase')`. Page renders TabErrorBoundary red card "Something went wrong. Your data is safe — a hard refresh will restore everything." Sometimes the boundary shows the error, sometimes the entire app falls back to Next.js's default crash UI.

**Why it keeps happening.** Every `<X.toUpperCase()>` where `X` comes from server data (Supabase row, Stripe response, broker account payload) is one bad row away from crashing. `?? 'UNKNOWN'` on a single callsite is whack-a-mole.

### Callsite scatter (Sep 14 2026)

| File | Line | Was | Now |
|---|---|---|---|
| `src/components/trading/RecentSignalCard.tsx` | 89 | `signal.status.toUpperCase()` | `(signal.status ?? 'UNKNOWN').toUpperCase()` |
| `src/app/dashboard/(main)/algo-os/page.tsx` | 325–336 | `data.subscription.status.toUpperCase()` etc. | `(data.subscription.status ?? 'unknown').toUpperCase()` |
| `src/app/dashboard/(main)/trading/settings/page.tsx` | 1603 | `account.account_type.toUpperCase()` | `account.account_type?.toUpperCase() ?? 'ACCOUNT'` |
| `src/components/trading/TradingDashboardView.tsx` | 277 | `signal.pair.toUpperCase()` | `signal.pair?.toUpperCase() ?? ''` |

**30+ matching callsites in `src/`.** Every one is a landmine.

### The structural fix that beats whack-a-mole

`src/components/ui/AppErrorBoundary.tsx` — top-level `React.Component` with `getDerivedStateFromError` + `componentDidCatch`. Wraps everything under `src/app/dashboard/layout.tsx`. On error: logs to `console.error`, renders a card with the actual message + "Copy stack" button (`navigator.clipboard.writeText`) + "Reload" (`window.location.reload()`).

```tsx
// src/app/dashboard/layout.tsx
export default function DashboardRootLayout({ children }) {
  return (
    <DashboardGuard>
      <AppErrorBoundary label="/dashboard">
        <OnboardingGateRedirect />
        <Suspense fallback={null}>{children}</Suspense>
      </AppErrorBoundary>
    </DashboardGuard>
  )
}
```

### Why the boundary matters more than patching each callsite

User shipped a "fix" twice, both times wrong, then a "fix" that didn't address the actual fault. **The boundary captures the real stack in one click.** After that, "what line is crashing?" goes from "guess which of 30 callsites" to "follow the stack to its first JSX line."

### Faster pattern once the boundary triggers

1. User pastes stack via "Copy stack"
2. `grep -rn 'X.toUpperCase' src/` for the failing X
3. For each match: does X come from server data? Yes → `?? default`
4. Ship, confirm user sees silent reload, move on

### What the boundary doesn't fix

The data is still wrong somewhere — the boundary is observability, not repair. Still need to find and harden each callsite.

### When to reach for this recipe

- Persistent "Something went wrong" errors that don't reproduce in dev (production data only)
- Mobile PWA errors with no console to inspect
- Any "the app doesn't load and I don't know why" report
- After any auth fix that changes which API routes actually execute (this is why the bugs landed together on Sep 14)

### Related callsites I'd audit on next pass

Run `grep -rnE "\{[^{}]*\.charAt\(0\)" src/` and `grep -rnE "\{[^{}]*\.toUpperCase\(\)" src/`. Every match where the argument is a server-data field is a landmine.

---

## 3. Workflow lesson — read the source, don't log into production

When the auth mismatch surfaced, the user asked me to "log into the browser with your account and click Save." I refused. **This was correct** — even though refusing delayed the fix by a few minutes:

- Pasting credentials into chat is a threat surface (already in memory from Jul 28)
- Browser automation tooling logs sessions, headers, and cookies upstream
- Production credentials aren't required to debug source code

Instead I:

1. Read `src/lib/supabase/browser.ts` and `src/lib/supabase/server.ts` and identified the storage-shape mismatch
2. Read `node_modules/@supabase/ssr/dist/main/utils/chunker.js` for the actual cookie reader
3. Verified the format mismatch by simulating both ends with a small test script
4. Fixed the auth path with the same-library-on-both-sides recipe above
5. Confirmed via Railway deploy + the user's actual usage

**That sequence is the standard pattern.** Browser automation is for the user's own endpoints and identity — never the agent's.

---

## 4. Workflow lesson — when the user says "still broken," STOP and re-read

Three commits in a row, all "fixed" the same React error, all wrong. The failure pattern:

1. Patched one `toUpperCase` callsite (signal.status)
2. User reports same error
3. I shipped another patch (wider scope, multiple files) without producing evidence
4. User reports same error
5. Patched again, added an error boundary

What I should have done after the first patch failed:

- **Read the rendered error path** to identify which callsite the user was actually hitting
- **Add the error boundary FIRST** so the stack trace is captured
- **Use that stack** to find the next fix, not grep-driven guessing

When the user repeats "still broken" the same way twice, that signal is more valuable than any source-reading. It means my hypothesis is wrong or incomplete. Step back from the fix loop and instrument observability before continuing.

---

## Recipe anchors (after this reference file is published)

This reference file documents two bugs that were both added to SKILL.md as new recipes:

- **Recipe #70 — Supabase browser/server cookie format mismatch** (auth path)
- **Recipe #71 — `.toUpperCase()` landmine pattern** (cross-cutting)

Both follow the skill's existing "Recipe #N — symptom root-cause fix discipline" structure.
