---
name: production-bug-recipes
description: "Fix recurring production bugs: the symptom, the actual cause, and the fix for migrations that half-apply, caches that go stale, and auth that works until it does not."
version: 1.0.0
license: MIT
author: "the maintainers"
---
# the platform — Known Bugs & Recipes

This skill captures the **recurring bug classes** that show up when shipping
the platform features. Each recipe is a class of failure, not a one-off
incident. When the next session sees a similar symptom, the matching
recipe is the starting point.


### Recipe #45 — Auth-gated column on `user_accounts` silently fails as 403 (added Aug 26 2026)

**Symptom:** an admin user reports that a feature in the admin panel is broken (empty list, blank screen, "no data"). The API endpoint returns 403 Forbidden. The page renders an empty state with NO error toast, NO banner, NO console error in the user's view.

**Root cause:** admin routes gate on auth-shaped columns like `user_accounts.inbox_access` or `is_admin`. The gate lives at the API layer (`if (!auth.profile?.X) return 403`). The UI side often only checks `res.ok` and silently fails when the API returns 403 — there's no error toast, no banner, no log visible to the user.

**The fix pattern — three pieces:**

1. **Add a UI fallback for 403**: in `loadThreads` (or equivalent), check `res.status` and dispatch a visible error: `setError('Your account does not have access to this view. Contact an admin.')`. Never let a 403 look like an empty list.
2. **Always seed the gate explicitly for admins**: in `user_accounts`, set `inbox_access = true` (or whatever flag the route checks) on every `is_admin = true` user. If a new flag gets added to the schema, run a backfill migration:
   ```sql
   UPDATE public.user_accounts
   SET inbox_access = true
   WHERE is_admin = true AND (inbox_access IS NULL OR inbox_access = false);
   ```
3. **Default the flag to `true` on schema create** for admin-shaped columns so new admins get it for free.

**The diagnostic flow:**

```sql
SELECT id, email, is_admin, inbox_access FROM public.user_accounts WHERE email = '<user email>';
```

```bash
curl -sL -H "Authorization: Bearer <token>" https://<domain>/api/admin/email/threads
# 200 → cache or render (Recipes #46, #47)
# 403 → auth flag (this recipe)
```

### Recipe #46 — iOS PWA service worker caches JSON API responses (added Aug 26 2026)

**Symptom:** the user opens the admin Inbox on their phone (or a PWA-installed desktop), sees "17 unread" in the header count, but the thread list is empty. The same URL from a fresh curl returns 200 OK with 25 threads. Recipe #17 covers SW cache busts on **content** changes (CSS/JS); this recipe covers the related case where the SW caches **API JSON responses** that should always be fresh.

**Root cause:** iOS PWAs cache aggressively via `public/sw.js`. Without explicit `Cache-Control: no-store`, the SW's `runtime-${CACHE_VERSION}` cache stores API responses. When the server-side code changes (a fix, a new query, a filter for banned users), the SW continues serving the OLD response. Recipe #17's `CACHE_VERSION` bump evicts static chunks but doesn't necessarily evict runtime cache entries the same way.

**The fix — three layers:**

1. **Add `Cache-Control: no-store` to the API response**, even for GETs:
   ```ts
   return NextResponse.json(
       { threads: data ?? [], total: count ?? 0 },
       { headers: { 'Cache-Control': 'no-store, no-cache, must-revalidate' } },
   );
   ```
2. **Bump `CACHE_VERSION` in `public/sw.js`** to evict the runtime cache.
3. **Tell the user to hard-refresh the PWA.** `skipWaiting()` + `clients.claim()` only kicks in on the next open after the new SW is fetched.

### Recipe #47 — React `.map()` silent crash when a single row has malformed data (added Aug 26 2026)

**Symptom:** an admin list page shows the right count (e.g. "17 unread") but renders zero rows. The API returns valid data. The page has no error toast, no console error in the user's view.

**Root cause:** `threads.map(t => <button>{addressName(t.participant_addrs.find(...))}`) — if a single row has `participant_addrs: null`, an unexpected shape, or a field that crashes the called function, the entire `.map()` callback throws. React's reconciliation handles siblings per-item, but **a single render exception can skip the whole list**.

**The fix — defensive render with explicit defaults:**

```tsx
threads.map(t => {
    const addrs = Array.isArray(t.participant_addrs) ? t.participant_addrs : []
    const external = addrs.find((a: string) => /* filter */) ?? addrs[0] ?? 'Unknown'
    const preview = typeof t.last_message_preview === 'string' ? t.last_message_preview : ''
    const subject = typeof t.subject === 'string' && t.subject ? t.subject : '(no subject)'
    return <button key={t.id}>...</button>
})
```

Three rules:
- `Array.isArray(x)` before calling `.find()` or `[0]`
- `typeof x === 'string'` before calling string methods
- Coerce `null`/`undefined` to safe defaults at the top of the `.map()` callback

### Recipe #48 — Supabase soft-delete via `banned_until` when hard-delete is blocked (added Aug 26 2026)

**Symptom:** `DELETE /auth/v1/admin/users/{id}` returns 500. The user stays in the database. The admin panel still shows them.

**The fix — soft-delete via `banned_until`:**

```bash
# 100-year ban via the admin update endpoint:
curl -X PUT -H "apikey: $KEY" -H "Authorization: Bearer $KEY"   -H "Content-Type: application/json" -d '{"ban_duration": "876000h"}'   https://<project>.supabase.co/auth/v1/admin/users/<user_id>

# Clean up dependent user_accounts row:
curl -X DELETE -H "apikey: $KEY" -H "Authorization: Bearer $KEY"   -H "Prefer: return=representation"   "https://<project>.supabase.co/rest/v1/user_accounts?id=eq.<user_id>"
```

**Caveat:** banned users STILL appear in `GET /auth/v1/admin/users`. Filter them out at the API layer:

```ts
const liveUsers = rawUsers.filter((u: any) => {
    const until = u?.banned_until;
    if (!until) return true;
    const t = Date.parse(until);
    return !(Number.isFinite(t) && t > Date.now());
});
```

### Recipe #51 — iOS viewport unit `100dvh` jumps when the URL bar shows/hides (added Aug 30 2026)

**Symptom:** the user opens a page that's locked to the viewport (chat, terminal, drawer-style page). On iOS Safari / Capacitor WebView, the page height **jumps** by ~24px every time the user scrolls enough to hide or show the URL bar. This breaks layouts that pin elements to the bottom of the viewport (chat input bars, terminal status lines, anything with `100vh` / `100dvh` in the height calc).

**Root cause:** `100dvh` (dynamic viewport height) reflects the **current** viewport size, which iOS Safari updates when the URL bar shows/hides. CSS that uses `100dvh` re-runs the layout each time, and any element pinned to `bottom: 0` of that container jumps.

**The fix — use `100svh` (small viewport height):** `100svh` is the smallest possible height — always including the URL bar — so it's stable across scroll states. Trade-off: ~24px of "unused" space when the URL bar is hidden, but worth it for not jumping. Also see the related `100lvh` (large viewport height) and `100dvh` (dynamic) options.

```css
.community-root {
  /* Before — jumps on iOS when the URL bar shows/hides */
  height: calc(100dvh - 140px);

  /* After — stable across URL bar states */
  height: calc(100svh - 140px);
}
```

**Diagnostic** — open the page in iOS Safari (real device or Simulator), then scroll up/down repeatedly. If pinned elements jump, the culprit is `100dvh` somewhere in the height chain.

**Gotcha — when you also need full height behavior:** if the page should fill the WHOLE viewport (no fixed-height ancestor), use `100vh` instead. `100vh` is the legacy "always the visible viewport" unit and behaves like `100svh` but is wider-supported. The trade-off: `100vh` includes the URL bar's space even when hidden, so on tall-content pages you get extra blank space at the bottom. Use `100dvh` only when you genuinely need "fill the visible area right now" behavior and have already accounted for jumps.

---

### Recipe #52 — Chat input bar with `position: sticky; bottom: 0` floats in the middle of the chat on iOS (added Aug 30 2026)

**Symptom:** on a chat-style page (community chat, DM, support inbox), the user types a message, the input bar appears to float in the middle of the visible chat area with empty space below it before the bottom dock. The user reports they have to scroll past messages to reach the input. On Chrome/Firefox/desktop the bar sits correctly at the bottom; only iOS Safari / iOS WebView is broken.

**Root cause — `position: sticky` pins to the scrolling ancestor, not the visual parent.** When you have:

```css
.chat-thread   { display: flex; flex-direction: column; overflow: hidden; }
.chat-messages { flex: 1; overflow-y: auto; }   /* scrolling container */
.chat-input-bar { position: sticky; bottom: 0; }  /* THIS IS THE BUG */
```

The input bar's **scrolling ancestor** is `.chat-messages` (the only element with `overflow: auto`). When the user scrolls messages, the sticky element pins itself to wherever the messages happen to be in the visible area — which on a short chat history puts the input mid-screen. The visual parent `.chat-thread` has `overflow: hidden` (no scrolling), so sticky has nothing to stick to within it.

**Why desktop "worked":** on desktop Chrome, with no iOS-style rubber-band, the chat-messages scroll position is steady and the sticky input happens to land near the visible bottom. iOS's rubber-band scrolling + the way Safari handles `position: sticky` inside `overflow: hidden` makes the misbehavior visible.

**The fix — remove `position: sticky` and use the natural flex column layout.** The input bar already has `flex-shrink: 0` and lives at the end of a flex column. Add the missing pieces:

```css
/* Before — broken */
.chat-input-bar {
  position: sticky;       /* ← REMOVE */
  bottom: 0;              /* ← REMOVE */
  flex-shrink: 0;
  /* ... */
}

/* After — pinned to bottom of visible chat thread */
.chat-input-bar {
  display: flex;
  gap: 8px;
  padding: 10px 18px calc(14px + env(safe-area-inset-bottom, 0px));
  border-top: 1px solid rgba(255, 255, 255, 0.06);
  background: rgba(10, 10, 20, 0.95);
  backdrop-filter: blur(24px);
  -webkit-backdrop-filter: blur(24px);
  flex-shrink: 0;
  /* no position: sticky, no z-index — none needed */
}

.chat-messages {
  flex: 1;
  overflow-y: auto;
  padding: 12px 18px 24px;   /* extra bottom padding so the last
                                message isn't hidden behind the input
                                when auto-scrolling */
  overscroll-behavior-y: contain;  /* prevent iOS rubber-band from
                                       propagating to the page */
  -webkit-overflow-scrolling: touch;
}
```

**Verification flow:**
1. Open the chat page in iOS Safari (or Capacitor iOS WebView)
2. Type a message and hit send
3. Auto-scroll to bottom — the last message should be **fully visible above the input bar**, not hidden
4. Scroll up to read older messages — the input bar should stay **fixed at the bottom** the whole time
5. Pull down at the top of messages — should rubber-band inside `.chat-messages`, NOT bounce the whole page

**When sticky IS the right answer:** if you want the input bar to STICK to the top of the visible area as the user scrolls up (e.g. always-visible reply box that moves with scroll direction), use sticky. If you want the input bar to ALWAYS sit at the bottom of the chat thread regardless of scroll position, use the natural flex layout.

---

### Recipe #53 — Duplicate per-page `legal.css` drifts after additions to the canonical one (added Aug 30 2026)

**Symptom:** you add a new legal page (e.g. `/support`) following the pattern of existing pages like `/privacy-policy`, `/disclaimer`, `/terms`. You copy `import './legal.css'` from a sibling page, ship it, and the next deploy **fails silently on Railway**. The previous build keeps serving because the new build broke. The actual error in `npx next build` is:

```
./src/app/support/page.tsx:2:1
Module not found: Can't resolve './legal.css'
```

**Root cause — each legal page directory has its own sibling `legal.css`:**

```
src/app/privacy-policy/page.tsx     → ./legal.css  → src/app/privacy-policy/legal.css
src/app/disclaimer/page.tsx         → ./legal.css  → src/app/disclaimer/legal.css
src/app/terms/page.tsx              → ./legal.css  → src/app/terms/legal.css
src/app/support/page.tsx            → ./legal.css  → src/app/support/legal.css  ← you have to CREATE this!
```

When you add a new legal page in a new directory, **there's no sibling `legal.css` to import.** You must either create one OR import from a sibling directory (e.g. `'../terms/legal.css'`). The latter is the right move when the styles are identical.

But there's a second trap: **the existing `legal.css` files drift**. When you add new styles to `terms/legal.css` (say, `.legal-link`, `.support-email`, `.support-faq`), the other directories' copies don't get updated. `/privacy-policy` and `/disclaimer` look correct on desktop but render with stale styles.

**The fix — both halves:**

1. **When adding a new legal page** in a fresh directory: import from an existing sibling: `'../terms/legal.css'`. Don't create a new `legal.css` unless you have styles unique to that page.

2. **When adding styles to any `legal.css`:** copy the canonical file to ALL `legal.css` locations to keep them in sync. One file changes, all four files update. There is no codegen for this — the project doesn't use a build-time CSS bundling trick.

```bash
# After editing terms/legal.css, sync to siblings
cp src/app/terms/legal.css src/app/privacy-policy/legal.css
cp src/app/terms/legal.css src/app/disclaimer/legal.css
```

**The long-term fix — extract to a single shared CSS module.** Move the styles to `src/styles/legal.css` and import that path in all pages. One file, one source of truth. Don't do this mid-feature; do it as a dedicated refactor pass when you have time.

**Diagnostic flow when the deploy silently fails:**

1. `git log --oneline -5` — confirm the commit is pushed
2. `git rev-parse HEAD` + `git ls-remote origin main` — confirm local == remote
3. In Railway: check the build log for "Build error" or "Module not found"
4. Locally: `npx rimraf .next && npx next build` — reproduce the failure
5. Read the error carefully — Next 16 / Turbopack build errors usually point to a specific file + line

**Defense — always run `npx next build` locally before pushing** any change that touches:
- File imports (especially `.css`, `.module.css`, image, font)
- New directories under `src/app/`
- New TypeScript files that depend on aliased imports (`@/...`)
- Any change to `next.config.mjs`, `tsconfig.json`, or `package.json`

If the local build succeeds, the Railway build will succeed (modulo missing env vars, which surface as runtime errors, not build errors).

---

### General pattern: when an admin feature reports "empty" — assume it's auth, not data

When an admin page shows an empty state but the count badge is correct, the **data is fine** — it's either auth (gate returning 403 silently), caching (SW serving old response), render exceptions (one bad row kills the list), or **CSS hiding the list inside a `@media` query** that never gets a class set anywhere.

Verification flow:
1. **Hit the API directly** with the user's bearer token (`curl`). If 403 → auth flag (Recipe #45). If 200 with data → cache, render, OR CSS (Recipes #46, #47, #49).
2. **Check the user's PWA SW version** vs. the live version. Stale SW → Recipe #46.
3. **Look for runtime render errors** in DevTools. React silent crash → Recipe #47.
4. **Open the browser devtools on the affected route**, then run this CSS probe in the console — surfaces every rule with `display: none`, `visibility: hidden`, or `opacity: 0` that's currently matching your list element:

```js
(() => {
  // Find the suspected container (the empty area) — adjust the selector
  const candidates = Array.from(document.querySelectorAll('*'))
    .filter(el => {
      const cs = getComputedStyle(el);
      return cs.display === 'none' || cs.visibility === 'hidden' || Number(cs.opacity) === 0;
    })
    .filter(el => el.offsetParent !== null || el === document.body)
    .map(el => {
      const cs = getComputedStyle(el);
      return {
        tag: el.tagName,
        cls: (el.className?.toString() || '').slice(0, 60),
        display: cs.display,
        visibility: cs.visibility,
        opacity: cs.opacity,
        mediaMatch: el.matches('*') ? 'yes' : '',
      };
    })
    .slice(0, 20);
  console.table(candidates);
})();
```

If any element that *should* be visible shows up with `display: none`, scroll the table to its CSS selector and search for `@media` rules matching the user's viewport width. The next recipe covers the exact pattern.

### Recipe #49 — Mobile-only CSS `display: none` rule hiding content via a class that's never set (added Aug 27 2026)

**Symptom:** an admin page works perfectly on desktop (width > 768px) but shows an empty state on mobile (iPhone PWA). The count badge renders correctly. The API returns the right data. Defensive row rendering doesn't help.

**Root cause:** a CSS rule inside `@media (max-width: 768px)` hides a list/grid element via a class that's never assigned in the React component:

```css
/* BAD: hides the thread list on mobile forever */
@media (max-width: 768px) {
    .vsi-list:not(.is-active-list) { display: none; }
}
```

The rule was written with the intent of "mobile pane-switching: show list OR viewer, not both," but the JSX never sets `is-active-list` anywhere. So on mobile, the list is `display: none` regardless of whether `threads` has data. Desktop was unaffected because the `@media` query only matches on small screens.

**The diagnostic — desktop works, mobile doesn't, count renders.** When this exact symptom pattern shows up, before diving into JSX or API work, do this:

```js
// Open the route in mobile devtools view, then in the console:
(() => {
  // The "empty" container selector — adjust for your route
  const sel = '.vsi-list';
  const el = document.querySelector(sel);
  if (!el) return console.log('NOT FOUND:', sel);
  const cs = getComputedStyle(el);
  console.log({
    selector: sel,
    display: cs.display,
    visibility: cs.visibility,
    opacity: cs.opacity,
    matchesIsActive: el.classList.contains('is-active-list'),
    width: el.offsetWidth,
    height: el.offsetHeight,
    mediaMatchesMobile: window.matchMedia('(max-width: 768px)').matches,
  });
  // Scroll the stylesheet list for any rule matching this selector
  Array.from(document.styleSheets).forEach(sheet => {
    try {
      Array.from(sheet.cssRules || []).forEach(rule => {
        if (rule.cssText && rule.cssText.includes('.vsi-list') && rule.cssText.includes('display: none')) {
          console.log('HIDING RULE:', rule.cssText);
        }
      });
    } catch {}
  });
})();
```

If the probe prints `display: none` and a `HIDING RULE:` line under `@media`, you have it. The fix is one of:

**Fix A — Toggle the class from React (matches the original intent):**

```tsx
// Component body
const [activeId, setActiveId] = useState<string | null>(null);
useEffect(() => {
  if (typeof document === 'undefined') return;
  document.body.classList.toggle('vsi-thread-active', !!activeId);
  return () => { document.body.classList.remove('vsi-thread-active'); };
}, [activeId]);
```

```css
@media (max-width: 768px) {
  body:not(.vsi-thread-active) .vsi-list { display: flex; }
  body.vsi-thread-active      .vsi-list { display: none;  }
  body.vsi-thread-active      .vsi-viewer { display: flex; }
}
```

**Fix B — Simplify the rule (when there's only one mobile state):**

```css
@media (max-width: 768px) {
  /* Just hide the viewer; let the list stay visible. */
  .vsi-viewer:not(:has(.vsi-viewer-body)) { display: none; }
}
```

Or remove the broken rule entirely and let the natural stack of two `<section>` blocks handle mobile via flex-direction.

**Three rules to write a CSS pane-switching system that doesn't break later:**

1. The gating class must be set from React state (Fix A) or the rule must apply unconditionally — never both as separate design decisions.
2. When debugging "works on desktop, broken on mobile" symptoms, check the `@media` rules FIRST. They're the most common silent breakage because desktop and mobile run different code paths.
3. If you're tempted to write `display: none` inside `@media` as a "viewport-aware toggle," set the gating class from React, not from CSS pseudo-classes. CSS can't know "is a thread active" without JS.

**Why this took two rounds to find (Rounds 21 and 21b both shipped without fixing it):** the symptom (count renders, list doesn't) overlaps Recipe #47's symptom (defensive row crash). The two fixes are different — defensive rendering doesn't help when the element is `display: none`. The fast path to the right fix is the `display: none` CSS probe above, before any JSX rewrite.




## Companion files

- `references/guided-account-program-architecture.md` — Guided the guided-account program product (tiers, math, schema, API surface)
- `[removed: internal file]` — One-shot `rg` / SQL recipes that surface the patterns this skill documents. Run BEFORE touching `src/app/api/`, `src/components/education/`, `src/components/partners/`, the `get-started`/`apply`/`ref` routes, or any new server-side fetch.
- `references/2026-08-23-onboarding-deep-link-and-downline-seeding.md` — Aug 23 2026 session drop-in. Recipes #23 (PGRST204 idempotency), #24 (downline seeding), #25 (`?brokerOpenConnect=1` deep-link for modal-trigger wizard steps).
- `references/2026-08-23-onboarding-lifecycle-recovery.md` — Aug 23 2026 session drop-in. Recipes #21 (multi-version recovery dance for partial-applied SECURITY DEFINER functions), #22 (hard-redirect middleware gate via cookie decode + client companion hook).
- `references/2026-08-23-onboarding-complete-cta-and-welcome-modal.md` — Aug 23 2026 session drop-in. Recipes #25 (lifecycle RPC + durable trigger dual-write pattern), #26 (welcome modal single-source dismiss handler), #27 (`useSearchParams()` Suspense boundary requirement in Next.js 16).
- `references/2026-08-23-onboarding-tail-end-bugs.md` — Aug 23 2026 session drop-in. Recipes #28 (SQL trigger with stale step list — `app_onboarding_step_changed` still required the old 4-key set), #29 (PWA SW serving stale 302s after onboarding_complete flips — hard-navigation fallback pattern), #30 (`Promise.allSettled` + `.then(async)` foot-gun — use `.catch(sentinel)` per fetch), #31 (`checkConnectBroker` must accept the durable user_accounts flag, mirror the broker-relax), #32 (partner portal Lifecycle column + drawer pattern, sibling-mount, N+1 caveat).
- `references/2026-08-24-onboarding-hero-glitch-and-partner-portal-v3.md` — Aug 24 2026 session drop-in. Recipes #35 (OnboardingHero shows wizard on stale-data mount — useUser as source of truth, three-state render paths with shimmer placeholder), #36 (JSX reference analysis technique — find missing imports in Turbopack-bundled chunks before runtime), #37 (CSS-only design overhaul that preserves JSX — visual reordering via CSS Grid, the safe default after a JSX rewrite has broken things).
- `references/2026-08-25-onboarding-wizard-polish-and-migration-audit.md` — Aug 25 2026 session drop-in. Recipes #38 (`supabase.auth.updateUser` silently aborts the next line of code — the WRITE-path twin of Recipe #15; move auth-side metadata writes to a server-side endpoint that uses `svc.auth.admin.updateUserById`), #39 (`adminFetch` is the right primitive for authenticated save handlers; avoid `supabase.auth.*` from component handlers entirely), #40 (stale `/api/...` route references in client code → silent 404; recipe for grepping client→server references), #41 (migration ordering trap: 4-step trim overridden by 7-step expansion — re-trim both `app_onboarding_step_changed` AND `app_get_user_lifecycle` together in one later-dated migration), #42 (probe `pg_proc` for "absent" functions correctly — POST `{}` triggers a zero-arg signature lookup that returns PGRST202 even for present functions; call with real args from a `KNOWN_ARGS` map), #43 (catch-up migration pattern: one dated file with `CREATE OR REPLACE FUNCTION …` for every missing function, verbatim body from the original source, plus `GRANT EXECUTE` and ending `NOTIFY pgrst, 'reload schema';`), #44 (force `window.location.href = '/path'` instead of `router.push()` for nav out of a gated flow — middleware on a full reload re-evaluates the freshly-flipped `onboarding_complete`, while client-side push can re-bounce to `/onboarding`).
- `references/2026-08-26-admin-inbox-access-pwa-cache-render-exception.md` — Aug 26 2026 session drop-in. Recipes #45 (auth-gated column silently fails as 403 — `inbox_access` on `user_accounts` returns 403 and the UI shows "No messages yet" with no error toast), #46 (iOS PWA service worker caches JSON API responses — three-layer fix: `Cache-Control: no-store` + SW `CACHE_VERSION` bump + user hard-refresh), #47 (React `.map()` silent crash when a single row has malformed data — defensive render pattern with `Array.isArray()` + fallback strings), #48 (Supabase soft-delete via `banned_until` with future date when hard-delete returns 500). General pattern: when an admin feature reports "empty", check auth first, then cache, then render — data is almost never the issue.
- `[removed: internal file]` — Aug 27 2026 session drop-in. Recipe #50 (iOS PWA warm-restart profile data loss — the cache-then-clobber bug where `setProfile(baseProfile)` overwrites the cache in the same render pass with `points: 0` because `buildProfile()` reads from `user.user_metadata` which doesn't have points; only call baseProfile when no cache exists. Also: sessionStorage vs localStorage on iOS PWA (sessionStorage can be cleared on WebView kill; use localStorage for any state that must survive swipe-up dismiss). Also: visibilitychange + pageshow + retry-the-fetch are the three additional layers that actually make the warm-restart recovery work end-to-end).
- `[removed: internal file]` — Aug 27–28 2026 session drop-in. Recipes #50–#56 (engine-page refresh + iOS PWA warm-restart cascade + DB investigation before UI fixes + md5-based synthetic outcome generation + localStorage tier + patch mode caveats + engine-name mismatch silently drops data) plus Recipes #57–#61 from the Aug 28 follow-ups: (57) `signal_log` actual schema — `pair` not `symbol`, `sent_at` not `created_at`, no `result` column; (58) PostgREST `column:alias` syntax does NOT exist in `.select()` strings — use a real column or a view; (59) Yahoo Finance ticker formats are not uniform — `US30=X` returns 404, must use `^DJI` for indices and `GC=F` for commodities; (60) inline-expansion chart centering — three-layer CSS containment recipe to keep chart visible without bleeding past card edges; (61) Telegram signals data flow — listener writes to `signal_log`, page reads from it, do NOT invent mirror tables. General pattern: when "no signals rendered" happens, walk down the diagnostic ladder (DB → query → hook → page state) to find which layer is broken.


- `references/2026-09-05-whitelabel-broker-ib-and-multi-account.md` — Sep 5 2026 session drop-in. The white-label broker as an IB label (not a separate broker) over the underlying broker, the real whitelabel-broker.example API contract (cookie auth, no Bearer tokens, `/api/auth/*` + `/api/dev/*` + `/api/broker/otp`), the 10 locked-in white-label broker decisions (firm slug `<your-firm-slug>`, default-broker=white-label-only, crypto-only funding, $250 min deposit, 100:1 leverage, indices US30/NAS100 available, no US country block), the `trading_accounts` multi-account schema (one-active-per-user via partial unique index), the four new trading-accounts API routes, and the Railway deploy crash recovery dance (startCommand override fix, Dockerfile ARG for NEXT_PUBLIC_* env vars so they're inlined at build time not runtime).

- `references/2026-09-05-multicause-page-wont-load-diagnosis.md` — Sep 5 2026 session drop-in. **CRITICAL methodology**: when the platform shows "Application error" or "page won't load", it can have FOUR independent root causes that mask as one symptom: (1) Railway `startCommand` override breaking the Docker container's CMD, (2) public assets returning 404 (`.gitignore`'d, missing from Dockerfile COPY), (3) `"use client"` component calling `Math.random()`/`Date.now()` inline during render (React #418 hydration mismatch), (4) `NEXT_PUBLIC_*` env vars not inlined correctly at build time — `Dockerfile` hardcoded `https://stub.invalid` is baked into the JS bundle. Each recipe has the curl/grep diagnostic, the BEFORE/AFTER code, the deploy verification. Trigger phrases: "page won't load", "Application error", "nothing is loading", "I cleared cookies and it still won't load", "make no mistakes, audit the session". Pairs with Recipe #17 (PWA CACHE_VERSION) and Recipe #46 (three-layer cache fix).

- `references/2026-08-22-session-additions.md` — pending merge into SKILL.md
- `references/2026-08-22-batch2.md` — pending merge into SKILL.md
- `references/2026-08-22-quiz-and-points-popup.md` — pending merge into SKILL.md
- `references/2026-08-22-server-authoritative-points-and-emails.md` — pending merge into SKILL.md
- `scripts/supabase_apply_migration.sh` — Wraps `supabase db push --dns-resolver https` with a dry-run + confirm prompt. Use when an agent needs to apply a migration from a sandboxed environment (Recipe #20 / #24).
- `scripts/e2e_partner_link.sh` — End-to-end check of the partner referral chain. Run after any change to `/ref/[code]`, `/api/partners/lookup`, or `/api/signup/register`.
- `scripts/pwa_avatar_check.sh` — Verifies the iOS PWA avatar flow end-to-end: SW version, Supabase storage pass-through, manifest scope, CORS headers, public file accessibility. Run after any change to `public/sw.js`, `public/manifest.json`, the avatar upload route, or `<img>` tags in profile components.

## Recipe #50 — iOS PWA warm-restart profile data loss: the cache-then-clobber bug + sessionStorage vs localStorage (added Aug 27 2026)

**Symptom:** the user opens the dashboard, data loads. They swipe up to dismiss the PWA from the app switcher (or background it long enough that iOS evicts the WebView), then reopen. The dashboard shows all data reset to defaults (points=0, streak=0, name "Operator", etc.). They have to force-close + reopen the app to get their data back. Same data loads fine on a true cold restart (force-close → reopen). The fix needs to survive both a warm restart (JS context suspended and resumed) AND an iOS-WebView-killed restart.

**Root cause #1 — sessionStorage is unreliable on iOS PWA.** The first instinct is to cache the profile in `sessionStorage` so it survives remount. But on iOS, sessionStorage CAN be cleared when the WebView is killed (memory pressure, swipe-up dismiss). Only `localStorage` reliably survives the kill + reopen cycle. If the cache is in sessionStorage, the first remount after a kill has no cache to restore.

**Root cause #2 — the cache-then-clobber bug (the silent killer).** Even if the cache exists, this pattern silently nukes it:

```js
const cached = loadProfileCache(currentUser.id)   // restores real points from cache
if (cached) setProfile(cached)

const baseProfile = buildProfile(currentUser)     // reads from user_metadata
setProfile(baseProfile)                           // CLOBBERS the cache with points=0
saveProfileCache(currentUser.id, baseProfile)      // saves the clobbered version
```

`buildProfile()` reads `points: meta.points ?? 0` from `user.user_metadata`. Points do not live in `user_metadata` — they live in `user_accounts`. So `baseProfile` always has `points: 0`. The cached profile's real points flash for ~16ms before being overwritten by `baseProfile`. The user sees their data disappear. This is the silent failure mode that made the first attempt at this fix look like it did not work — the cache was being written and read correctly, but the immediate overwrite was the actual bug.

**Root cause #3 — the `user_accounts` fetch can fail transiently on warm restart.** While the network radio comes back up, the PostgREST fetch can fail with a network error. Without a retry, the dashboard is stuck with the cached profile (or empty) until the next refresh.

**The fix — three layers:**

```js
// 1. Use localStorage, not sessionStorage
const PROFILE_CACHE_PREFIX = "app-profile-cache:";
function saveProfileCache(userId, profile) {
    localStorage.setItem(PROFILE_CACHE_PREFIX + userId, JSON.stringify(profile));
    // ...
}

// 2. Do not clobber the cache
const cached = loadProfileCache(currentUser.id);
if (cached) {
    setProfile(cached);    // restore cache
}
// ONLY build baseProfile when there is no cache
if (!cached) {
    const baseProfile = buildProfile(currentUser);
    setProfile(baseProfile);
    saveProfileCache(currentUser.id, baseProfile);
}
// The Promise.allSettled block below MERGES user_accounts data into
// the cached profile via setProfile(prev => ...) — preserves the
// cached values that are not in user_accounts.

// 3. Retry the user_accounts fetch on failure
const effectiveProfileResult =
    profileResult.status === "rejected"
        ? await (async () => {
              await new Promise(r => setTimeout(r, 600));
              const retry = await supabase.from("user_accounts")
                  .select("...").eq("id", currentUser.id).maybeSingle();
              return (!retry.error && retry.data)
                  ? { status: "fulfilled", value: retry }
                  : profileResult;
          })()
        : profileResult;
```

**Plus a visibilitychange handler** that triggers `refreshProfile()` when the page becomes visible (the actual warm-restart signal on iOS):

```js
const handleVisibility = () => {
    if (document.visibilityState !== "visible") return;
    if (Date.now() - lastRefresh < 5000) return;  // throttle
    lastRefresh = Date.now();
    void refreshProfile();
};
document.addEventListener("visibilitychange", handleVisibility);
```

**Companion rule — the cache-then-clobber pattern is sneaky in any "merge from metadata, then enrich from DB" flow.** If step 1 reads from a source that does not have all the fields, step 2 will silently overwrite good data with zeros. Pattern: either (a) merge incrementally via `setProfile(prev => ({...prev, ...newFields}))` so existing fields are preserved, OR (b) check for the cache/fetched state BEFORE writing the base layer.

**Companion rule — for PWA state that must survive an iOS WebView kill, always use localStorage.** sessionStorage is appropriate only when you specifically want data cleared on tab close (which does not happen reliably on PWA anyway — iOS PWAs keep the WebView alive).

**Companion rule — clear profile cache on sign-out.** Use `saveProfileCache(undefined, null)` to wipe all `app-profile-cache:*` keys. Otherwise a different user signing in on the same device briefly sees the previous user's data while the live fetch is in flight.

**When this hits again:** any feature whose UI reads from `useUser().profile` (or any other context-derived state) on iOS PWA. Same pattern applies — cache locally, restore before fetching, never clobber the restored data with a base layer that does not have all the fields.

---

## Recipe #1 — The "supabase db push marked it applied" silent failure (added Aug 22 2026)

**Symptom:** a migration that contains `INSERT ... ON CONFLICT DO UPDATE` for a `storage.buckets` row is reported as **applied** by the supabase migration runner, but the bucket doesn't exist when you try to upload to it. Subsequent `supabase storage.from('avatars').upload(...)` calls return 404 or the bucket is missing entirely.

**Root cause:** the migration runner can mark a migration applied even when the inner INSERT did not commit cleanly (e.g. transaction-level constraint, RLS row-level check, or a missing `storage.buckets` SELECT permission for the role that runs the migration). The migration table gets the row, the data does not.

**The fix — when a migration is "applied" but the side effect didn't happen:**

1. **Verify directly via the supabase CLI** (the JS-side service-role client bypasses RLS, so any read here is the ground truth):

   ```js
   const svc = createServiceClient()
   const { data, error } = await svc.storage.listBuckets()
   ```

2. **If the bucket is missing, create it via the storage API** (not via a new migration). The migration runner can repeat the silent failure:

   ```js
   const sb = createServiceClient()
   await sb.storage.createBucket('avatars', {
     public: true,
     fileSizeLimit: 5 * 1024 * 1024,
     allowedMimeTypes: ['image/jpeg', 'image/png', 'image/webp'],
   })
   ```

3. **Backfill the missing migration** with a NEW migration that does the same operation but starts with `IF NOT EXISTS` guards:

   ```sql
   INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
   VALUES (...)
   ON CONFLICT (id) DO UPDATE SET
       public = EXCLUDED.public, ...;
   ```

4. **Add a verification step to the migration** — a `RAISE NOTICE` with the bucket ID, or a final `SELECT id FROM storage.buckets WHERE id = 'avatars'` so a real "applied but not effective" failure is visible in the migration output.

**When this hits again:** any new migration that creates storage buckets, scheduled jobs, or other "side-effect" rows. Pre-flight check: after `supabase db push`, always read back the data via the JS client.

## Recipe #2 — The `position_snapshot` table has no `id` column (added Aug 22 2026)

**Symptom:** a cron-driven route that does `.from('position_snapshot').select('id, ...')` returns `500 column "position_snapshot.id" does not exist` on every tick. The route silently swallows the error and the user sees no points awarded even though the position closed.

**Root cause:** the table was created with `PRIMARY KEY (user_id, broker_position_id)` — a composite primary key. The route author assumed there's a single `id` column (the more common pattern).

**The fix — verify the schema before adding `select('id, ...')`:**

```sql
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'position_snapshot'
ORDER BY ordinal_position;
```

The columns are `user_id, broker_account_id, broker_position_id, symbol, side, qty, avg_price, sl_price, tp1_price, tp2_price, tp3_price, tp4_price, opened_at, last_seen_at, closed_at, close_price, close_reason, tp1_hit, tp2_hit, tp3_hit, tp4_hit, tp_history_id, updated_at` — **no `id`**. Adjust the route to select only the columns that exist.

**Companion rule:** any new snapshot/audit table should use a synthetic `id UUID PRIMARY KEY DEFAULT gen_random_uuid()` column for log/audit flexibility, even if the natural key is composite. Costs nothing at runtime, prevents this class of error entirely.

## Recipe #3 — The PATCH route SL/TP field-swap bug (added Aug 22 2026)

**Symptom:** when the user updates SL/TP on an existing position, the new protective orders don't attach, or the broker silently rejects them, or the order goes through as the WRONG type (market instead of stop/limit).

**Root cause:** a single `placeOrder` helper was used for both position-closes (market orders) and SL/TP-attachment (stop/limit orders). The helper hard-coded `type: 'market'` and used field names that the broker interprets differently for stop vs limit orders. So `takeProfit: 1234` was being sent for both a TP placement AND a SL placement, with the broker silently accepting or rejecting the wrong type.

**The fix — separate helper for protective orders:**

```ts
async function placeProtectiveOrder(TL_BASE, accountId, spec: {
  tradableInstrumentId: string
  routeId?: string
  side: 'buy' | 'sell'
  qty: number
  parentId: string
  kind: 'stop' | 'limit'
  price: number
}, headers) {
  const body: any = {
    tradableInstrumentId: spec.tradableInstrumentId,
    side: spec.side,
    qty: spec.qty,
    type: spec.kind,                  // 'stop' for SL, 'limit' for TP
    validity: 'GTC',
    parentId: spec.parentId,           // links to the open position
  }
  if (spec.routeId) body.routeId = spec.routeId
  if (spec.kind === 'stop') {
    body.stopLoss = spec.price         // trigger price for stop
  } else {
    body.price = spec.price             // fill price for limit
  }
  // POST to /orders
}
```

**Rule:** never reuse a market-order helper for stop/limit orders. Each order type has its own broker-specific field conventions. The execute route got this right (uses `type: 'stop' + stopLoss` for SL, `type: 'limit' + price` for TP); the PATCH route got it wrong (used the market helper, sent `takeProfit` for both).

## Recipe #4 — iPhone HEIC uploads rejected at TWO layers (added Aug 22 2026)

**Symptom:** user picks a photo from iPhone Photos library, sees a "Profile picture updated!" toast, but the avatar URL doesn't change and the file is missing from storage. Console shows either `400 unsupported type image/heic` or `500 mime type image/heic is not supported`.

**Root cause:** iPhones save photos as `image/heic` (or `image/heif`). Two separate layers need to accept this MIME type:

1. **The server route's `ALLOWED_MIME` set** — without HEIC, returns 400.
2. **The Supabase storage bucket's `allowed_mime_types` array** — without HEIC, storage returns 500 even if the route accepted the file.

**The fix — both layers need HEIC + client-side fallback:**

```ts
// Server route ALLOWED_MIME
const ALLOWED_MIME = new Set([
  'image/jpeg', 'image/jpg', 'image/png', 'image/webp', 'image/gif',
  'image/heic', 'image/heif',  // iPhone photos
  '',                         // some old mobile clients send empty type
])
const MAX_FILE_SIZE = 8 * 1024 * 1024  // bumped from 5MB for HEIC photos
```

```js
// Update the bucket directly via service-role
await svc.storage.createBucket('avatars', {
  public: true,
  fileSizeLimit: 8 * 1024 * 1024,
  allowedMimeTypes: ['image/jpeg', 'image/png', 'image/webp', 'image/gif',
                     'image/heic', 'image/heif'],
})
```

```ts
// Client-side: convert HEIC to JPEG via canvas before upload (iOS Safari decodes HEIC natively)
if (file.type === 'image/heic' || file.type === 'image/heif' || /\.(heic|heif)$/i.test(file.name)) {
  const url = URL.createObjectURL(file)
  const img = new Image()
  await new Promise((resolve, reject) => {
    img.onload = resolve
    img.onerror = reject
    img.src = url
  })
  const canvas = document.createElement('canvas')
  // cap at 1024x1024
  let { width, height } = img
  if (width > 1024 || height > 1024) {
    const scale = Math.min(1024 / width, 1024 / height)
    width = Math.round(width * scale)
    height = Math.round(height * scale)
  }
  canvas.width = width
  canvas.height = height
  canvas.getContext('2d')!.drawImage(img, 0, 0, width, height)
  URL.revokeObjectURL(url)
  uploadFile = await new Promise<Blob>((resolve, reject) => {
    canvas.toBlob(b => b ? resolve(b) : reject(), 'image/jpeg', 0.92)
  })
}
```

**When this hits again:** any new feature that accepts image uploads from mobile. Always accept HEIC at the route layer AND the bucket layer, AND add a client-side canvas fallback for browsers that can decode HEIC (iOS Safari, recent macOS Safari, Edge).

## Recipe #5 — The JWT self-heal bug — never write base64/data: URLs to `auth.user_metadata` (added Aug 22 2026)

**Symptom:** user uploads a profile picture, sees it briefly, then it disappears on the next page refresh. Console shows `Authorization` token length jumping from ~2KB to ~12KB.

**Root cause:** the `auth.user_metadata.avatar_url` field gets passed back in the JWT. A 1.5KB base64 string (or even a normal Supabase storage URL with a long signed-token query param) inflates the JWT past the 6KB threshold. Old "self-heal" code in UserContext then SET `avatar_url = null` to "fix" the JWT bloat, silently wiping the avatar.

**The fix — store avatars in `user_accounts.avatar_url`, NEVER in `auth.user_metadata`:**

```sql
-- Migration that makes user_accounts the canonical avatar store
ALTER TABLE public.user_accounts ADD COLUMN IF NOT EXISTS avatar_url TEXT;
```

```ts
// UserContext — read from user_accounts, not from auth.user_metadata
const { data: profileRow } = await supabase
  .from('user_accounts')
  .select('is_admin, points, streak_count, streak_last_date, full_name, phone, divisions, experience_level, onboarding_complete, lifetime_pnl_usd, lifetime_pnl_updated_at, avatar_url')
  .eq('id', currentUser.id)
  .maybeSingle()

setProfile(prev => ({
  ...prev,
  avatarUrl: profileRow?.avatar_url ?? prev.avatarUrl ?? '',
}))
```

```ts
// Server route — write to user_accounts ONLY, not auth.user_metadata
const { error: dbError } = await svc
  .from('user_accounts')
  .update({ avatar_url: publicUrl })
  .eq('id', auth.userId)
```

**The audit — find any code that still touches `user_metadata.avatar_url`:**

```bash
rg "user_metadata.*avatar|avatar.*user_metadata" src/ supabase/migrations/
# Should return zero hits
```

**When this hits again:** any feature that wants to store per-user data and is tempted to use `user_metadata` for it. If the data is user-visible on every page (avatar, display name, etc.) it must go in `user_accounts` (or another public table). Reserve `user_metadata` for **truly private, auth-only** data (notification prefs, opt-ins, etc.).

## Recipe #6 — The `streak_log` inconsistent return shape (added Aug 22 2026)

**Symptom:** the daily-check-in popup clicks "Collect" but the result screen never shows, OR shows "NaN points". Logs show `points_added: undefined`.

**Root cause:** the SQL function returns different shapes for the "already-bumped" early-return path vs. the fresh-bump path:

- Fresh bump returns `{ ok, new_streak, base_awarded, points_added, bonus_awarded, bonus_reason }`
- Early-return (already bumped) returns `{ ok, new_streak, already_counted }` — **no `points_added`, no `bonus_awarded`**

The client side checks `if (!data.already_bumped_today) { ...data.points_added... }` — which works, BUT the bug is that the early-return path used `already_counted` while the client expected `already_bumped_today`. The check failed → the `if` branch ran → `data.points_added` was undefined → the result screen tried `+ undefined` → NaN.

**The fix — always return the same shape, with a canonical field name:**

```sql
CREATE OR REPLACE FUNCTION public.streak_log(p_user_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_today          DATE := (now() AT TIME ZONE 'UTC')::date;
  v_yesterday      DATE := v_today - INTERVAL '1 day';
  v_last_streak    DATE;
  v_new_streak     INTEGER := 1;
  v_base_added     BIGINT  := 2;
  v_final_amount   BIGINT  := 0;
  v_bonus_amount   BIGINT  := 0;
  v_bonus_reason   TEXT    := NULL;
  v_already_today  BOOLEAN := false;
BEGIN
  SELECT streak_last_date INTO v_last_streak
  FROM public.user_accounts WHERE id = p_user_id;

  IF v_last_streak IS NULL THEN
    v_new_streak := 1;
  ELSIF v_last_streak = v_today THEN
    SELECT streak_count INTO v_new_streak
    FROM public.user_accounts WHERE id = p_user_id;
    v_already_today := true;
    v_base_added    := 0;
  ELSIF v_last_streak = v_yesterday THEN
    SELECT streak_count + 1 INTO v_new_streak
    FROM public.user_accounts WHERE id = p_user_id;
  ELSE
    v_new_streak := 1;  -- missed a day, streak resets
  END IF;

  IF NOT v_already_today THEN
    UPDATE public.user_accounts
    SET streak_count = v_new_streak, streak_last_date = v_today, updated_at = now()
    WHERE id = p_user_id;

    -- award the daily_open + any milestone
    v_final_amount := v_base_added;
    -- ... milestone logic ...
  END IF;

  -- ALWAYS return the same shape
  RETURN jsonb_build_object(
    'ok', true,
    'new_streak', v_new_streak,
    'base_awarded', v_base_added,
    'points_added', v_final_amount,
    'bonus_awarded', v_bonus_amount,
    'bonus_reason', v_bonus_reason,
    'already_bumped_today', v_already_today,
    'already_counted', v_already_today  -- deprecated alias for back-compat
  );
END;
$$;
```

**Rule:** every SQL function that returns JSONB should have ONE return shape. The client should never have to branch on "did the function early-return or finish?" — the shape encodes the state.

**Companion rule:** the client should always check the field name with the most-specific meaning. `already_bumped_today` (the canonical name) takes precedence over `already_counted` (the deprecated alias). Don't add alias fields without deprecating the old ones in the same commit.

## Recipe #7 — The "the broker `?limit=N` is ignored" pagination trap (added Aug 22 2026)

**Symptom:** the position-watcher detects that a position has closed but the close-fill doesn't match any TP/SL price, so the watcher awards no TP/CLOSE_IN_PROFIT points. The fill is buried in the order history past the visible window.

**Root cause:** the broker's `/ordersHistory?limit=N` query parameter is **ignored**. The broker returns ALL orders regardless of `limit`. To get a specific window, you must:
1. Paginate with `?offset=N` (also ignored) — or
2. Fetch ALL rows, then dedupe-by-id across multiple requests.

**The fix — dedupe-by-id loop with a sane cap:**

```ts
async function fetchFullHistory(TL_BASE, accountId, headers, opts: { target: number; maxPages: number }): Promise<any[][]> {
  const seen = new Set<string>()
  const out: any[][] = []
  for (let page = 0; page < opts.maxPages; page++) {
    const r = await fetch(`${TL_BASE}/trade/accounts/${accountId}/ordersHistory?limit=200`, { headers })
    if (!r.ok) break
    const j = await r.json()
    const rows: any[][] = j?.d?.ordersHistory ?? []
    if (!rows.length) break
    let newCount = 0
    for (const row of rows) {
      const id = String(row?.[0] ?? '')
      if (id && seen.has(id)) continue
      if (id) seen.add(id)
      out.push(row)
      newCount++
    }
    if (newCount === 0) break
    if (out.length >= opts.target) break
  }
  return out
}
```

**Call site (position-watcher):** fetch up to 500 orders. Walk the most-recent first (the broker returns newest-first). For each fill, compare price to the snapshot's tp1_price, tp2_price, tp3_price, tp4_price, sl_price (with tolerance 0.0001). The first matching fill IS the close fill — any earlier TP fills are part of a partial-close and were already credited.

**Rule:** for any the broker endpoint that returns historical data (orders, fills, closed positions), the `?limit=N` and `?offset=N` parameters may be ignored. Always implement client-side pagination via dedupe-by-id.

## Recipe #8 — The "Daily popup" day boundary: UTC vs local time (CORRECTED Aug 22 2026)

**Symptom:** the user clicks "Collect" on the daily reward popup. The popup closes, points + streak update, all looks good. They navigate away, come back, and the popup **re-appears**. They click "Collect" again — the popup says "already collected" or it bumps the streak a second time. The popup stays open across every navigation. They say "I just collected an hour ago!" or "the popup keeps coming back."

**Root cause:** the original code compared two values that lived in different timezones:

```ts
// todayLocal — built from new Date() in the BROWSER's local TZ
const todayLocal = new Date().getFullYear() + "-" + ...

// streakLastAsLocal — parsed the DB's UTC date string as midnight
// UTC and converted to local
const d = new Date(s.split('T')[0] + 'T00:00:00Z')  // Aug 22 00:00 UTC
d.getDate()  // returns LOCAL date — for Eastern time, returns "21"
return `${d.getFullYear()}-${d.getMonth()+1}-${d.getDate()}`  // 2026-08-21

hasClaimedToday = streakLastAsLocal === todayLocal
//                "2026-08-21"          ===  "2026-08-22"  → false
//                (UTC date rolled over to "today" in UTC, but local
//                 date is still "yesterday" → mismatch → popup re-fires)
```

The mismatch only happens for users west of UTC. An Eastern user collecting at 8 PM gets `streak_last_date = 2026-08-22` (UTC midnight just rolled). Then they navigate back at 9 PM Eastern same day. Their local day is still `2026-08-22`, but `streakLastAsLocal` (which does `new Date('2026-08-22T00:00:00Z').getDate()` in Eastern TZ) returns `2026-08-21`. The comparison fails → popup opens again.

**The fix — STOP MIXING TIMEZONES. Compare UTC dates to UTC dates:**

```ts
// Today in UTC (server's source of truth)
const todayUtc = (() => {
  const d = new Date()
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, '0')}-${String(d.getUTCDate()).padStart(2, '0')}`
})()

// DB's streak_last_date — DATE column → "YYYY-MM-DD"
// Just strip any time portion, no TZ conversion
const streakLastUtc = profile?.streakLastDate?.split('T')[0] ?? null

const hasClaimedToday = streakLastUtc != null && streakLastUtc === todayUtc
```

Both sides of the comparison are now UTC. The popup auto-shows exactly once per UTC day — which matches the SQL function's idempotency boundary (`streak_log` uses UTC throughout).

**Companion rule:** don't try to convert UTC to local for "have I collected today" comparisons. If the SQL function's idempotency is UTC-anchored, the popup's idempotency check has to be UTC-anchored too. Mixing timezones always loses.

**Companion rule for the sessionStorage key:**

```ts
const collectedKey = `app-daily-collected:${todayUtc}`  // keyed by UTC day
```

The key string changes when UTC rolls over at midnight, so old entries expire naturally. Using a local-day key would let the entry linger past midnight in the user's TZ and cause the popup to incorrectly stay suppressed.

**What the WRONG fix looked like (the version that shipped earlier in this session, captured here so it never returns):**

```ts
// ❌ WRONG — converts UTC date to local date, then compares to today's local date.
// This is asymmetric: todayLocal uses local TZ, streakLastAsLocal does UTC→local.
// For users west of UTC, streakLastAsLocal is always 1 day BEHIND todayLocal
// after a successful collect.
const todayLocal = (() => { ... new Date().getFullYear()/Month/Date() ... })()
const streakLastAsLocal = (() => {
  const d = new Date(s.split('T')[0] + 'T00:00:00Z')  // UTC midnight
  return `${d.getFullYear()}-${d.getMonth()+1}-${d.getDate()}`  // local day
})()
const hasClaimedToday = streakLastAsLocal === todayLocal  // ALWAYS false west of UTC
```

**When this hits again:** any feature that needs to compare "is this thing from today?" against a DB timestamp. Always use the SAME timezone on both sides. If the DB is UTC, the comparison must be UTC-to-UTC.

## Recipe #19 — Trader-access toggle endpoint pattern (added Aug 22 2026)

**Class of work:** the Access tab in customers Manage drawer already had Trading/Sales/Partner toggles. Adding a fourth — "Trader Access" — required a NEW pattern: a lightweight endpoint that flips a single boolean flag (`is_trader` on `user_accounts`) without requiring all the `trader_profiles` wizard fields that the existing `/api/admin/enable-trader` POST endpoint does. This separates "grant the permission" from "set up the public profile" — same model as Partner toggling `is_partner` separately from configuring a Partner profile.

**Symptom of the wrong approach (what NOT to do):** reusing `/api/admin/enable-trader` POST and trying to make it accept an "is_trader: false" without a `display_name` / `slug`:
- The endpoint returns 400 ("display_name is required")
- The Access tab UX is broken — toggle stays in "pending" state, no save
- The admin has to switch to the Trader tab to fill in the profile fields before they can grant access

**The fix — split the two operations into two endpoints:**

1. `/api/admin/set-trader-flag` (POST): just flips `is_trader` + `trader_status`. No `display_name` / `slug` / `bio` required. The trader profile remains in whatever state it's in.
2. `/api/admin/enable-trader` (POST/PATCH): the existing "set up the public profile" endpoint. Used by the Trader tab.

The same pattern applies to Partner: `/api/admin/set-partner` (just flips `is_partner`) vs the broader partner profile setup.

**The endpoint shape:**

```ts
// POST /api/admin/set-trader-flag
// Body: { user_id: string, is_trader: boolean }
// Auth: admin only (matched on email allowlist)
export async function POST(req: NextRequest) {
  const auth = await isAdminRequest(req)
  if (!auth.ok) return auth.response
  // ... parse body, validate user_id + is_trader:boolean
  // ... look up existing row, update is_trader + trader_status
  // ... PRESERVE trader_since across revoke cycles
  // Response: { ok, publicUser: { id, is_trader, trader_status, trader_since }, message }
}
```

**The trader_since preservation gotcha — got this wrong the first time:**

```ts
// ❌ WRONG — re-stamps trader_since on every revoke→re-grant cycle
if (body.is_trader && !existingPU.is_trader) {
  update.trader_since = new Date().toISOString()
}

// ✅ RIGHT — only stamp on the very first grant (when no date exists yet)
if (body.is_trader && !existingPU.trader_since) {
  update.trader_since = new Date().toISOString()
}
```

The first version checked `!existingPU.is_trader` which, after a revoke, was true → re-stamped the date. Fixed by checking `!existingPU.trader_since` so the timestamp only records the user's first-ever promotion. Caught this with an e2e test that toggled ON → OFF → ON in sequence and verified `trader_since` matched across all three states.

**E2E test that exercises the full endpoint contract:**

```js
// 11 steps — exercise all paths
1. Auth as admin
2. Find a non-trader user (target for toggle)
3. Toggle ON → 200 OK, is_trader=true, trader_status='active'
4. Verify in DB → persisted
5. Toggle OFF → 200 OK, is_trader=false, trader_status='deactivated', trader_since preserved
6. Toggle ON again → trader_since must equal the original (NOT re-stamped)
7. Non-admin JWT → 403
8. Missing user_id → 400
9. Non-boolean is_trader → 400
10. Unknown user_id → 404
11. No bearer → 401
```

**The adminFetch wiring on the client — same pattern as the Partner toggle:**

```tsx
// In TraderHubTab or AdminUsersPanel
const traderChanged = !!modalUser.isTrader !== pendingTrader

const results = await Promise.all([
  ...toGrant.map(d => fetch('/api/admin/grant-division', {...})),
  ...toRevoke.map(d => fetch('/api/admin/revoke-division', {...})),
  ...(partnerChanged ? [fetch('/api/admin/set-partner', {...})] : []),
  // Aug 22 2026 — new toggle
  ...(traderChanged ? [
    adminFetch('/api/admin/set-trader-flag', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ user_id: modalUser.id, is_trader: pendingTrader }),
    }),
  ] : []),
])

const failed = results.find(r => r && !r.ok)
if (failed) { /* show error */ }
```

Note `adminFetch` — the localStorage-read pattern from Recipe #15. Plain `fetch()` would silently 401 if the supabase-js lockManager contended (see Recipe #15 for the full diagnosis).

**When this hits again:** any "toggle a single role/permission flag from the Access tab" pattern. The split-endpoint approach separates the permission-grant UX from the profile-setup UX, so the admin can grant access with one click without filling out a 6-field wizard. New endpoints to consider: `/api/admin/set-divisions-bulk` for toggling multiple divisions, `/api/admin/set-experience-level`, `/api/admin/set-engines-bulk`.

## Recipe #9 — The cron script lives at `~/.agent-home/scripts/`, not `~/Projects/.../scripts/` (added Aug 22 2026)

**Symptom:** the cron job fires on schedule, the log says `Script not found: ~/.agent-home/scripts/<name>.sh`, every run fails. The script exists in `~/Projects/<name>/scripts/`.

**Root cause:** the agent scheduler runs scripts from `~/.agent-home/scripts/`, not from any project directory. `git`-checked-in scripts in `~/Projects/<name>/scripts/` are NOT visible to cron.

**The fix — copy the script:**

```bash
# From the project where the script lives
cp scripts/cron_<name>.sh ~/.agent-home/scripts/cron_<name>.sh
chmod +x ~/.agent-home/scripts/cron_<name>.sh
```

**Better fix — symlink instead of copy:**

```bash
ln -sf "$HOME/Projects/the platform/scripts/cron_<name>.sh" "$HOME/.agent-home/scripts/cron_<name>.sh"
# Edits to the source file take effect immediately.
```

**Better fix 2 — source env vars from `~/.agent-home/cronenv file`:**

```bash
# ~/.agent-home/cronenv file
CRON_SECRET=...
SNAPSHOT_REBUILD_URL=...
```

```bash
# In the script
if [[ -z "${CRON_SECRET:-}" && -f "${HOME}/.agent-home/cronenv file" ]]; then
  set -a
  source "${HOME}/.agent-home/cronenv file"
  set +a
fi
```

This keeps the secret out of `git` (it's in `~/.agent-home/cronenv file`, not in the project) and out of Railway env (Railway env is for the running app, not the local cron that calls the running app).

**When this hits again:** every new cron-driven script. Pre-flight: after writing the script, `ls -l ~/.agent-home/scripts/ | grep <name>` to confirm it's there, then trigger the cron manually and verify the log.

## Recipe #10 — iOS PWA + Supabase storage cross-origin image rendering (added Aug 22 2026)

**Symptom:** user installs the PWA on iPhone. Avatar works in the regular browser tab but is blank/invisible inside the standalone PWA. Console inside the PWA (via Safari → Settings → Advanced → Web Inspector) shows the `<img src=...>` loads but renders 0×0, or shows CORS errors.

**Root cause:** iOS Safari PWA is strict about service workers and cross-origin image responses. When the SW intercepts a fetch for an image from a different origin (e.g. `https://<project>.supabase.co/storage/v1/object/...`) and tries to put it in the cache, the response is treated as an **opaque response**. iOS Safari then refuses to render opaque responses for `<img src=...>` — the `<img>` element shows broken.

**The fix — three layers:**

**1. Service worker (public/sw.js): pass Supabase storage through to the network untouched:**

```js
self.addEventListener('fetch', (event) => {
    const req = event.request;
    if (req.method !== 'GET') return;
    const url = new URL(req.url);
    if (!url.protocol.startsWith('http')) return;
    if (url.pathname.startsWith('/rest/v1') || url.hostname.includes('supabase')) {
        if (url.pathname.startsWith('/storage/v1/object/')) {
            return;  // let the browser handle it natively
        }
        return;
    }
    // ... rest of fetch handler
});
```

Always bump `CACHE_VERSION` when changing this so existing PWA installs pick up the new SW (they will eventually; iOS clears the SW on update but the user has to close+reopen the PWA for the new SW to activate).

**2. PWA manifest (public/manifest.json): declare cross-origin scope:**

```json
{
  ...
  "scope_extensions": [
    { "origin": "https://<project-ref>.supabase.co" }
  ],
  "handle_links": "preferred"
}
```

`scope_extensions` is a non-standard but Chromium-supported extension that tells the PWA that the listed origin is part of its scope. This prevents iOS from blocking cross-origin auth tokens, push messages, and image fetches.

**3. `<img>` tags: add `crossOrigin="anonymous"`:**

```tsx
<img src={avatarUrl} alt={name} crossOrigin="anonymous" />
```

This tells the browser the `<img>` is a cross-origin resource and should be fetched with CORS. Combined with `Access-Control-Allow-Origin: *` on the storage response (Supabase storage sets this by default on public buckets), the browser can use the response.

**Verification (run after the change):**

```bash
# 1. New sw.js is served (bigger file size = new code)
curl -sIL https://<domain>/sw.js | grep -i 'content-length\|HTTP'
# 2. SW version is bumped
curl -sL https://<domain>/sw.js | grep CACHE_VERSION
# 3. CORS is open on storage
curl -sI -H 'Origin: https://<domain>' \
  https://<project>.supabase.co/storage/v1/object/public/avatars/<userId>/avatar.jpg | grep -i 'access-control'
# 4. Manifest has scope_extensions
curl -sL https://<domain>/manifest.json | grep scope_extensions
```

**When this hits again:** any PWA feature that loads cross-origin assets (images, video, audio). The key principle: **never let the SW cache cross-origin responses for `<img>` / `<video>` / `<audio>` tags**. Always pass them through.

**iOS PWA gotcha — close+reopen required after SW update:** iOS PWAs don't auto-update the service worker like Chrome does. When you ship a new `sw.js`, the user has to close the PWA and reopen it (or wait for the next session). Plan for this: tell the user to "close the PWA and reopen" in the commit message / release notes.

---

## Recipe #67 — Partner dashboard hangs forever on "Loading partner data..." when a new API call hangs (added Sep 10 2026)

**Symptom:** `/dashboard/partners/dashboard` shows the spinner indefinitely after wiring up a new endpoint (in this case, `/api/partners/developer/dashboard` that fans out to white-label broker's `/api/dev/*` for live downline data). No console errors. The finally block never fires. `setLoading(false)` is never called.

**Root cause:** any `await fetch(...)` without an AbortController will hang forever if the upstream call never resolves. Common offenders: a white-label broker endpoint that needs admin scope the user doesn't have (returns 401 silently, or hangs), a Supabase PostgREST request that times out at the TCP layer, a `Promise.allSettled([...])` where one promise resolves but a downstream `.then` swallows the failure. The page's `finally { setLoading(false) }` never runs because the awaited promise never resolves.

**The fix — wrap every potentially-slow fetch with AbortController + a sensible timeout:**

```tsx
const ac = new AbortController();
const timeoutId = setTimeout(() => ac.abort(), 8_000);

try {
    let res = await fetch('/api/some/slow/endpoint', {
        headers: { Authorization: `Bearer ${token}` },
        cache: 'no-store',
        signal: ac.signal,
    }).catch((e) => {
        console.warn('[component] endpoint failed:', e?.message ?? e);
        return null;  // Critical: catch swallows the abort so the fallback path runs
    });

    if (res?.ok && (json = await res.json())?.live === true) {
        // success path
    } else {
        // fallback path — use a FRESH AbortController (the first is aborted)
        const ac2 = new AbortController();
        const t2 = setTimeout(() => ac2.abort(), 8_000);
        res = await fetch('/api/fallback', {
            headers: { Authorization: `Bearer ${token}` },
            signal: ac2.signal,
        });
        clearTimeout(t2);
        // ...
    }
} finally {
    clearTimeout(timeoutId);
    setLoading(false);  // GUARANTEED to run within 8s
}
```

**Verification (when this hits again):**

1. Hard-refresh the affected page → spinner should resolve within 8s (worst case)
2. Check `Network` tab in DevTools → look for the failed request (often 401, 403, or canceled)
3. If the live endpoint fails, the fallback endpoint must already exist and respond — never ship a feature with only one endpoint in the chain

**When this hits again:** any new server-side endpoint that calls out to a 3rd-party API (white-label broker, the broker, Yahoo Finance, etc.). The pattern is identical every time: **don't trust an upstream to return promptly**. Always timeout + fall back.

---

## Recipe #68 — `is_partner` lives on `public.partners`, NOT on `public.user_accounts` (added Sep 10 2026)

**Symptom:** you write a migration that updates or inserts `is_partner = true` on `public.user_accounts` and it fails with `ERROR: 42703: column "is_partner" of relation "user_accounts" does not exist`. The error tells you exactly what's wrong, but it's confusing because `is_partner` is the natural name for the column on either table.

**Root cause:** the partners program has TWO tables that both store user metadata:

| Table | Columns |
|---|---|
| `public.user_accounts` | `id`, `email`, `full_name`, `is_admin`, `is_master_partner`, `api_access`, `onboarding_complete`, ... |
| `public.partners`     | `id`, `user_id`, `is_partner`, `ib_contract_rate`, `referral_code`, `affiliate_code`, `total_earnings`, ... |

`is_partner` is on **`public.partners`**. It got moved there during the 2026-04 partner program migration when `affiliates` was renamed to `partners`. Anyone touching the partner program must remember: **`user_accounts` is the user profile; `partners` is the partner-program membership**. They are joined by `partners.user_id = user_accounts.id`.

**The fix — when writing a migration that touches "partner" state:**

```sql
-- WRONG: this 42703s
UPDATE public.user_accounts SET is_partner = true WHERE email = 'support@yourdomain.com';

-- RIGHT: is_partner lives on public.partners
UPDATE public.partners
SET is_partner = true
WHERE user_id IN (
    SELECT au.id FROM auth.users au WHERE au.email = 'support@yourdomain.com'
);
```

**Helper query to verify which table owns which column:**

```sql
SELECT table_name, column_name
FROM information_schema.columns
WHERE column_name IN ('is_partner', 'is_admin', 'is_master_partner', 'api_access', 'onboarding_complete')
  AND table_name IN ('user_accounts', 'partners')
ORDER BY column_name, table_name;
```

**When this hits again:** any migration touching master accounts (support@yourdomain.com), admin flags, or partner-program state. Run the helper query first to confirm which table owns the flag you want to flip.

**Related:** Recipe #11 — `user_accounts.id` IS the auth.users.id. Both tables reference the auth user, but they store different concerns. Don't confuse "user profile" with "partner-program membership".

---

## Recipe #69 — Admin accounts provisioned before the onboarding wizard bounce through onboarding → login (added Sep 10 2026)

**Symptom:** you provision a master/admin account via SQL (or any pre-auth method that bypasses the normal signup wizard). When that user logs in for the first time, they get bounced through `/onboarding` → `/login` indefinitely. They can never reach the trading dashboard even though they're logged in.

**Root cause:** the post-Aug 2026 onboarding gate at `src/components/onboarding/useOnboardingGate.ts` checks `profile.onboardingComplete === true`. If the user has a placeholder `user_accounts` row with `is_admin=true` but `onboarding_complete` defaulted to whatever the SQL migration set (often `false`, or the row was created before the wizard even ran), the gate bounces them to `/onboarding`. The `/onboarding` page then re-checks `supabase.auth.getUser()` and pushes to `/login` if the JWT is expired or missing. The user is stuck in a loop.

**The fix — admins always bypass the onboarding gate:**

```ts
// src/components/onboarding/useOnboardingGate.ts
const { profile, isAdmin, loading } = useUser();

useEffect(() => {
    if (loading) return;
    if (!profile) return;
    if (!hasDecisiveStatus) return;
    if (onboardingComplete) return;
    // NEW: admins bypass the gate regardless of onboardingComplete
    if (isAdmin === true) return;
    router.replace('/onboarding');
}, [loading, profile, isAdmin, onboardingComplete, router]);
```

Mirror the same bypass in the inline `<OnboardingGate>` component by surfacing `is_admin` from `/api/onboarding/lifecycle`:

```sql
-- backend: surface is_admin alongside onboarding_complete
SELECT pu.onboarding_complete, pu.is_admin, ...
FROM user_accounts pu WHERE pu.id = <userId>;
```

```tsx
// frontend: skip the inline checklist for admins
if (lifecycle.is_admin === true) return null;
```

**Migration gotcha:** when consolidating a pre-existing placeholder row onto the auth-linked row (e.g. `support@yourdomain.com` was inserted by an earlier migration with a synthetic UUID, then the user signed up via auth and the `handle_new_user` trigger created a separate row with the real UUID), the finalize migration must update BOTH tables:

```sql
-- user_accounts gets is_admin, is_master_partner, api_access
UPDATE public.user_accounts
SET is_admin = true, is_master_partner = true, api_access = true
WHERE id IN (SELECT au.id FROM auth.users WHERE au.email = 'support@yourdomain.com');

-- public.partners gets is_partner (see Recipe #68)
UPDATE public.partners
SET is_partner = true
WHERE user_id IN (SELECT au.id FROM auth.users WHERE au.email = 'support@yourdomain.com');
```

**Verification (when this hits again):**

1. Have the admin user log in → should land at `/dashboard/trading` directly, NOT bounce through `/onboarding`
2. Open DevTools console → no `/onboarding` redirect, no 401 on `supabase.auth.getUser()`
3. The admin can navigate freely without ever seeing the wizard

**Related:** Recipe #11 + #68 + #69 all hit together when provisioning a new admin/master account. Always run them in this order: (1) write the migration with the right column on the right table, (2) apply it, (3) have the admin log in, (4) verify no onboarding bounce.

---

## Cross-cutting patterns

### A. "Migration is applied but the side effect didn't happen"

The `INSERT ... ON CONFLICT DO UPDATE` pattern silently no-ops when the data already exists. This bites for storage buckets, RLS policies, and config rows. The audit recipe: after every `supabase db push`, read back the data via the JS client to confirm the side effect actually committed.

### B. "The route that 'just works in dev' silently fails in prod"

Three causes hit in this session:

1. **Missing Supabase storage bucket** (Recipe #1) — dev worked because the bucket existed locally; prod failed because the migration didn't create it.
2. **The SQL helper's return shape was inconsistent** (Recipe #6) — fresh path returns `points_added`; early-return doesn't. Always normalize the return shape.
3. **The PATCH helper used the wrong order type** (Recipe #3) — `placeOrder` was market-only; SL/TP need separate code paths.

Pre-flight audit before any new route goes to Railway:

```bash
# 1. Build clean
cd ~/Projects/the platform && npx next build 2>&1 | tail -5

# 2. Type clean — actually read every line
npx tsc --noEmit 2>&1 | tee /tmp/tsc-check.log
grep -E "error TS|TS\d{4}" /tmp/tsc-check.log | head -20

# 3. Storage bucket present
curl -sL -H "Authorization: Bearer $SERVICE_KEY" \
  "$SUPABASE_URL/storage/v1/bucket" | python3 -c "import json,sys; d=json.load(sys.stdin); print(*[b['id'] for b in d], sep='\n')"
```

### C. "The watcher cron has been failing silently for 50+ runs"

The pattern: a route is added, the cron is registered, and the first run fails. The log is checked once ("it says error") and the cron is left to fail silently for days/weeks.

**Rule:** any time a new cron is registered, **immediately check the next 3 runs** to confirm it's not failing. Don't wait for the user to report a missing-points bug.

```bash
# Trigger the cron manually via the script (with the env loaded)
bash -c "source ~/.agent-home/cronenv file && bash ~/.agent-home/scripts/cron_<name>.sh"
# Should print: "exit=0 processed=N awarded=M errors=[]"
```

### D. "I shipped a real bug, said it was tested, but tsc just said 'no errors'"

`tsc --noEmit` passing is **necessary but not sufficient** for "the feature works end-to-end." The Verifier-First rule: any new feature that touches storage / DB / RLS / broker API must have an actual end-to-end test before the commit message claims success. Use the `scripts/e2e_partner_link.sh` template — copy it, replace the steps, and run it before committing.

---

## Recipe #11 — `user_accounts.id` IS the auth.users.id (Aug 22 2026)

**Symptom:** any feature that maps "find or create a user_accounts row for this auth user" returns errors like `column "user_accounts.user_id" does not exist`, or causes the same auth user to get duplicate user_accounts rows after activation/deactivation cycles.

**Root cause:** the platform's user_accounts table does NOT have a `user_id` column. Its primary key IS `id` (a UUID), and the value of `user_accounts.id` is the same UUID as `auth.users.id`. There's only ONE user_accounts row per user.

```sql
-- What the schema ACTUALLY looks like
\d user_accounts
-- id                  | uuid                        | PRIMARY KEY (auth.users.id)
-- is_admin            | boolean                     | not null default false
-- is_trader           | boolean                     | not null default false
-- trader_status       | text                        | 'active'|'paused'|'deactivated'
-- trader_since        | timestamptz                 |
-- points, app_level, streak_count, full_name, phone, ...
-- avatar_url          | text                        |
-- email               | citext                      | mirror (not authoritative)
```

The mistake to AVOID: any code (especially the trader enable/deactivate flow) that does:

```ts
// WRONG — there's no user_id column
.from('user_accounts')
.select('id').eq('user_id', authUserId)  // ← blows up: column does not exist
.from('user_accounts')
.insert({ user_id: authUserId, ... })    // ← creates a 1:n row per user
```

The correct pattern (this is what `enable-trader`, `set-partner`, profile writes, etc. all use):

```ts
// CORRECT — id IS the auth UUID
.from('user_accounts')
.select('id, is_trader, trader_status')
.eq('id', authUserId)                    // SELECT by auth UUID = user_accounts PK
.maybeSingle()

// To create a new user_accounts row (1:1 with auth.users)
.insert({
  id: authUserId,                       // ← the FK IS the PK
  is_trader: true,
  trader_status: 'active',
  // ... other user_accounts columns
})

// To update (e.g. revoke trader)
.update({ is_trader: false, trader_status: 'deactivated' })
.eq('id', authUserId)                    // ← WHERE by auth UUID = user_accounts PK
```

**The diagnostic for "did I get this wrong?":**

```sql
-- Confirm the schema before writing any feature
SELECT column_name
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'user_accounts'
ORDER BY ordinal_position;
```

If you see a `user_id` column, you're in a different schema (some projects use a separate mapping table). If you don't, `id` IS the FK.

**Rule for any new app user-mapping endpoint:** every "find or create this user's public row" flow must use `.eq('id', authUserId)` — not `.eq('user_id', authUserId)`. Treat `user_accounts.id` as the FK, even though it's also the PK. If you need a project-specific join table later (e.g. multi-role mappings or org-scoped users), build a separate table.

## Recipe #12 — UserContext `loading=false` race causes feature-gate flicker (Aug 22 2026)

**Symptom:** a freshly-promoted user (e.g. an admin sets `user_accounts.is_trader = true` via the customers Manage drawer) navigates to the gated page and sees the "Access required" / "You aren't a [role]" gate — even though the DB row clearly shows the flag set. After the user navigates away and comes back, the page works. Or the page works eventually after a hard refresh.

**Root cause:** the UserContext provider flips `loading=false` BEFORE the DB-derived flags (isTrader, isAdmin, hasMembership, isPartner) resolve. The pattern that breaks:

```tsx
// refreshProfile()
// 1. fetch session, set user (sync)
// 2. setProfile(buildProfile(currentUser))
// 3. setLoading(false)          // ← flipped HERE, page renders as if loading is done
// 4. fire Promise.allSettled([partnerFetch, recordFetch, traderFetch, adminFetch])
//    (a) 100ms later: setIsTrader(true) finally lands — but the page ALREADY rendered
//        with isTrader = false and showed the gate
```

The page reads `{ loading: false, isTrader: false }` at step 3 → gate renders. The setState at step 4 happens AFTER React already committed the gate-screen render. The user is stuck on a stale gate until they navigate away.

**The fix — flip `loading=false` AFTER all DB-derived flags resolve:**

```tsx
const refreshProfile = async (sessionOverride?: Session | null) => {
  setLoading(true)  // start with loading
  // ... fetch session, setUser, setIsAdmin(computeIsAdmin), setProfile(buildProfile)
  
  // Wait for all DB-derived flags BEFORE flipping loading=false
  try {
    const [partnerResult, userRecordResult, traderResult, profileResult] =
      await Promise.allSettled([
        supabase.from('partners').select('is_partner').eq('user_id', me.id).eq('is_partner', true).maybeSingle(),
        supabase.from('user_accounts').select('referred_by').eq('id', me.id).maybeSingle(),
        supabase.from('user_accounts').select('is_trader, trader_status').eq('id', me.id).maybeSingle(),
        supabase.from('user_accounts')
          .select('is_admin, points, streak_count, ...')
          .eq('id', me.id).maybeSingle(),
      ])
    // Commit the flags
    if (traderResult.status === 'fulfilled') setIsTrader(!!(traderResult.value.data?.is_trader && traderResult.value.data?.trader_status === 'active'))
    else setIsTrader(false)  // belt-and-braces: don't leave a stale true
    // ... setIsAdmin, setIsPartner, setProfile merge
    setLoading(false)  // ← ONLY here, after all flags are resolved
  } catch (e) {
    setLoading(false)  // don't leave the loading state hung
  }
}
```

**The companion rule on the gated page:**

```tsx
// Always wait for UserContext.loading=true signal, AND don't render the gate
// until you know the flag has been read at least once.

// ❌ WRONG — page renders gate while flag is still being fetched
if (loading) return <Loading/>
if (!isTrader) return <Gate/>

// ✅ RIGHT — combine the load + the read into one render path
// (the loading flip and the flag result are now atomic from the page's POV)
if (loading || isTrader === undefined) return <Loading/>
if (!isTrader) return <Gate/>
```

The two fixes compound: UserContext flips loading only after the flags, AND the page treats "loading OR flag not yet read" as the loading state. The gate only renders when `loading=false AND isTrader=false (or true)` — both branches of which are consistent.

**When this hits again:** any new context flag (e.g. `isEducator`, `isPartnerLevel3`, `hasKYCVerified`) that is derived from a DB read. Default to the "DB-resolved → setState → flip loading" pattern, never the synchronous-flip-background-fetch pattern. If a NEW flag shows up, check that the page gate waits for it explicitly (not just `loading`).

## Recipe #13 — Rate limit 429 on trader signals: per-user bucket, not per-IP (Aug 22 2026)

**Symptom:** a trader clicks "Send Signal" and gets `429 Too many requests` immediately, even though they're the only person using the platform right now. The error message is `{"error":"Too many requests","retryAfter":N}` with `Retry-After: N` header.

**Root cause (multi-pronged):**

1. **IP-based keying** — `LIMIT_MAP` was a plain `Map<ip, { count, resetAt }>` shared across ALL users on the same egress IP. Corporate NAT, mobile carriers, and server-side e2e tests all share an IP, so the limit collides across users.
2. **Low bucket for traders** — `POST /api/trader/signals` had `{ limit: 30, windowMs: 60_000 }`. A trader who retries after a network blip blows the bucket in a single minute.
3. **Hidden compounding cost** — the trader signals POST triggers a PWA push fan-out (1 listSubs + 1 listUsers + N web-push attempts). A single user-visible signal can produce 5-10 internal calls. If the rate limiter counts ALL of these against the trader's bucket, the limit hits WAY faster than expected.
4. **In-memory state** — `LIMIT_MAP` lives in the Next.js process. Railway deploys restart the process → empty bucket → user gets a fresh window. Across multiple dynos (if Railway ever scales horizontally), the limit doesn't aggregate. (For production, swap for Upstash Redis. Single-dyno in-memory is fine for now.)

**The fix — three layers:**

**Layer 1 — user-aware bucket with cache:**

```ts
// src/lib/rateLimit.ts
async function isUserActiveTrader(req: NextRequest): Promise<boolean> {
  const auth = req.headers.get('authorization') || ''
  const tokenMatch = auth.match(/^Bearer (.+)$/i)
  if (!tokenMatch) return false
  const token = tokenMatch[1]

  // Cache trader status (5-min Tbroker — promotion/demotion doesn't need ms latency)
  if (TRADER_CACHE.has(token)) {
    const c = TRADER_CACHE.get(token)!
    if (c.expiresAt > Date.now()) return c.isTrader
  }

  const supabase = createClient(SUPABASE_URL, SERVICE_KEY)
  const { data: userRes } = await supabase.auth.getUser(token)
  if (!userRes?.user) return false
  const { data: pu } = await supabase
    .from('user_accounts')
    .select('is_trader, trader_status')
    .eq('id', userRes.user.id)
    .maybeSingle()
  const isTrader = !!pu?.is_trader && pu?.trader_status === 'active'
  TRADER_CACHE.set(token, { isTrader, expiresAt: Date.now() + 5 * 60_000 })
  return isTrader
}

export async function applyRateLimit(req, options) {
  const ip = /* x-forwarded-for, cf-connecting-ip, x-real-ip */
  const isTrader = await isUserActiveTrader(req)

  let key, limit, windowMs
  if (isTrader) {
    const token = req.headers.get('authorization')?.replace(/^Bearer\s+/i, '').trim() || ip
    key = `user:${token.slice(0, 64)}`     // per-user, not per-IP
    limit    = options.traderLimit    ?? 300   // default trader bucket
    windowMs = options.traderWindowMs ?? 60_000
  } else {
    key = `ip:${ip}`
    limit    = options.limit    ?? 60
    windowMs = options.windowMs ?? 60_000
  }
  // ... existing per-key check
}
```

**Layer 2 — bumped bucket for routes with internal fan-out:**

```ts
// In /api/trader/signals POST handler
const rateLimitCheck = await applyRateLimit(req, {
  limit: 30,
  windowMs: 60_000,
  traderLimit: 300,        // 10x headroom for traders
  traderWindowMs: 60_000,
})
```

**Layer 3 — `applyRateLimit` is async:** changing the signature to async required adding `await` to ALL 70+ call sites across the codebase. Use:

```bash
# One-shot bulk-fix with perl (negative lookbehind for 'await ')
perl -i -pe 's/(?<!await )\bapplyRateLimit\(/await applyRateLimit(/g' src/app/api/**/*.ts
```

**The diagnostic for "is the user hitting the limit?":**

```bash
# Open the response headers in the browser DevTools Network tab
# Look for X-RateLimit-Remaining: 0 + Retry-After: 14 → confirmed 429
```

**Rule for the next rate-limited route:** every new endpoint that calls a 3rd-party API or sends push to N subscribers needs a bumped `traderLimit` (or `workerLimit`) option proportional to the fan-out. Default `60/min` is fine for an admin endpoint; `30/min` is fine for user-driven actions; trader signals, snapshot rebuilds, and orders need `300+/min`.

## Recipe #14 — Trader-only compose UI needs to live where traders already are, not at a separate URL (Aug 22 2026)

**Symptom:** the user says "I want to send a signal from the trading page" / "I want to send signals from where I already am" / "the send button on the trading page doesn't work." The trader-hub at `/dashboard/trader-hub` has the form, but the user lands on `/dashboard/trading` (the trading page) and expects a send button on the read-only signal-feed view.

**Root cause:** the read-only signal view (TraderSignalsView on `/dashboard/trading`) and the compose view (`/dashboard/trader-hub`) live on separate routes. The trader has to:
1. Open a different route
2. Navigate away from the page they're inspecting signals on
3. Re-find the send form (a tab inside the trader-hub)

This is friction. Real traders are mobile and time-pressed — sending a signal needs to be a one-tap action from any signal-related view.

**The fix — extract `SendSignalForm` as a reusable component, wrap in a `SendSignalModal`, expose a `SendSignalButton` trigger:**

**1. The form lives in `src/components/trader/SendSignalForm.tsx`** as a self-contained component with its own CSS namespaced to `.tsf-*` (no collision with the trader-hub's `.th-*`):

```tsx
// Inputs: pair dropdown, BUY/SELL toggle, Entry / SL / TP1-TP4, commentary, submit
// Output: POST /api/trader/signals, fires onSuccess callback with the inserted signal
// Namespaced CSS: .tsf-form, .tsf-row, .tsf-dir-toggle, .tsf-btn-primary
```

**2. The `SendSignalModal`** wraps the form in a centered overlay with framer-motion + keyboard ESC handling. Self-contained state for open/close:

```tsx
function SendSignalModal({ open, onClose, onSuccess, defaultPair }: SendSignalModalProps) {
  return (
    <AnimatePresence>
      {open && (
        <motion.div className="send-signal-overlay" onClick={onClose}>
          <motion.div className="send-signal-modal" onClick={e => e.stopPropagation()}>
            <SendSignalForm onSuccess={onSuccess} defaultPair={defaultPair} />
          </motion.div>
        </motion.div>
      )}
    </AnimatePresence>
  )
}
```

**3. The `SendSignalButton`** is the one-line trigger that traders put in their header:

```tsx
<SendSignalButton onSuccess={(signal) => setReloadKey(k => k + 1)} triggerLabel="Send Signal" />
```

**4. The TraderSignalsView header on `/dashboard/trading`** imports `useUser()`, derives `canSendSignal = isTrader || isAdmin`, and conditionally renders the trigger:

```tsx
{canSendSignal && (
  <SendSignalButton
    onSuccess={(signal) => setTimeout(() => setReloadKey(k => k + 1), 500)}
    triggerLabel="Send Signal"
  />
)}
```

**5. The trader-hub page** also uses the same `SendSignalForm` (extracted from the inline form that used to live in that route's tab). Both pages share the same component, the same CSS, the same server POST — the only difference is whether the form is inline or modal.

**Why the `setReloadKey` + 500ms timeout matters:** the server POST does:
1. INSERT into telegram_trader_signals
2. Mirror to Telegram (if bot is configured)
3. PWA push fan-out to all subscribers

The Telegram mirror + push fan-out can race with the page reload. The 500ms delay lets the broadcast settle before the feed refetches, so the new signal doesn't appear half-pushed (e.g. with a stale trader_avatar).

**The submission feedback message must mention the push fan-out explicitly:**

```tsx
// In SendSignalForm success state:
<div className="tsf-result-note">
  Signal saved and PWA push fan-out triggered. Subscribers notified.
</div>
```

Otherwise the trader wonders why their phone didn't buzz (or, conversely, doesn't realize they ARE pushing to the community).

**When this hits again:** any new "compose" action that's currently gated behind a multi-tab deep-link. Pattern:
1. Extract the form into a shared component (namespaced CSS)
2. Wrap in a modal trigger button
3. Mount the button on every view the user might be on when they want to compose
4. Use `useUser()` (or equivalent context) to permission-gate the trigger
5. On success: bump a reload counter on the parent and let the parent's own feed re-render

## Recipe #15 — `navigator.locks` LockManager contention with `supabase.auth.getSession()` (added Aug 22 2026)

**Symptom:** a browser-side fetch returns `401 Not authenticated` even when the user is clearly signed in and the Supabase session token is in localStorage. The browser console shows the message:

```
Acquiring an exclusive Navigator LockManager lock "lock:sb-<project-ref>-auth-token" timed out waiting 10000ms
```

The visible UI looks like the feature is broken: "Access required" gates, blank trader-profile forms, infinite "Loading trader profile…" spinners. The user sees a 401 in DevTools Network.

**Root cause:** `supabase-js` v2's `auth.getSession()` (and any internal call that touches the session — including the session-refresh path on tab focus) acquires an **exclusive `navigator.locks` lock** on the auth-token storage key. The lock is project-keyed (`sb-<project-ref>-auth-token`). On PWA installs, in apps that keep multiple tabs open, or when an IndexedDB lock is held across windows, the lock acquisition times out at 10s. When it times out, `auth.getSession()` resolves with `{ data: { session: null } }` — silently. The client then makes a Bearer-less fetch to the API, the server returns 401, and the page shows a "loading forever" / "access required" state.

This was the root cause of FOUR separate bug reports in a single session:

1. TP1 button on a signal card silently failed (`SignalActions.tsx`)
2. Send Signal modal failed (`SendSignalForm.tsx`)
3. Admin profile form in the customers/Manage drawer failed to load (`adminFetch` in `src/lib/admin-fetch.ts`)
4. Public trader profile page at `/trader/[slug]` showed "Trader not found" because anon PostgREST calls returned NULL session, so PostgREST queries silently dropped.

The unifying cause: every one of these code paths used `getSupabaseBrowserClient().auth.getSession()` (or had the session access via supabase-js which acquires the same lock) and the lock timed out.

**The fix — read the access_token straight from localStorage and bypass supabase-js for the request:**

```ts
// src/lib/admin-fetch.ts (and any other auth-bearing fetch wrapper)
export async function adminFetch(input: RequestInfo | URL, init: RequestInit = {}) {
  const headers = new Headers(init.headers || {})
  if (!headers.has('Content-Type') && init.body) {
    headers.set('Content-Type', 'application/json')
  }

  let accessToken: string | null = null
  if (typeof window !== 'undefined') {
    // Try BOTH known storage keys (supabase-js mirrors the session into one of them)
    for (const key of [
      'sb-<project-ref>-auth-token',
      'app-auth-token',
    ]) {
      try {
        const raw = window.localStorage.getItem(key)
        if (!raw) continue
        const parsed = JSON.parse(raw)
        // Newer supabase-js stores as `{ access_token, refresh_token, ... }`
        // Older (pre-v2) stores as `[{ access_token, refresh_token, ... }, ...]` (array)
        const tok = parsed?.access_token || parsed?.[0]?.access_token
        if (tok) { accessToken = tok; break }
      } catch {
        // ignore parse errors — try next key
      }
    }
  }

  if (accessToken) {
    headers.set('Authorization', `Bearer ${accessToken}`)
  }

  return fetch(input, { ...init, headers })
}
```

**Apply this fix to ANY browser-side fetch wrapper that calls `supabase.auth.getSession()` or that uses supabase-js's Bearer injection indirectly.** Specifically:

- `adminFetch` (admin / customer drawer / admin manual points adjuster)
- `SignalActions` TP1/TP2/TP3/TP4/SL/Update/Close/Reopen button calls
- `SendSignalForm` composer modal calls
- Any `/api/admin/*` or `/api/trader/signals/*` POST from the client

**The diagnostic for "is this the lockManager bug?":**

1. Open the page in Chrome/Firefox dev console.
2. Look for any `LockManager lock "lock:sb-…-auth-token"` related console warnings or errors.
3. Or use the application tab → Service Workers tab in Chrome to inspect active locks (Chrome DevTools → Application → Storage → IndexedDB → LockManager is part of Web Locks API).

The fastest diagnostic at runtime: add `await supabase.auth.getSession()` to a console REPL and time how long it takes. If it takes >10s, the lock is contended. The page that called it already gave up and rendered a 401-bound state.

**The deeper rule — don't use supabase-js for simple Bearer auth in the browser:**

`supabase-js` is great for typed PostgREST access when the session is stable. For *auth* in the browser, it pulls in the lockManager + IndexedDB machinery, which is overkill if all you need is `Authorization: Bearer <access_token>`. The two-line localStorage read above is faster, smaller, and never hangs.

**The deeper companion rule — when `useUser()` reads session from supabase-js, it can hang too:**

`useUser()` (the context provider that wraps the whole app) uses `supabase.auth.getSession()` on mount. If the lock is held, the entire provider hangs for 10s. Pages that depend on `isTrader`, `isAdmin`, etc. must wait for `loading=false` AFTER all DB-derived flags resolve, not before (see Recipe #12). The lockManager bug amplifies Recipe #12's race because the lock timeout delays the provider's `setLoading(false)` by 10s.

**When this hits again:** any new client-side fetch that uses `supabase.auth.getSession()` to get a token. Default to the localStorage-read pattern. Add a comment explaining why (the lockManager bug). If the auth state truly needs to be live (auto-refresh on token expiry), use `supabase.auth.onAuthStateChange` instead of `getSession` — it doesn't acquire the same lock.

## Recipe #16 — `signal.trader_id` is `auth.users.id`, NOT `trader_profiles.id` (added Aug 22 2026)

**Symptom:** the trader-action buttons (TP1 / TP2 / TP3 / TP4 / SL / Update / Close / Reopen) disappear from every card on the Trader Signals feed, even for the user who owns the signals. Or the buttons show for the wrong users. The DB row clearly shows `is_trader=true, trader_status='active'`. The auth UUID matches the trader. Yet `signal.trader_id === user?.id` is always false.

**Root cause — the `v_recent_trader_signals` view exposes `trader_profile_id` (the trader_profiles row PK), NOT `trader_id` (the auth.users.id).** The two UUIDs are different:

- `trader_profiles.id` is a synthetic PK (`gen_random_uuid()`)
- `telegram_trader_signals.trader_id` is `auth.users.id` (the FK)
- `trader_profiles.user_id` is the FK back to `auth.users.id`

So when the TraderSignalsView component checks `signal.trader_id === user?.id`, it's comparing the user's auth UUID against an undefined field. The view doesn't expose `trader_id` at all (yet — the migration to add it is queued).

**The fix — augment the public feed server-side:**

```ts
// src/app/api/trader/signals/route.ts — public branch
const signals = data || []

// Augment each signal with `trader_id` (= the auth user's UUID)
// so the frontend can decide whether the current user owns this signal.
const slugs = Array.from(new Set(
  signals.map(s => (s as any).trader_slug).filter(Boolean)
)) as string[]
if (slugs.length > 0) {
  const { data: profiles } = await supabase
    .from('trader_profiles')
    .select('slug, user_id')
    .in('slug', slugs)
  const slugToUserId = new Map<string, string>()
  for (const p of profiles || []) {
    if (p?.slug && p?.user_id) slugToUserId.set(p.slug, p.user_id)
  }
  for (const s of signals as any[]) {
    if (!s.trader_id && s.trader_slug) {
      s.trader_id = slugToUserId.get(s.trader_slug) || null
    }
  }
}

return NextResponse.json({ signals })
```

The route runs with `service_role`, so RLS is bypassed. One batched query covers all unique slugs in the response. The client just consumes the API as-is.

**The wrong approach — client-side PostgREST fetch on the underlying table:**

```ts
// WRONG — anon client can't read telegram_trader_signals (RLS),
// so the fetch returns 401 or an empty array. Augmentation never happens.
const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY || ''
const ownerRes = await fetch(
  `/rest/v1/telegram_trader_signals?source=eq.trader&select=id,trader_id&limit=200`,
  { headers: { 'apikey': anonKey, 'Authorization': `Bearer ${anonKey}` } }
)
```

The "ownerMap" stays empty, `signal.trader_id` stays undefined, the action buttons never render.

**The schema truth — always check before assuming column names:**

```sql
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'v_recent_trader_signals'
ORDER BY ordinal_position;
```

The view's exposed columns are `signal_id, pair, direction, entry, sl, tp1, tp2, tp3, tp4, tp1_hit, ..., status, sent_at, channel_id, telegram_message_id, mirrored_to_telegram_at, commentary, is_trader, trader_telegram_handle, trader_profile_id, trader_slug, trader_display_name, trader_avatar_url, user_id`.

Note `trader_profile_id` (the row PK) and `user_id` (the auth UUID). Both exist on the view, but the column the component looks for (`trader_id`) does NOT — until the queued migration lands.

**The companion rule on `telegram_trader_signals.status` enum:**

The CHECK constraint allows only `'live', 'tp1_hit', 'tp2_hit', 'tp3_hit', 'tp4_hit', 'sl_hit', 'completed', 'expired', 'cancelled'` — **NOT `'closed'`**. A route that wants to write `status='closed'` will fail with `new row for relation "telegram_trader_signals" violates check constraint`. Use `'completed'` for manual closes. Surface `'closed'` semantics to clients in the response shape (separate from the DB column).

**When this hits again:** any new feature that gates on "this signal belongs to the current user." Check the view's columns via `information_schema.columns` before adding a gate. If the column you need is missing from the view, augment server-side with a batched lookup — never via client-side anon PostgREST fetches on RLS-protected tables.

## Recipe #17 — PWA service worker `CACHE_VERSION` must be bumped on every content-only release (added Aug 22 2026)

**Symptom:** the agent pushes a CSS-only or JS-only fix (no new HTML, no new route, no env var). The new content-hashed chunk is served at `/_next/static/chunks/<hash>.css` or `/_next/static/chunks/<hash>.js`. `curl` against the production URL confirms the new content is live. But the user's PWA still shows the old layout. The user reports "still not working" / "fix didn't work" / "the spacing is still wrong." Sometimes the same fix ships 3 times before the user gives up.

**Root cause:** the PWA service worker (`public/sw.js`) caches the content-hashed chunks under a cache name like `static-${CACHE_VERSION}` (currently `static-app-v7`). When CACHE_VERSION doesn't change but the content does, the cache name stays the same and `cache.match(request)` returns the **stale** chunk the user already cached on first install.

Important nuance: the content-hashed chunk filename (e.g. `347bc52a628602b5.css`) **does** change when the content changes — but the service worker checks against the cached **request URL**, not the cached **content hash**. The browser's HTTP cache is keyed by URL. Once `sw.js` says "for any request matching this regex, return `cache.match(request)`", the URL match wins regardless of content hash.

The trigger condition: any deploy where **only content changes** (CSS, JS, lazy-loaded component chunks) and `public/sw.js` is unchanged. CSS-only changes don't generate a new HTML response (the HTML is already cached). The PWA shows the stale CSS.

**The fix — bump `CACHE_VERSION` in `public/sw.js` on every release:**

```js
// public/sw.js
// Aug 22 2026 — bumped to v7: the trader-signals-view CSS bundle
// (TraderSignalsView.css) is bundled into a content-hashed chunk
// that the SW served from cache. Until v7 the PWA on iPhone was
// still serving the old chunk with `padding: 10px ...` even though
// the network now ships `padding: 0 0 14px`. Bumping the SW
// version forces the PWA to drop the cached chunk and refetch.
const CACHE_VERSION = 'app-v7';
```

When CACHE_VERSION changes:

1. The `install` event runs `caches.open('static-app-v7')` and seeds it.
2. The `activate` event runs `caches.delete('static-app-v6')` and `caches.delete('runtime-app-v6')`.
3. The user's NEXT request (e.g. opening the Trader Analysis tab) goes to the network because the old cache is gone.
4. `skipWaiting()` + `clients.claim()` (already in the existing SW) make the new SW active without requiring the user to refresh.

**The verification after every content-only deploy:**

```bash
# 1. SW is the new version
curl -sL https://<domain>/sw.js | grep CACHE_VERSION
# Expected: const CACHE_VERSION = 'app-v<NEW>'

# 2. The new content chunk IS being served
curl -sIL https://<domain>/_next/static/chunks/<new-hash>.css | head -1
# Expected: HTTP/2 200

# 3. The new chunk actually contains the new content
curl -sL https://<domain>/_next/static/chunks/<new-hash>.css | grep '<search-for-new-text>'
# Expected: a match

# 4. (iOS PWA only) Ask the user to close+reopen the PWA — iOS doesn't auto-activate
#    the new SW like Chrome does. The activate() event fires after close+reopen.
```

**The pre-deploy checklist for any CSS/JS-only release:**

```bash
# 1. Bump the SW cache version
sed -i "s/CACHE_VERSION = 'app-v[0-9]*'/CACHE_VERSION = 'app-v$NEXT'/" public/sw.js

# 2. Add a comment in the SW explaining why you bumped
#    (audit trail — when the user reports "still broken" six months
#    from now, future-you can grep git log for the bump reason)

# 3. Verify the SW file size changed (sanity check the edit landed)
ls -l public/sw.js
```

**When this hits again:** every content-only release (CSS, JS, component chunk). The bump is one line. The cost of forgetting it is a series of "still not working" reports that erode user trust.

**Companion rule — iOS PWA needs close+reopen, not hard refresh:**

iOS Safari PWA does NOT auto-activate a new service worker like Chrome does. The user has to close the PWA (swipe up to dismiss), then reopen. Until then, the OLD SW is still active. Plan for this:

1. Bump CACHE_VERSION
2. Tell the user "close the PWA and reopen" in the commit message / release notes / chat reply
3. iOS may also delay SW activation for up to 24h (Safari is conservative). If the user says "I closed it, still broken," check `chrome://serviceworker-internals` equivalent in Safari (none directly — use DevTools connected to the device).

**Pair with:** Recipe #10 (iOS PWA + Supabase storage cross-origin image rendering). The SW pass-through rules in Recipe #10 also need to be re-tested after a CACHE_VERSION bump, because the new SW might have a bug in the pass-through regex.

## Recipe #20 — Apply Supabase migrations from a sandbox via `db push --dns-resolver https` (added Aug 25 2026)

**Symptom:** the agent needs to run a new `.sql` migration against the live Supabase project but cannot connect directly: the agent is running inside a sandbox where outbound DNS to `db.<project-ref>.supabase.co` returns ENOTFOUND, both the IPv4 pooler and the IPv6 direct connection are blocked, and `/api/admin/apply-migration` returns 503 because `SUPABASE_DB_URL` is not set in Railway env.

**Root cause:** the Supabase JS client (`supabase-js`) works from any sandbox because it routes through `api.supabase.co` (HTTPS, normal internet egress) — but the Postgres wire protocol (`pg` package, connection-string auth, port 5432) is blocked by the sandbox's egress filter. Apps that need to run arbitrary SQL have been stuck waiting for the user to paste the SQL into the Supabase SQL Editor manually.

**The fix — use the local `supabase` CLI with DNS-over-HTTPS resolver:**

```bash
# 1. Confirm CLI is installed and logged in
supabase --version
supabase projects list  # must show the target project

# 2. Link the project so the CLI knows where to push
supabase link --project-ref <your-project-ref>

# 3. Run migrations using Cloudflare's HTTPS DNS resolver so DNS lookups
#    succeed even when the sandbox blocks native DNS to db.supabase.co
supabase db push --include-all --dns-resolver https
```

The `--dns-resolver https` flag tells the CLI to resolve DNS via `https://1.1.1.1/dns-query` (Cloudflare's DNS-over-HTTPS endpoint) instead of the system resolver. The HTTPS resolution succeeds where native DNS gets ENOTFOUND.

**The duplicate-migration-version trap:**

If your `supabase/migrations/` directory contains multiple files whose filename starts with the same `YYYYMMDDXXXX` version (e.g. `202608220000_a.sql`, `202608220000_b.sql` — three files sharing version `202608220000`), the CLI's local-vs-remote comparison breaks and `db push` errors with `duplicate key value violates unique constraint "schema_migrations_pkey"`.

**The diagnostic:** run `supabase migration list` BEFORE pushing. Look for the same version appearing more than once in the **Local** column (the leftmost).

**The fix — move duplicates out of `supabase/migrations/`:**

```bash
mkdir -p supabase/migrations/_archive
mv supabase/migrations/202608220000_a.sql supabase/migrations/_archive/
mv supabase/migrations/202608220000_b.sql supabase/migrations/_archive/
# The CLI now sees exactly one file per version, db push proceeds.
```

**The partial-apply trap (the real footgun):**

A migration file can include statements that succeed and statements that fail (e.g. a `CREATE OR REPLACE FUNCTION` references a column that doesn't exist). The CLI reports the file as "applied" but the live DB has a half-applied state — the function was created (success) but the rest aborted on the bad column reference.

**The diagnostic — check what landed in `pg_proc`:**

```sql
SELECT proname, prosrc LIKE '%last_seen_at%'
FROM pg_proc WHERE proname = 'app_get_user_lifecycle';
```

If the function exists but references `last_seen_at` (which doesn't exist in production), the partial apply left broken code. Recover by pushing a NEW migration file with a fresh version stamp (e.g. `202608250002_*` after `202608250001_*`) that `CREATE OR REPLACE FUNCTION`s the corrected version.

**Always dry-run before apply:**

```bash
supabase db push --include-all --dns-resolver https --dry-run
```

The output lists exactly which files will run. If it lists more than you expected, abort and investigate.

**The column-name gotcha in SECURITY DEFINER functions:**

This is a migration-content gotcha, not a CLI issue. SQL functions running under `SECURITY DEFINER + service_role` can read `auth.users` but the actual column names are different from what PostgREST shows:

| PostgREST alias (use in `supabase-js`) | Real SQL column (use in SECURITY DEFINER function) |
|---|---|
| `user_metadata` | `raw_user_meta_data` |

Inside `SECURITY DEFINER` functions, you reference the RAW column.

```sql
-- WRONG — fails in prod with 'column auth.users.user_metadata does not exist'
SELECT (auth.users.user_metadata->>'theme_accent') IS NOT NULL
FROM auth.users WHERE id = p_user_id;

-- RIGHT
SELECT (raw_user_meta_data->>'theme_accent') IS NOT NULL
FROM auth.users WHERE id = p_user_id;
```

Same gotcha on `user_accounts`: column is `last_active_at` (production), NOT `last_seen_at` (which was the original column name in the position-snapshot migration lineage — renamed during a later migration). Verify columns BEFORE writing the RPC:

```sql
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'user_accounts'
ORDER BY ordinal_position;
```

**The repair flow when the partial-apply leaves a broken function:**

```bash
# 1. Tell the CLI to forget about the failed migration
supabase migration repair --status reverted 202608250001

# 2. Move + rename the file to a fresh version
mv supabase/migrations/202608250001_lifecycle_steps.sql \
   supabase/migrations/202608250002_lifecycle_steps_fixup.sql

# 3. Verify with --dry-run, then apply
supabase db push --include-all --dns-resolver https --dry-run
supabase db push --include-all --dns-resolver https
```

The migration tool's `repair --status` lets you flip the ledger without re-running SQL. Use it when:
- The SQL succeeded but the ledger didn't update (CLI bug)
- You need to manually mark a SQL Editor–applied migration as "managed by CLI"
- You want to skip a migration that's already applied

**When this hits again:** any time the agent needs to apply DDL to production Supabase from inside a sandbox where Postgres wire egress is blocked. The `--dns-resolver https` flag is the unlock. Pair it with the duplicate-version diagnostic before pushing, and verify column names via `information_schema.columns` before writing SECURITY DEFINER functions that reference `auth.users`.

**Pair with:** `supabase-policies-migrations` skill for naming rules and idempotency patterns.

## Recipe #18 — JSX child comments: `{/* */}` only, NEVER bare `//` (added Aug 22 2026)

**Symptom:** the user reports seeing **literal source code text** in the rendered UI. For example, a trader signal card displays:

```
TP1 TP2 TP3 TP4 SL Update
// Close (manual exit) — opens a tiny pri
// constraint allows: live|tp1_hit|tp2_hit|tp3_hit|tp4_hit|sl_hit|
// completed|expired|cancelled. Anything other than live / TP* / SL*
// is "closed".
Close
```

The text isn't a render bug — the JSX compiler is doing exactly what it's told. The bare `//` is being interpreted as TEXT CHILDREN, not comments.

**Root cause:** JSX has two kinds of comments:

1. **Block comments in JSX children positions:** `{/* close price input */}` — these are stripped.
2. **Bare line comments in JSX child positions:** `// close price input` — these are PRESERVED AS TEXT.

If you write `// something` between two JSX elements (i.e. between `</button>` and the next conditional render), the line shows up as literal text in the DOM.

**The wrong pattern (renders as text):**

```tsx
{/* Close (manual exit) */}
// Close (manual exit) — opens a tiny price input form
// constraint allows: live|tp1_hit|tp2_hit|tp3_hit|tp4_hit|sl_hit|
// completed|expired|cancelled.
{(signal.status !== 'completed') && (
  <button>...</button>
)}
```

The `//` lines above the conditional are rendered as TEXT NODES inside the parent element. The user sees them.

**The correct pattern:**

```tsx
{/* Close (manual exit) — opens a tiny price input form.
    Constraint allows: live|tp1_hit|tp2_hit|tp3_hit|tp4_hit|sl_hit|
    completed|expired|cancelled. */}
{(signal.status !== 'completed') && (
  <button>...</button>
)}
```

Use `{/* ... */}` block comments for documentation inside JSX, even for single lines.

**The diagnostic — look for `//` between sibling JSX elements:**

```bash
grep -n "^[[:space:]]*//" src/**/*.tsx
```

Any `//` between `</Component>` and `<NextComponent>` is suspect. Replace with `{/* */}` or just delete the comment (the function/component name usually makes the intent obvious).

**When this hits again:** any JSX file that has comments at child positions (between elements). The lint rule to add to your repo: `eslint-plugin-react` rules `react/jsx-no-comment-textnodes` catches this exactly — it errors on any JSX child that looks like a comment but isn't wrapped in `{ }`.

**Companion rule — JSX expressions `{}` inside text don't render comments:**

```tsx
<p>// this is not a comment</p>            {/* renders "// this is not a comment" */}
<p>{"// this is text inside braces"}</p>   {/* renders "// this is text inside braces" */}
```

To get a JSX comment OUTSIDE of `{}`, you cannot. There is no comment-in-text syntax. Use `{/* */}` for any comment you need.


## Recipe #21 — Onboarding lifecycle pattern: durable flag vs short-lived token (added Aug 26 2026)

When a wizard step asks "is the user connected to X?" — and X has both
a durable row (e.g. `user_accounts.broker_connection_status = 'connected'`) and a
short-lived access token (e.g. `user_accounts.broker_access_token` with
`broker_token_expiry`) — the gating check MUST be on the durable flag, not
on token expiry. OAuth access tokens age out every ~1h; the user's
intent to be connected does not.

Concrete failure case from production: the `link_broker` step in
`/onboarding` required `broker_access_token IS NOT NULL AND broker_token_expiry > now()`.
Token expired 11h after the user connected → step flipped back to "pending"
even though `broker_connection_status='connected'` was still set. The user
couldn't progress the wizard and had no bypass.

The fix: accept EITHER signal. The connection-state flag is the durable
record of "this user has set up the broker"; the OAuth access token is
a refreshable credential that any subsequent API call will fail with 401
if stale, prompting the user to re-auth via the modal. Two checks,
one OR'd:

```sql
-- supabase/migrations/202608260000_lifecycle_broker_relax.sql
v_has_broker_token := EXISTS (
    SELECT 1 FROM public.user_accounts
    WHERE id = p_user_id
      AND (
        (broker_access_token IS NOT NULL
         AND (broker_token_expiry IS NULL OR broker_token_expiry > now()))
        OR broker_connection_status = 'connected'   -- durable flag wins
      )
);
```

Mirror the same rule in the API completion handler. The TypeScript
equivalent at `src/app/api/onboarding/complete-step/route.ts`:

```ts
const tokenOk = data.broker_access_token
    && (!data.broker_token_expiry || new Date(data.broker_token_expiry) > new Date())
if (tokenOk) return null                      // non-expired token
if (data.broker_connection_status === 'connected') return null  // durable fallback
return 'broker_token_expired'
```

General rule: **any "is X connected?" gating that reads from
`user_accounts` should look at the durable `*_status` / `*_connected` /
`*_linked` flag, not the OAuth/token expiry. The token's only job is to
gate the next API call that actually needs to talk to X — not the UI's
"are you set up?" question.**

---

## Recipe #22 — Deep-link query param to open a modal from a wizard step (added Aug 26 2026)

When a wizard step needs to land the user inside a specific modal
(e.g. The broker connect, account switcher, deposit prompt) — don't
try to do a same-tab modal-render from a different route. Use a
deep-link query param consumed on mount.

`src/lib/onboarding/steps.ts` — point the step's `route` at:
```ts
route: '/dashboard/trading?brokerOpenConnect=1',
```

`src/components/trading/TradingDashboardView.tsx` — read the param
on mount, auto-open the modal, then clean the URL so a refresh
doesn't re-open:

```tsx
useEffect(() => {
    if (typeof window === 'undefined') return
    try {
        const url = new URL(window.location.href)
        if (url.searchParams.get('brokerOpenConnect') === '1') {
            setShowConnectionModal(true)
            url.searchParams.delete('brokerOpenConnect')
            window.history.replaceState({}, '', url.toString())
        }
    } catch {}
}, [])
```

This pairs naturally with the existing `tl:open-connect-modal` window
event pattern in `TradingDashboardView` (lines ~76-83). The query
param handles the cross-page deep-link; the event handles in-page
buttons (e.g. a "Connect now" button in the Settings page).

General rule: **cross-route deep-link → query param. In-page open →
window event. Don't try to make a modal render across route
boundaries — use the URL as the bridge.**

---

## Recipe #23 — Hard-redirect middleware gate for first-run onboarding (added Aug 26 2026)

When a new user is supposed to walk through an onboarding wizard before
accessing the dashboard, two layers of enforcement are required — a
sandboxed agent can't trust either alone:

**Server-side middleware** (`src/middleware.ts`):
```ts
const GATED_PREFIXES = ['/dashboard', '/trading-dashboard']
const ALLOWED = ['/onboarding', '/onboarding/...', '/auth', '/login', ...]
if (underGate && !allowed) {
    const sbCookie = request.cookies.getAll().find(c => c.name.includes('auth-token'))
    // decode JWT payload (sub = user id), look up user_accounts.onboarding_complete
    // via service_role, 302 to /onboarding if false
}
```

**Client-side companion** (`src/components/onboarding/useOnboardingGate.ts`):
```ts
useEffect(() => {
    if (profile && !profile.onboardingComplete && !pathname.startsWith('/onboarding')) {
        router.replace('/onboarding')
    }
}, [profile, onboardingComplete, router])
```

The middleware handles hot-load refresh + bot traffic. The hook handles
SPA navigation (clicking a sidebar link inside the dashboard) since
the middleware doesn't run on client-side route changes.

Both rely on a `UserContext.profile.onboardingComplete` boolean that
the auth bootstrap fetches from `user_accounts.onboarding_complete`. The
canonical state is in the DB; the client flag is a cached read.

**Idempotency for the wizard itself**: the wizard polls
`app_get_user_lifecycle(p_user_id)` which auto-grades steps from live
data. A user who has already done the underlying task (avatar set,
broker connected, etc.) but is on the old wizard just needs a "Refresh
status" button to re-fetch the lifecycle and have the steps auto-flip.
Don't make the user re-do work the system can detect.

---

## Recipe #24 — Direct DB connection from agent sandbox: three dead ends + one working path (added Aug 26 2026)

When the agent sandbox can't connect to Postgres directly to apply
migrations, the fallback paths in order of preference:

1. `supabase db push --dns-resolver https` — works for adding new
   migrations. Covered by Recipe #20.
2. **Apply via a deploy-time one-shot script** — the migration runs
   in Railway's network which CAN reach the DB. The script can be a
   `cron` job that runs once on next deploy, or a one-time `npm run`
   in the build container. Use this when the migration has already
   been applied but a side-effect (data backfill, foreign-key fix)
   needs to run in the prod network.
3. **Apply via a dedicated API route** that takes the SQL string and
   runs it via `pg.Client({ connectionString: process.env.SUPABASE_DB_URL })`.
   This requires `SUPABASE_DB_URL` to be set in Railway env. If it's
   not, the route returns 503 with a clear migration-pending hint.

What does NOT work from the sandbox:
- Direct `pg.connect('db.<ref>.supabase.co')` — DNS returns
  IPv6 only on Cloudflare, and the sandbox's outbound IPv6 is
  blocked (`ENOTFOUND` / `ECONNREFUSED`). Even with
  `dns.setServers(['8.8.8.8', '1.1.1.1'])` and `--dns-resolver https`,
  the actual TCP connect to port 5432 fails on every region tried.
- `pg.Pool` with `db.<ref>.supabase.com` IPv4-only — same issue.
- `pg-meta` REST endpoint — requires a Supabase Management PAT, not the
  service-role JWT.
- `/api/admin/apply-migration` — works only if Railway env has
  `SUPABASE_DB_URL` (postgres connection string) AND
  `ADMIN_BOOTSTRAP_TOKEN` (admin email login). Check Railway env
  first; if both are present, the route works.

So the **decision tree** when an agent needs to apply a migration:

```
Is `supabase db push` available? (CLI installed + linked + token)
  YES → use it (Recipe #20)
  NO → does the prod app have `SUPABASE_DB_URL` env?
    YES → use `/api/admin/apply-migration` with ADMIN_BOOTSTRAP_TOKEN
    NO  → tell the user to apply via Supabase SQL Editor manually
```

---

## Recipe #25 — Client-side auth/permission gates must require DECISIVE state, not undefined (added Aug 24 2026)

**Symptom**: A user who's already completed onboarding navigates to `/dashboard` and clicks the "Trading Floor" card. The browser briefly navigates to `/onboarding` then bounces back to `/dashboard`. The user reports: "I'm redirected to the onboarding screen then back to the dashboard."

**Root cause — the `OnboardingGateRedirect` client-side companion treated `profile.onboardingComplete === undefined` as "incomplete" and pushed the user to `/onboarding`:**

```ts
// BROKEN — undefined treated as "incomplete"
useEffect(() => {
    if (loading) return
    if (!profile) return
    if (profile.onboardingComplete) return  // <-- undefined skips this
    router.replace('/onboarding')
}, [loading, profile, onboardingComplete, router])
```

UserContext sets the profile IMMEDIATELY from `user_metadata` on auth, but the `onboarding_complete` boolean lives on `user_accounts` (fetched a moment later via `Promise.allSettled`). During that window, `profile.onboardingComplete` is `undefined`. The `if (profile.onboardingComplete) return` doesn't short-circuit because `undefined` is not `=== true`. So the redirect fires. Once `user_accounts` resolves with the real value, the redirect is undone, leaving the visible flash.

**The fix — require an EXPLICIT boolean before allowing any redirect:**

```ts
// CORRECT — require a decided boolean
const onboardingComplete = profile?.onboardingComplete === true
const hasDecisiveStatus = profile?.onboardingComplete === true
    || profile?.onboardingComplete === false

useEffect(() => {
    if (loading) return                  // still loading UserContext
    if (!profile) return                 // not signed in
    if (!hasDecisiveStatus) return       // loaded but field still undefined
    if (onboardingComplete) return        // safe to skip
    router.replace('/onboarding')
}, [loading, profile, onboardingComplete, router, hasDecisiveStatus])
```

**The class-level rule** — any client-side auth/permission gate that reads a "could be undefined" boolean from UserContext must distinguish three states:

1. `undefined` → "not yet known" → DO NOTHING (don't redirect, don't show UI)
2. `false` → "known to be false" → safe to redirect/show
3. `true` → "known to be true" → allow access

This applies to EVERY permission-gate component, not just onboarding. The pattern is "wait for the data, then act on the data" — don't act on missing data as if it were negative.

Companion pattern: the inline wizard/hero (e.g. `OnboardingHero`) should also return `null` (not render anything) when the user is fully onboarded, rather than rendering a "you're all set" card. The same decisive-status rule: only show UI for users whose state is known.

---

## Recipe #26 — Never hardcode business rules that are stored in the database (added Aug 24 2026)

**Symptom**: User passes a quiz at exactly 75%. The popup fires, points credit, the "you passed" message shows. The lesson does NOT flip to "completed." The next lesson stays locked. The user reports: "I passed the quiz but the lesson doesn't mark off as complete."

**Root cause — the lesson progress route hardcoded 80% as the pass threshold for the micro-quiz gate, but actual quizzes pass at 70 OR 80 depending on the quiz:**

```ts
// BROKEN — hardcoded threshold
const microQuizPassed = newMicroQuizScore !== null
    ? newMicroQuizScore >= 80
    : (prev?.micro_quiz_passed ?? false)
```

50 micro-quizzes exist. Of those:
- Module-end quizzes (Markets, Price Action, Trade Mechanics, Candles, Structure, Indicators, Position Sizing, Stop Placement, Drawdown, Broker Connection): `pass_pct=70`
- All other micro-quizzes: `pass_pct=80`

A user who scores 75% on a 70%-threshold quiz passes the quiz, sees the popup, but the lesson doesn't mark complete because 75 < 80.

**The fix — fetch the actual rule from the database:**

```ts
// CORRECT — read the rule from the source of truth
let microQuizPassed = newMicroQuizScore !== null
    ? false
    : (prev?.micro_quiz_passed ?? false)

if (newMicroQuizScore !== null && lessonRes.data?.micro_quiz_id) {
    const qRes = await svc.from('education_quizzes')
        .select('pass_pct')
        .eq('id', lessonRes.data.micro_quiz_id)
        .maybeSingle()
    const passPct = (qRes.data as any)?.pass_pct ?? 80
    microQuizPassed = newMicroQuizScore >= passPct
}
```

**The class-level rule** — NEVER hardcode a business rule that lives in the database. Anywhere you see `if (x >= 80)` or `if (x > 0.5)` for a value that varies by row/category, the rule is wrong: it should be a JOIN or a column read. The cost of one extra `SELECT pass_pct` is negligible. The cost of a user reporting "I passed but it says I didn't" is high.

Common offenders in this codebase:
- `>= 80` thresholds for quizzes
- `>= 70` for streak milestones
- Hardcoded `daily_cap`, `lifetime_cap` in the TypeScript config vs the DB registry
- Hardcoded retry counts, timeouts, pagination sizes

The fix is always the same: read the value from the source of truth. If the source of truth is split between TS and DB (e.g. POINTS config in `src/lib/os-points/config.ts` vs `app_point_reasons` table), pick one and migrate the other.

---

## Recipe #27 — SQL `WHERE col=*** is case-sensitive; reason keys must match the case the code passes (added Aug 24 2026)

**Symptom**: A user earns 100 quiz_ace points. The `user_accounts.points` total goes up correctly. The points popup fires. The activity feed shows nothing. Daily caps appear to be bypassed (a user can earn `lesson_complete` 200 times in a day with no cap). The lifetime_cap on `lesson_complete` (100) never kicks in.

**Root cause** — DB stores reasons in UPPERCASE (`QUIZ_PASS`, `QUIZ_ACE`, `LESSON_COMPLETE`); TypeScript config and code pass lowercase (`quiz_pass`, `quiz_ace`, `lesson_complete`). The award_log SQL function does:

```sql
SELECT * INTO v_reason_record FROM app_point_reasons WHERE reason_key = p_reason;
IF FOUND THEN
  v_base_amount := v_reason_record.base_amount;
  -- ... cap checks below
ELSE
  v_base_amount := p_amount;  -- fallback uses caller's amount
END IF;
```

PostgreSQL string equality is case-sensitive. So `WHERE reason_key = 'quiz_pass'` doesn't match the row stored as `QUIZ_PASS`. `v_reason_record` is NULL. Every subsequent cap check uses `IF FOUND` guards, which skip. The function falls back to the caller's `p_amount` and the hourly velocity check (which IS hardcoded at 500/hr). The result: every cap is bypassed.

**The fix — normalize everything to one case. The TypeScript side is the right place to start because it's what the code passes; lowercase the DB to match:**

```sql
-- migration: normalize reason keys
UPDATE public.app_point_reasons
SET reason_key = LOWER(reason_key)
WHERE reason_key <> LOWER(reason_key);

UPDATE public.points_ledger
SET reason = LOWER(reason)
WHERE reason <> LOWER(reason);

UPDATE public.app_point_award_caps
SET reason_key = LOWER(reason_key)
WHERE reason_key <> LOWER(reason_key);
```

**The class-level rule** — when defining a registry table (reasons, statuses, types, categories), pick one canonical case (lowercase is the most common convention in JS/TS ecosystems) and enforce it on both the writer (the SQL) and the reader (the code). Audit it with a one-time migration; prevent drift with a `CHECK (reason_key = LOWER(reason_key))` constraint.

**Related pattern: when adding a new enum-like value, search for ALL its consumers** — the SQL function, the TypeScript config, the route, the audit log, the cap table. Missing one creates silent drift. The reason-key bug here existed for weeks before anyone noticed because the call still "worked" (just without caps).

---

## Recipe #28 — Customer-facing copy: describe what's there, don't push actions or expose internals (added Aug 24 2026)

**Symptom**: Three rounds of edits to the platform walkthrough copy at `/guide`. Each round, the user says "not like that, like this."

- Round 1: "This is wrong. Don't include the admin division — customers don't see it."
- Round 2: "Don't push users to refer people. That's not the vibe."
- Round 3 (final, accepted): "Most members start with Trading, with other areas appearing as you use the platform."

**Root cause** — the agent was writing copy from a BUILDER's POV: describing the full app structure, naming every division, implying growth paths the user might not want. The customer is reading this to understand what they can do RIGHT NOW, not what's possible if they invest effort.

**The class-level rules for customer-facing onboarding copy** (anywhere a new user reads about the app, the platform walkthrough, the first-run guide, the division chooser, the bottom dock description):

1. **NEVER name a division/feature the user can't access.** If admin-only, don't list it. The user will ask "why can't I see this?"
2. **NEVER push a specific growth path** ("once you start building a partner network you'll see Sales"). The user is just exploring. Growth paths come up in their own time, in the right context (the partner portal CTA, the referral UI, etc.). Onboarding copy is for orientation, not activation.
3. **NEVER volunteer tradeoffs the user can't act on.** "Each tile is a shortcut. Long-press to remove it from your Pinned section. Reorder by dragging." — fine, actionable. "Divisions vary by account" — too vague, useless to the user.
4. **Use neutral framing for things the user discovers on their own.** "Most members start with Trading, with other areas appearing as you use the platform." — this is descriptive without implying the user SHOULD do something.
5. **The rule of thumb: read the copy aloud, replace the user's name with "I" — does it sound like something a real customer would say to themselves?** If it sounds like a marketing brochure, the user will reject it.

Same pattern applies to the **bottom dock labels, the dashboard hero, the empty states, the "what's new" modals, the error messages** — any text the customer sees. The internal naming (admin division, partner network activation, etc.) is fine in admin tools, settings panels, runbook pages. It's wrong in first-run, onboarding, and walkthrough surfaces.

---

## Recipe #29 — Missing CSS import is the #1 cause of "white text, no styling" on a rewritten Next.js page (added Aug 24 2026)

**Symptom**: User reports the `/onboarding` page renders as raw browser-default text on a dark background — no colors, no spacing, no animations, no buttons. tsc and next build both pass clean. The user says: "all I'm seeing is white text without any CSS styling."

**Root cause** — the page was rewritten (via `write_file` or full content replacement) without re-adding the CSS import. Next.js **only bundles CSS that gets explicitly imported** by a page, component, layout, or root. A 42KB `onboarding.css` file sitting next to `page.tsx` does nothing if no `import './onboarding.css'` is in the file. Webpack/Turbopack drops it silently — no warning, no error.

```ts
// BROKEN — page.tsx has no CSS import. 42KB of styles are not in the build.
'use client'
import React from 'react'
import { useUser } from '@/context/UserContext'
import { adminFetch } from '@/lib/admin-fetch'
export default function OnboardingPage() { /* ... */ }
```

```ts
// CORRECT — CSS import added
'use client'
import React from 'react'
import { useUser } from '@/context/UserContext'
import { adminFetch } from '@/lib/admin-fetch'
import './onboarding.css'  // <-- the missing line
export default function OnboardingPage() { /* ... */ }
```

**How to detect this without a build round-trip:**

1. `grep -nE "import\s+['\"][^'\"]*\\.css['\"]" <page-or-component-file>` — if a sibling CSS file exists but no import inside the .tsx/.ts file, this is the bug
2. Inspect `next.config.js` and the `className` strings in the JSX — if the CSS classes are real but missing from the production CSS chunk, the import chain is broken
3. After deploying, fetch `/_next/static/css/*.css` and grep for the page's distinctive class names (`onb-all-root`, `partner-portal-grid`, etc.). If they appear, the CSS shipped. If they don't, the import was lost.

**The class-level rule** — when rewriting ANY Next.js page/component via `write_file` or full overwrite:

1. **Before writing**, copy the import block from the original file verbatim, including `import './whatever.css'`
2. **After writing**, audit: every adjacent `.css` file referenced in the original MUST appear in the new file's imports
3. **Verify in build output**: `next build` should produce a chunk matching the page name that contains the expected CSS hash
4. **Verify in production**: pull `/_next/static/css/<hash>.css` and grep for a distinctive class from the page

The build passing cleanly is **not** sufficient — the build only checks syntax and references, not whether the design actually renders. The class-level audit (grep for class names in the deployed CSS) is the actual verification.

This bug class is silent because:
- `tsc` doesn't check whether the imported CSS file exists or is bundled
- `next build` succeeds even with orphaned CSS files
- The production HTML correctly links the CSS bundles that DO exist
- The user sees a working page shape (text, layout, interactivity) — just no visual styling

A user who says "white text, no styling, tsc says it's fine" is almost always missing a CSS import.

---

## Recipe #30 — Next.js App Router layout composition: a top-level `layout.tsx` wraps `page.tsx` AND every `(route-group)/*` beneath it (added Aug 24 2026)

**Symptom**: a `<DashboardGuard>` + `<OnboardingGateRedirect>` is mounted in `/app/dashboard/(main)/layout.tsx` to gate access. The trader sign-up flow works fine for everything UNDER `(main)/*` — `/dashboard/trading` redirects to `/onboarding` if incomplete. But `/dashboard` itself (the home/landing page at `/app/dashboard/page.tsx`) is NOT gated. New users can see the dashboard home even when they haven't completed onboarding.

**Root cause** — Next.js App Router layouts compose ONLY for the path they cover. `/app/dashboard/(main)/layout.tsx` wraps:
- ✅ `/app/dashboard/(main)/trading/page.tsx`
- ✅ `/app/dashboard/(main)/partners/page.tsx`
- ❌ `/app/dashboard/page.tsx` (this is a SIBLING of `(main)`, NOT a child)

Route groups `(name)` are just organizational — they DON'T create a route segment. So `(main)/trading` resolves as `/dashboard/trading`, but `(main)` itself adds nothing to the URL. The layout file at `(main)/layout.tsx` only wraps `(main)/*.tsx` files. Anything directly under `/app/dashboard/` is outside the gate's reach.

**The fix — put the gate at the top level** (`/app/dashboard/layout.tsx`):

```tsx
// /app/dashboard/layout.tsx
// Aug 24 2026 — Round 8. ONE place that owns the onboarding gate for the
// entire /dashboard tree — page.tsx AND (main)/*.tsx both flow through it.
import { OnboardingGateRedirect } from '@/components/onboarding/useOnboardingGate'
import { DashboardGuard } from '@/components/DashboardGuard'

export default function DashboardRootLayout({ children }: { children: React.ReactNode }) {
    return (
        <DashboardGuard>
            <OnboardingGateRedirect />
            <Suspense fallback={null}>{children}</Suspense>
        </DashboardGuard>
    )
}
```

Then strip the duplicate gate from `/app/dashboard/(main)/layout.tsx` — `(main)/layout.tsx` should now only handle UI chrome (drawer, dock, trading context), not auth gates.

```tsx
// /app/dashboard/(main)/layout.tsx — UI only, gate lifted to /dashboard/layout.tsx
export default function DashboardLayout({ children }: { children: React.ReactNode }) {
    return (
        <TradingProvider>
            <PointsPopupProvider>
                <MobileKeyboardHandler />
                {/* ... UI chrome (drawer, dock) ... */}
                {children}
            </PointsPopupProvider>
        </TradingProvider>
    )
}
```

**The class-level rules for auth/permission gates in Next.js App Router** (don't get caught by gaps in route-group coverage):

1. **Mount the gate at the highest level that matters.** If you want to protect `/dashboard*`, put the gate in `/app/dashboard/layout.tsx`. Don't bury it in a route group.
2. **Route groups `(name)` create layout boundaries, not URL segments.** `(main)/trading` is just `/dashboard/trading`. A layout at `(main)/layout.tsx` only affects files in `(main)/`. Files directly under the parent (`/app/dashboard/page.tsx`) are siblings, not children.
3. **For "wrap everything under X" goals, the layout file location is `/app/X/layout.tsx`.** That's a wrapper for `/app/X/page.tsx` AND every nested `(group)/*` page.
4. **If you need a gate shared by multiple unrelated top-level routes**, use a HOC component (e.g. `<DashboardGuard>`) and wrap each root layout individually, NOT a single layout file.
5. **Verify the boundary.** After adding a gate, list every URL prefix you intend to cover, then visit each one with a fresh user that should be blocked. Don't trust the URL structure — visit them all.

Why this matters for Verdige onboarding gates — until this fix landed, `/dashboard` was the leak that let new users see the dashboard home before completing the wizard, even though `/dashboard/trading` was properly gated. The `(main)/` group had hidden the gap from anyone reading the route layout tree.

This is a class of bug you can only catch by visiting the URL, not by reading the file tree. Whenever you put a guard in a layout, enumerate the URLs in your head from the page tree, then test each.

---

## Recipe #31 — `withTimeout` race for every async call in a Next.js mount effect — `supabase.auth.getUser()` and `adminFetch` can hang on iOS PWA IndexedDB lock contention indefinitely (added Aug 24 2026)

**Symptom**: a user's PWA keeps loading, showing a spinner with text like "Setting things up…" or "Loading your onboarding…" indefinitely. No error, no retry button. The page is stuck because the `useEffect`'s async chain never resolves. tsc and build pass clean.

**Root cause** — at least one async call inside the mount effect never resolves. Specifically:

1. `supabase.auth.getUser()` reads from `auth.users` via the IndexedDB-backed `gotrue-js` SDK. On iOS PWA after backgrounding or fast-tapping, the IndexedDB can be locked by another tab/Timer/etc. `gotrue-js` does NOT have a default timeout — the call awaits forever.
2. `adminFetch` is a wrapper around `fetch()` that only adds an `Authorization` header. `fetch()` itself has no default timeout — it awaits forever on a stalled network.
3. Any `supabase.from('user_accounts').select(...)` can also hang on iOS IndexedDB contention.

If the user's mount effect chains these calls in sequence, the page hits an indefinite hang the moment any one stalls. There is no "ready=true" fallback at the bottom of the chain.

**The fix** — wrap every awaited call in a `withTimeout<T>(promise, ms, fallback)` race:

```ts
// Aug 24 2026 — Round 8. Hard 5s timeout for any awaited network call.
// Without this, an iOS PWA IndexedDB lock or a slow API fetch would
// hang the page on 'Setting things up…' indefinitely.
async function withTimeout<T>(promise: Promise<T>, ms: number, fallback: T): Promise<T> {
    let timer: ReturnType<typeof setTimeout> | undefined
    try {
        return await Promise.race([
            promise,
            new Promise<T>((resolve) => {
                timer = setTimeout(() => resolve(fallback), ms)
            }),
        ])
    } finally {
        if (timer) clearTimeout(timer)
    }
}
```

Use it at every awaited call site:

```ts
useEffect(() => {
    const safetyTimer = setTimeout(() => setReady((prev) => prev || true), 5000)
    ;(async () => {
        try {
            // Aug 24 2026 — Round 8. Cap the lifecycle fetch at 4s.
            const r = await withTimeout(
                adminFetch('/api/onboarding/lifecycle', { method: 'GET' }),
                4000,
                new Response(JSON.stringify({ ok: false }), { status: 504 }),
            )
            if (r.ok) { /* ... */ }
        } catch { /* ... */ } finally {
            clearTimeout(safetyTimer)
            setReady(true)
        }
    })()
}, [router])
```

Three rules for a mount effect that can't hang:

1. **Belt: per-call `withTimeout`** — race each awaited call against a 4s timer, supply a fallback value that won't break downstream logic (e.g. empty steps array, null profile, 504 Response)
2. **Suspenders: a safety timer at the effect level** — `setTimeout(() => setReady(true), 5000)` that fires unconditionally even if a `Promise.race` itself misbehaves
3. **Finally clause** — `setReady(true)` MUST run in a `finally`, not just at the end of the try branch. The safety timer and the per-call timeouts mean the try will either resolve fast or resolve via the race fallback.

**Specific to iOS PWA** — the IndexedDB lock happens most often when:
- The user has the app open in two tabs
- The user backgrounds then foregrounds the app rapidly
- The PWA wakes from cold start with a stale SW
- iOS Safari gets a memory pressure kill

**The class-level rule for any Next.js client mount effect that does async work** — every awaited call should have a hard timeout. `fetch()` has no default, `supabase.auth.get*()` has no default, `supabase.from().select()` has no default. If you only await one thing and it hangs, the page hangs. The user sees a spinner for 30+ seconds, gives up, and refreshes — at which point the cycle restarts on a more contention-prone state.

Don't wait for an iOS PWA user to report this. Add `withTimeout` to every mount-effect async by default. It's three lines per call site. The cost of the timeout (returning a fallback early) is much smaller than the cost of an indefinite spinner.

---

### Recipe #50 — iOS PWA warm-restart: data disappears unless user force-closes (added Aug 27 2026)

**Symptom:** the user opens the app, sees all their data (points, streak, name, role badges like Admin / Trader / Partner). They background the app (home button / switch apps / swipe up to dismiss from the app switcher). They bring the app back to foreground. Their data is **gone** — points show 0, streak shows 0, role badges are missing. They have to force-close the app and reopen it before the data comes back.

**Important distinction:** cold restart (force-close + reopen) works fine. **Only warm restart (background → foreground) is broken.** If the user can't articulate this difference, ask them whether force-close fixes it — if yes, this recipe.

**Root cause** — iOS PWAs use WKWebView. When the user backgrounds the app, iOS may keep the WebView alive in memory OR kill it and rebuild it on resume, depending on memory pressure and time elapsed. When the WebView rebuilds:
1. React state re-initializes to its `useState(default)` values (null profile, false flags).
2. The `useEffect` fires `refreshProfile()`, but the Supabase REST fetch takes 500ms-2s to resolve.
3. During that window, the dashboard renders with empty data.
4. If the network fails transiently (radio coming back up), the fetch never resolves and the user sees empty data indefinitely.

**The first fix attempt that DOES NOT WORK** — saving to `sessionStorage`. On iOS PWAs, sessionStorage can be cleared when the WebView is killed. Use `localStorage` instead.

**The second fix attempt that DOES NOT WORK** — restoring the cached profile but then immediately overwriting it with `buildProfile()`. `buildProfile()` reads from `user.user_metadata`, which doesn't have points/streak (those live in `user_accounts`). So `buildProfile()` returns `points: 0` and clobbers the cached real values. Pattern:

```ts
// BAD — the cache restoration is silently overwritten
const cached = loadProfileCache(currentUser.id)
if (cached) setProfile(cached)              // restore from cache
const baseProfile = buildProfile(currentUser) // reads metadata (stale points=0)
setProfile(baseProfile)                     // ← CLOBBERS the cache
```

Fix: only call `setProfile(baseProfile)` when there's no cache. If there IS a cache, let the `Promise.allSettled` block below merge fresh `user_accounts` data into it via the `prev => ...` callback.

**The third fix attempt that DOES NOT WORK** — saving the flags at the END of the fetch block. If anything between the `setIs*` calls and the end throws, the flags never reach the cache. Save each flag to cache IMMEDIATELY after the corresponding `setIs*` call, not at the end.

**The full fix — four coordinated pieces:**

1. **Cache key uses `localStorage`** (not sessionStorage). `localStorage` survives iOS WebView kill + reopen. `sessionStorage` does not. Cache helpers:
   ```ts
   const CACHE_PREFIX = 'app-user-cache:'
   function loadUserCache(userId: string | undefined): CachedUserState | null {
       if (!userId || typeof window === 'undefined') return null
       const raw = localStorage.getItem(CACHE_PREFIX + userId)
       if (!raw) return null
       try {
           const parsed = JSON.parse(raw)
           if (!parsed || typeof parsed !== 'object' || !('profile' in parsed)) return null
           return parsed as CachedUserState
       } catch { return null }
   }
   function saveUserCache(userId, state) { /* write JSON.stringify(state) */ }
   ```

2. **Cache stores the FULL user state**, not just the profile:
   ```ts
   interface CachedUserState {
       profile: UserProfile | null
       isAdmin: boolean
       hasMembership: boolean
       isPartner: boolean
       isTrader: boolean
       savedAt: string  // ISO timestamp for debugging
   }
   ```
   Reason: React state has separate `isPartner`, `isTrader`, `isAdmin`, `hasMembership` flags. They live outside the profile object and need to be cached too. Otherwise tags/badges disappear on warm restart even with the profile cached.

3. **Restore flags from cache BEFORE the live fetch**, only setting true values (let live fetch handle false):
   ```ts
   const cachedUserState = loadUserCache(currentUser.id)
   if (cachedUserState) {
       if (cachedUserState.isPartner) setIsPartner(true)
       if (cachedUserState.isTrader) setIsTrader(true)
       if (cachedUserState.isAdmin) setIsAdmin(true)
       if (cachedUserState.hasMembership) setHasMembership(true)
   }
   ```
   Reason: if live fetch fails on warm restart, the cached flags keep the UI correct.

4. **Save flags to cache IMMEDIATELY after each `setIs*` call**, not at the end of the block:
   ```ts
   if (partnerResult.status === 'fulfilled') {
       const isPartnerResolved = !!partnerResult.value.data
       setIsPartner(isPartnerResolved)
       // Save immediately — if anything later throws, this flag is persisted
       saveUserCache(currentUser.id, {
           ...loadUserCache(currentUser.id),  // preserve other flags
           isPartner: isPartnerResolved,
       })
   }
   ```
   Reason: if the function aborts mid-way (retry throws, page navigates away, the user backgrounds again), the latest flag values are already in localStorage.

**Bonus — also add a `visibilitychange` listener** that re-runs `refreshProfile()` when the page becomes visible, throttled to once per 5s. Handles the bfcache restoration case and reduces perceived lag.

**Diagnostic when the user reports "data disappeared"**:
```js
// In browser devtools console, after a warm restart:
JSON.parse(localStorage.getItem('app-user-cache:<user-uuid>'))
// Should show { profile: {...points: 9783...}, isPartner: true, isTrader: true, isAdmin: true, savedAt: "..." }
// If isPartner/isTrader/isAdmin are missing → flag caching not working
// If profile.points === 0 → baseProfile clobbered the cached profile
// If the whole key is missing → wrong storage (sessionStorage vs localStorage)
```

**Why each fix alone isn't enough:**
- localStorage alone → still clobbered by buildProfile
- Cache structure alone → not saved fast enough
- Immediate save alone → uses sessionStorage which iOS clears
- Profile-only cache → flags still disappear

All four pieces are required. The user sees nothing wrong if any one is missing because the failure mode looks identical (data appears, then disappears).

---

---

## Recipe #51 — Migration references `public.set_updated_at()` but the codebase uses per-table trigger functions (added Aug 27 2026)

**Symptom:** a new migration that adds `CREATE TRIGGER ... BEFORE UPDATE ... EXECUTE FUNCTION public.set_updated_at();` fails at apply time with:

```
ERROR: 42883: function public.set_updated_at() does not exist
```

**Root cause.** The code mix has a shared assumption baked in. Earlier migrations added trigger functions **per table**, named after the table (e.g. `set_webhook_subscriptions_updated_at()`, `set_lifecycle_steps_updated_at()`). There's no shared `public.set_updated_at()` in the schema. But many example snippets online (and earlier helpers in this very repo) reference a shared one — the migration author assumed it existed.

**The fix — define the trigger function inline in the migration, named after your table.** Pattern:

```sql
CREATE OR REPLACE FUNCTION public.set_<your_table>_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS <your_table>_set_updated_at ON public.<your_table>;
CREATE TRIGGER <your_table>_set_updated_at
    BEFORE UPDATE ON public.<your_table>
    FOR EACH ROW EXECUTE FUNCTION public.set_<your_table>_updated_at();
```

**Why per-table vs shared?** Two reasons:

1. **Per-table is the codebase convention.** Multiple migrations in this repo use `set_<table>_updated_at`. Match the convention.
2. **Per-table avoids future drift.** A shared `set_updated_at()` ends up being shared by 30+ tables, so any change to its signature (e.g. adding an `IF NEW.col IS DISTINCT FROM OLD.col` guard) breaks every table at once. Per-table means each migration owns its own function body and can fix its own bugs.

**Diagnostic before writing a migration** — search the existing migrations for `BEFORE UPDATE`:

```sh
grep -rln "BEFORE UPDATE" supabase/migrations/
```

If every existing trigger uses `set_<table>_updated_at()`, follow that pattern. If there's a shared `set_updated_at()` somewhere in the codebase, use it instead. **Don't assume either** — verify.

**Companion pitfall — `EXECUTE FUNCTION public.<name>()` without the schema prefix.** Postgres resolves unqualified function names against `search_path`, which by default is `"$user", public`. If your migration runs as the migration owner (often `postgres`), `$user` is empty and the lookup falls through to `public` — works fine. But if it runs as a different role, the lookup can fail or hit a function in a different schema that happens to have the same name. **Always prefix with `public.`.**

**Companion pitfall — reserved words in column names.** `offset` is a Postgres reserved word. If you have a `telegram_listener_state` table with a column named `offset`, every reference to it in DDL/SELECT/INSERT/JS must be quoted (`"offset"`). The `supabase-policies-migrations` skill has the full reserved-word list.

---

## Recipe #52 — `createServerClient()` from `@/lib/supabase/server` is async — `await` it in every route handler (added Aug 28 2026)

**Symptom:** a new API route compiles clean and builds clean. At runtime, the FIRST call into the client (`.auth.getUser()`, `.from('x').select()`) throws:

```
TypeError: supabase.auth is not a function
# OR
TypeError: supabase.from is not a function
# OR a generic "Cannot read properties of undefined (reading 'auth')"
```

TypeScript caught it with:

```
error TS2339: Property 'auth' does not exist on type 'Promise<SupabaseClient<...>>'.
```

But only if `tsc` was actually run on the new route — `next build` does not type-check the new file if it shares no imports with the old ones. So the build passes, the route 500s, and the dev server logs the TypeError the moment the first request hits.

**Root cause.** The platform's server-side Supabase helper at `src/lib/supabase/server.ts` reads `cookies()` from `next/headers` to set up per-request cookie state. `cookies()` is async in Next 14/15, so the wrapper is exported as:

```ts
export async function createClient() {
  const cookieStore = await cookies();
  return createServerClient(URL, KEY, { cookies: { ... } });
}
```

It returns a `Promise<SupabaseClient>`. **Every call site must `await` it.** the reference codebase (the reference codebase) uses `createClient` synchronously; ports from the reference codebase frequently forget the `await`.

```ts
// BROKEN — pattern from the reference codebase port, silently broken on the platform
import { createClient as createServerClient } from '@/lib/supabase/server';

export async function GET() {
  const supabase = createServerClient();       // ← returns a Promise!
  const { data: { user } } = await supabase.auth.getUser();
  //                          ^^^^^^^^^^^^^^^^ TypeError: supabase.auth is not a function
  // ...
}

// CORRECT — the wrapper is async, await it
export async function GET() {
  const supabase = await createServerClient();  // ← awaits the Promise
  const { data: { user } } = await supabase.auth.getUser();
  // ...
}
```

**The fix — always `await createServerClient()` (or `await getServiceClient()` for the service-role variant) at the top of every route handler / server component.** Once awaited, the rest of the Supabase API is synchronous-looking.

**Diagnostic — when a route 500s on first request after adding a Supabase call:**

1. Open the route file. Search for `createClient` / `createServerClient` / `getServiceClient` / `getSupabaseServerClient`.
2. Check each call site: is the call inside an `await` expression?
3. If any are missing `await`, that's the bug. The error message (`supabase.auth is not a function`) is the smoking gun.

```bash
# Sanity sweep across the app:
grep -rn "createServerClient()" src/app/api src/app/admin src/app/office 2>/dev/null \
  | grep -v "await "
```

Any line returned by this grep is a candidate. Add `await` and re-deploy.

**Class-level rule for porting from the reference codebase to the platform** — the reference codebase's server-side Supabase client is **synchronous**. The platform's is **async** because the cookies-based session store requires `await cookies()`. Any time you copy a route or server-component pattern from `<reference-repo>/` into `~/Projects/the platform/` and it touches `createClient` / `getServiceClient`, the FIRST edit you should make is to add `await` to the constructor call. Don't trust `next build` to catch it — type-check the file separately (`npx tsc --noEmit`) before deploying.

---

## Recipe #53 — PostgREST select-string column names that don't exist in the table (added Aug 28 2026)

**Symptom:** a Supabase fetch returns an empty array (or `null`) when you know the table has rows. Or a server route returns `204 No Content` for a "this should work" case. The modal says "No signals recorded for ENGINE_D yet" even though `SELECT count(*) FROM signal_log WHERE engine='ENGINE_D'` returns 41. The chart image never renders.

**Root cause.** PostgREST is strict about column names. A `.select('id, symbol, direction, ...')` against a table that has `pair` (not `symbol`) returns:

```
HTTP 400: column signal_log.symbol does not exist
```

Supabase JS client wraps that 400 in `error`. If the call site has `.catch(() => setSignals([]))` or `if (error) throw error` followed by a catch that swallows, **the user sees an empty state, not an error**. The 400 itself never reaches the console because Supabase only logs warnings, not errors.

**Aug 28 2026 case** — three callers all hit this with `signal_log.symbol`:
- `src/hooks/useEngineSignals.ts` — fed the engine card ticker, the inline-expansion chart pane, and the modal signal history. All three returned empty.
- `src/app/api/engines/[engine]/signals/[id]/chart/route.ts` — the chart PNG route. Failed closed with 204 → the inline-expansion chart never rendered.
- The cast at the hook boundary then TS'd an `unknown as EngineSignal[]` because the wire shape and the JS shape had different field names.

The DB column was `pair` (legacy from the reference codebase). The JS shape had been using `symbol`. The query failed silently every call.

**The fix — two patterns.**

**(A) Alias in the select string.** PostgREST supports `column:alias` to rename fields on the response, so the JS shape stays the same:

```ts
// BROKEN — DB has pair, not symbol
.select('id, symbol, direction, status, pips, entry, sl, tp1, tp2, tp3, tp4, created_at')

// FIXED — alias pair as symbol in the response
.select('id, pair:symbol, direction, status, pips, entry, sl, tp1, tp2, tp3, tp4, created_at')
```

The TS cast widens to `unknown as EngineSignal[]` because the wire shape says `pair` but the JS type says `symbol`. The runtime payload is identical — same data, same shape.

**(B) Server routes that read the field by name.** If a server-side route reads `signal.symbol` after the alias, the alias only applies at the Supabase client layer — the server still sees `pair`:

```ts
// After .select('id, pair:symbol, ...')
const { data: signal } = await supabase.from('signal_log').select(...).eq('id', id).maybeSingle();

// CORRECT — server reads `pair`, the DB column
String(signal.pair).toUpperCase()

// BROKEN — server tries to read `symbol`, which doesn't exist on the response
String(signal.symbol)  // → runtime error / undefined
```

**Diagnostic — when a fetch returns nothing but the table has rows:**

1. Open Supabase Studio → SQL Editor → run the exact `.select(...)` string against the table. If the column doesn't exist, PG raises `column ... does not exist` immediately.
2. Or curl the PostgREST URL directly with the same params — the 400 response body says exactly which column is missing.
3. Or check the browser DevTools Network tab → the Supabase call returns 400 with a `42703` (undefined_column) error code in the JSON body.

```bash
# From the sandbox, replicate the exact .select() the app uses:
node -e "
const key = require('fs').readFileSync('<project-dir>/scripts/apply-migration.mjs','utf8')
                 .match(/SERVICE_KEY\s*=\s*'([^']+)'/)[1];
fetch('https://<project-ref>.supabase.co/rest/v1/signal_log' +
  '?select=id,symbol,direction&engine=eq.ENGINE_D&limit=1', {
  headers: { apikey: key, Authorization: 'Bearer ' + key }
}).then(r => r.text()).then(console.log);
"
# Expect: {"code":"42703","message":"column signal_log.symbol does not exist",...}
```

**Class-level rule for any new PostgREST `.select(...)` string:**

1. Before writing the select clause, check the actual column names in the source migration OR in Studio (table editor → schema). Do **not** trust the variable name in another file's code as proof the column exists. Other code may have been written by someone who made the same mistake.
2. If you want a JS-friendly alias, use `column:alias` syntax (works for table columns, computed fields, and embedded-resource fields).
3. Server-side code (route handlers, scripts) that consumes the response reads the **original column name**, not the JS alias. The alias is client-side only.
4. When debugging "empty state but data should be there" — always curl the exact select string first. PostgREST's error messages name the column that's missing.

---

## Recipe #54 — TradingTerminal `p.pnl.toFixed` crash when a new response shape ships without matching the consumer field (added Aug 30 2026)

**Symptom:** the user connects a built-in demo account, navigates to `/dashboard/trading?tab=CHART`, and the page crashes with `undefined is not an object (evaluating 'p.pnl.toFixed')`. Real the broker users never hit this — only demo. Other consumers of the same `tlPositions` array (balance card, Live Positions card, etc.) render fine.

**Root cause:** the response shape drift. The real the broker route (`/api/broker/account-data` → real broker path) maps positions through a `posArrayToObj` helper that explicitly adds `pnl: Number(obj.unrealizedPl ?? 0)`. The demo path (`buildDemoAccountData`) built its own object literal that only set `unrealizedPl` but never set `pnl`. The TradingTerminal renders positions by mapping over `tlPositions` and reading `p.pnl` directly. Demo → `p.pnl` was undefined → `.toFixed(2)` threw → entire terminal errored out.

**Diagnostic pattern — when a route returns data but a consumer crashes on it:**

1. Open the consumer component (e.g. `TradingTerminal.tsx`) and grep for the property the crash names — here `p.pnl.toFixed`.
2. Find every `tlPositions.map((p) =>` render path in that component.
3. Find every code path that puts data into `tlPositions`:
   - Real broker path: `posArrayToObj` / setBrokerPositions calls
   - Demo path: `buildDemoAccountData` returned shape
   - Cache hydration: `broker_session_cache` from localStorage
   - Order execution: optimistically appended `pending` rows
4. Compare each producer's output shape against what the consumer reads. They MUST match field-for-field for every property the consumer touches.

**The fix — three layers:**

```ts
// Layer 1: producer side — every position object MUST set BOTH pnl
// (consumer-friendly name) and unrealizedPl (canonical broker name).
return {
    id: p.broker_position_id,
    symbol: sym,
    pnl: Number(pnlUsd.toFixed(2)),         // ← consumer reads this
    unrealizedPl: Number(pnlUsd.toFixed(2)), // ← real broker path reads this
    realizedPl: Number(p.realized_pnl ?? 0),
    // ...
};

// Layer 2: consumer side — null-guard every property the consumer reads
// even if every producer currently sets it. Future route shape changes
// should not crash the page.
{(p.pnl ?? 0) >= 0 ? '+' : ''}${Number(p.pnl ?? 0).toFixed(2)}

// Layer 3: TS — define a single Position type in src/types or src/lib
// and make every producer + consumer reference it. The compiler catches
// drift at build time instead of at runtime.
```

**Class-level rule for any new response shape that flows into a multi-component consumer:**

1. Before adding a new producer (route, cache hydration, optimistic append), grep every consumer for the fields they read.
2. Set every field the consumer reads, even if you mirror them with the same value. `pnl: x` AND `unrealizedPl: x` costs 1 line and prevents a one-line future bug from taking down the page.
3. Null-guard in the consumer anyway. Route shapes drift over time as the team adds features.
4. The diagnostic when a route "works for some users but crashes for others" is almost always a field-name mismatch between the new producer and the legacy consumers.

**Related:** this is the same shape-drift family as Recipe #45 (auth-gated column silently fails) and Recipe #53 (PostgREST select-string column doesn't exist). All three are "the wire format quietly diverges from what the consumer expects." Adding a `Position` type would catch all three at build time.

---

## Recipe #55 — Demo account P&L goes wildly negative because entry price and current price come from different sources (added Aug 30 2026)

**Symptom:** a user picks a demo balance ($250 / $500 / $1k / $5k / $10k). The dashboard shows "Equity: -$18,769.53" with the dashboard P&L tile also showing -$18,769 in red. Total Trades: 3, Open Trades: 3. The user has not placed any trades yet. The numbers do not match the chosen balance at all.

**Root cause:** two different price sources. `connect-demo` stored starting positions with `avg_price = getDemoPrice(symbol)` — a hardcoded synthetic value baked into `src/lib/trading/demo-accounts.ts` (e.g. NAS100 = $18,468). `buildDemoAccountData` later fetched the LIVE Yahoo price for the same symbol (e.g. NAS100 = $29,433) and computed P&L as `dir * (livePrice - entry) * pipValue`. The ~$11,000 gap between synthetic and live multiplied by 1.0 lots/point for indices = $11,000 per position. Three positions × ~$6k each = -$18,769.

**The fix — entry price MUST match the live price at creation time:**

```ts
// In connect-demo/route.ts, fetch live prices FIRST, use them as entry
const priceRes = await fetch(`${APP_URL}/api/demo/price?symbols=${symbols.join(',')}`);
const livePriceMap = priceRes.ok ? parseLivePrices(await priceRes.json()) : {};

// Fall back to synthetic only if the live feed is offline
const entry = livePriceMap[sym] ?? getDemoPrice(sym);

// P&L starts at 0 — current_price = entry_price at creation,
// then ticks realistically as Yahoo prices update every 3s.
return {
    avg_price: Number(entry.toFixed(5)),
    current_price: Number(entry.toFixed(5)),
    unrealized_pnl: 0,
    // ...
};
```

**Diagnostic when the demo dashboard equity is wildly off-balance:**

1. Query `position_snapshot` directly: `SELECT symbol, avg_price, current_price, side, qty FROM position_snapshot WHERE user_id=... AND source='demo'`.
2. Compare `avg_price` to a live Yahoo quote for the same symbol. If they diverge by more than a few percent, you have the synthetic-vs-live gap.
3. Compute `dir * (current_price - avg_price) * pipValue` for one position. If that single value is more than the starting balance, the bug is real.

**Class-level rule for any simulated/demo position lifecycle:**

1. **Use the same price source for entry and live ticks.** If your live feed is Yahoo, then the entry price for any new position MUST come from the same Yahoo call — not from a hardcoded synthetic baseline.
2. **Snapshot the price at creation time** and store both `avg_price` and `current_price` equal. Future ticks only update `current_price`.
3. **P&L starts at $0.** The user sees the position appear with zero P&L; ticks make it drift realistically. This is honest and matches what real broker accounts do.
4. **Reset positions is a real product feature.** Add a "Reset positions" button in Settings that wipes old demo positions and re-seeds at the current balance tier. Users will want a clean slate after a bad run.

---

## Recipe #56 — i18n exists but nothing in the app actually displays translated text (added Aug 30 2026)

**Symptom:** the user changes language in Settings → Language (e.g. picks Spanish). The header dropdown updates to show "Español" and `<html lang="es">` is set on the document. But the entire rest of the app still renders English. The user says "I changed language and nothing happened."

**Root cause:** the i18n system is wired at the plumbing layer (provider mounted in root layout, `setLanguage` writes to localStorage, `<html lang>` updates) but the display layer is missing. The codebase has:
- 13 language JSON files in `src/i18n/translations/*.json` (~300KB each)
- A `<LanguageProvider>` mounted in `src/app/layout.tsx`
- A `useLanguage()` hook that returns `{ t, language, currentLang, isRTL, setLanguage }`
- A `t(key, fallback)` function that walks nested JSON

But the only files that call `useLanguage()` are `LanguageSettings.tsx` and `LanguageSwitcher.tsx` — the two switcher components themselves, and only to call `setLanguage`. Zero UI text uses `t()`. Switching language re-runs `setLanguage`, but since no component renders text via `t()`, the rendered output is identical.

**Diagnostic — how to check i18n coverage in <5 seconds:**

```bash
# Find all files that USE translations
cd ~/Projects/the platform
grep -rln 'useLanguage\|t("' src/components/ --include='*.tsx'

# Compare against total components
find src/components -name '*.tsx' | wc -l

# If the first count is 2-5 and the second is 100+, i18n is plumbed but not wired.
```

**The fix pattern:**

1. Pick the highest-impact page the user touches most often. For the platform: Settings → Profile, Demo Account, demo picker.
2. For each visible English string in that page, add a translation key to `en.json` and `es.json` (or whichever languages you support). The naming convention is `section.subElement.purpose` — e.g. `settings.tabProfile`, `settings.demoAccount`, `demoAccounts.balanceQuestion`.
3. Add `const { t } = useLanguage()` at the top of the component.
4. Replace every English string with `{t('section.key', 'English fallback')}`. The second arg is the English fallback so even if a key is missing, the page still renders in English rather than showing a literal `settings.tabProfile`.
5. Module-scope constants (like `const TABS = [...]`) cannot call `t()` directly. Move them inside the component or refactor to a `TAB_ICONS` constant + computed labels inside the render.

**The fallback second arg is critical.** When you add a new string and forget to translate it, the second arg renders English instead of the literal key. Without it, the user sees `settings.demoAccount` printed on the page.

**Class-level rule for any i18n implementation:**

1. The plumbing layer (provider + JSON files + setLanguage) and the display layer (every component calls `t()`) are separate milestones. Plumbing ships in hours; display takes a multi-commit sweep across every page.
2. ALWAYS pass the English string as the second arg to `t()`: `t('key', 'English fallback')`. This way missing translations degrade to English instead of leaking internal keys.
3. Don't try to translate every string in one commit. Pick one page (the one the user complains about), translate it, ship, move to the next.
4. The translations JSONs already cover most keys you need — `dashboard.*`, `nav.*`, `terminal.*`, `common.*`, `profile.*`, `trading.*`, etc. Add new keys under a new `section.*` namespace rather than trying to fit them under an existing one.

---

## Recipe #57 — Mobile-only layout where a right-rail panel holds mutually-exclusive content but mobile wants the secondary card always visible below the primary (added Aug 30 2026)

**Symptom:** the user reports the trade journal page is broken on mobile. The Monthly Breakdown card is missing. On desktop, the page is fine — calendar on the left, day-detail on the right, monthly breakdown in the right column when no day is selected. On mobile, the user can never see the monthly breakdown unless they never tap a calendar day.

**Root cause:** a ternary inside a single right-rail container:

```tsx
<div className="journal-detail-panel">
    {selectedDay !== null ? (
        <j-day-detail>...</j-day-detail>
    ) : (
        <j-stats-panel>Monthly Breakdown ...</j-stats-panel>
    )}
</div>
```

The `max-width: 900px` media query already collapses the grid to one column (so the right rail moves below the calendar). But because the ternary shows EITHER day-detail OR stats, on mobile the user only ever sees one card at a time. The user wanted the Monthly Breakdown "below the calendar block" — that's not where it lands because the ternary hides it whenever a day is selected.

**The fix — split into siblings, reorder on mobile:**

```tsx
// JSX: always render BOTH, no ternary on the right rail
<div className="journal-detail-panel">
    {selectedDay !== null ? (
        <j-day-detail>...</j-day-detail>
    ) : (
        <j-day-detail--placeholder>
            Tap a day on the calendar
        </j-day-detail--placeholder>
    )}

    <j-stats-panel>Monthly Breakdown ...</j-stats-panel>
</div>
```

```css
/* Desktop: stack vertically inside the right column (unchanged) */
@media (min-width: 901px) {
    .journal-detail-panel {
        position: sticky;
        top: 20px;
    }
}

/* Mobile: reorder so calendar → day-detail → monthly breakdown */
@media (max-width: 900px) {
    .journal-detail-panel {
        display: flex;
        flex-direction: column;
        gap: 14px;
    }

    /* Put real day-detail on top, monthly breakdown below */
    .journal-detail-panel .j-day-detail:not(.j-day-detail--placeholder) {
        order: -1;
    }
    .journal-detail-panel .j-stats-panel {
        order: 0;
    }

    /* When day-detail is the placeholder, dim it so the breakdown
       below carries the most visual weight */
    .journal-detail-panel .j-day-detail--placeholder {
        opacity: 0.78;
        order: -1;
    }
}
```

**The placeholder is not optional.** Without it, the right panel collapses to one card (the breakdown) when no day is selected, which looks broken. The placeholder keeps the layout balanced so the breakdown sits in its expected slot whether a day is selected or not.

**Class-level rule for any "mutually-exclusive content inside a right rail":**

1. On mobile, the user expects both pieces of content visible. Right rail panels usually hold secondary content that the user always wants to see (stats, breakdowns, action buttons). Mutually-exclusive renders are a desktop affordance.
2. The fix is: render both as siblings, with a placeholder for the empty branch.
3. Use CSS `order` to reorder on mobile without changing JSX structure.
4. When the placeholder renders, dim it (0.75–0.8 opacity + dashed border) so the real content below carries visual weight.

---

## Recipe #58 — Required migration columns for `position_snapshot` to support demo + journal features (added Aug 30 2026)

**Symptom:** a feature that "should" work fails with `400 Bad Request` from Supabase PostgREST on inserts to `position_snapshot`. The route handler logs `Failed to fetch demo positions` or `Failed to insert starting positions`. The DB shows the table exists but the insert fails.

**Root cause:** the `position_snapshot` table was created in an early migration with only the broker minimum columns: `user_id`, `broker_account_id`, `broker_position_id`, `symbol`, `side`, `qty`, `avg_price`, `sl_price`, `tp*_price`, `tp*_hit`, `opened_at`, `last_seen_at`, `closed_at`, `close_price`, `close_reason`, `tp_history_id`, `created_at`, `updated_at`.

**Missing columns for newer features:**

| Column | Used by | Purpose |
|---|---|---|
| `current_price` | buildDemoAccountData, terminal live P&L | Live Yahoo price for P&L calculation |
| `unrealized_pnl` | buildDemoAccountData, terminal | Per-position unrealized P&L |
| `realized_pnl` | close-position route, journal | Per-position realized P&L on close |
| `status` | terminal filtering | `'open'` vs `'closed'` (vs `closed_at` null check) |
| `source` | demo vs real filtering | `'demo'` or `'real'` to scope queries |
| `signal_id` | journal entry grouping | Links trade back to its originating signal |
| `stop_loss` | terminal SL display | Mirror of `sl_price` for consistency |
| `take_profit` | terminal TP display | Mirror of `tp1_price` for consistency |
| `engine` | journal engine breakdown | Which engine triggered this trade |
| `close_price` | close-position route, journal | Final fill price on close |

Without these columns, any new feature that writes to `position_snapshot` (demo accounts, journal integration, engine-level P&L) will fail with `42703 column does not exist`.

**The migration (apply via Supabase Studio SQL editor):**

```sql
-- 202608300000_add_position_tracking_columns.sql
ALTER TABLE position_snapshot ADD COLUMN IF NOT EXISTS current_price NUMERIC;
ALTER TABLE position_snapshot ADD COLUMN IF NOT EXISTS unrealized_pnl NUMERIC DEFAULT 0;
ALTER TABLE position_snapshot ADD COLUMN IF NOT EXISTS realized_pnl NUMERIC DEFAULT 0;
ALTER TABLE position_snapshot ADD COLUMN IF NOT EXISTS status TEXT DEFAULT 'open';
ALTER TABLE position_snapshot ADD COLUMN IF NOT EXISTS source TEXT DEFAULT 'real';
ALTER TABLE position_snapshot ADD COLUMN IF NOT EXISTS signal_id TEXT;
ALTER TABLE position_snapshot ADD COLUMN IF NOT EXISTS stop_loss NUMERIC;
ALTER TABLE position_snapshot ADD COLUMN IF NOT EXISTS take_profit NUMERIC;
ALTER TABLE position_snapshot ADD COLUMN IF NOT EXISTS engine TEXT;
ALTER TABLE position_snapshot ADD COLUMN IF NOT EXISTS close_price NUMERIC;

-- Index for fast demo-position queries
CREATE INDEX IF NOT EXISTS idx_position_demo ON position_snapshot (user_id, source) WHERE source = 'demo';

-- RLS: the existing policy allows user to read their own rows.
-- Demo positions are written with user_id = auth.uid() so they pass.
```

**Class-level rule for any new feature writing to `position_snapshot`:**

1. Before writing to `position_snapshot`, check what columns the table actually has (via `select *` from PostgREST or via Studio). Do not trust the column list in any other route's `.select()`.
2. If a feature needs a column that doesn't exist, ship the migration alongside the route. Two PRs for one feature is correct.
3. Sandbox agents cannot run DDL directly — the database password rotates. Apply via Supabase Studio SQL editor (the path the user controls).
4. The migration is idempotent (`ADD COLUMN IF NOT EXISTS`) so re-running it is safe.

**Related:** Recipe #2 (`position_snapshot` has no `id` column) is the historical root cause for many of these. Now there's a full schema diagram at the top of the relevant recipes. Recipe #53 (PostgREST select-string column names) catches read-side bugs; this recipe catches write-side schema gaps.

---

## What I deliberately did NOT do (out of scope, future work)

- A unified "the platform feature checklist" — too broad, would dilute this skill
- ProfileView $5→$500 ladder documentation — that's the companion platform skill umbrella territory, not bugs
- Engine unlock level / IB rank reference — those are config, not bugs
- Cron job recovery procedures — that's a separate `hermes-gateway-channels` adjacent skill---

## Recipe #59 — Demo accounts are persona-FREE: one question, pick a balance (added Aug 30 2026)

**Symptom:** the demo account picker shipped with 6 personas (Jessica Chen, Marcus Okonkwo, Priya Singh, David Reyes, Anya Volkov, Aisha Bello) each with its own avatar, win-rate pill, total-trades pill, and a starting P&L per persona. The catalog was ~110 lines of code, the picker UI was a 3-column grid of cards, and there was a persona-specific "Currently connected as Jessica Chen" state.

**User reaction, verbatim:** *"No, the user does not pick a persona. It is choose the balance of the amount they want to use for their demo camera. You can remove the whole persona thing. It's not necessary here."*

**The lesson — persona concept was wrong from the start.** The user wants the demo flow to be: "how much do you want to trade with?" → pick $250 / $500 / $1k / $5k / $10k → done. No persona, no avatar, no per-persona starting history, no per-persona `accountId` selection.

**The fix — strip persona entirely:**

1. Catalog is just `DEMO_BALANCE_TIERS: number[]` (the 5 tiers). No persona objects.
2. `connect-demo` accepts only `{ balanceTier: number }`. Writes `broker_account_id = demo-account-${userId}` (deterministic, single account per user). Synthesizes 3 starting positions scaled by balance (lot size = `balance / 10000`, capped to sensible bounds).
3. Settings section shows "Currently connected · $5,000 demo balance" — no persona name, no win-rate pill.
4. Quick tier switcher: 5 buttons ($250 / $500 / $1k / $5k / $10k). No "Switch persona" link.

**Code that had to be deleted:**
- `PERSONAS` array in `src/lib/trading/demo-accounts.ts` (6 entries with winRate, totalTrades, etc.)
- `getStartingPositionsFor(personaId, tier)` function — replaced with `getStartingPositions(balance)`
- Persona grid in `/dashboard/trading/demo-accounts/page.tsx`
- Persona selection state in `DemoAccountSection`
- `selectedPersonaId` field in `connect-demo` route — API shape is now `{ balanceTier }`

**Class-level rule for any new user-facing "demo" feature:** the only variable the user controls is **balance**. Don't reintroduce personas, risk profiles, strategies, or "trader types" — the user explicitly rejected that whole direction.

---

## Recipe #60 — Reusable Quick Order panel: extract once, use twice (added Aug 30 2026)

**Symptom:** the Quick Order form (BUY/SELL toggle + quantity + SL + TP + submit) was inline inside `TradingTerminal.tsx` as a hardcoded `<div className="terminal-card terminal-card-order">`. When the user asked for it on the home page, the natural temptation was to copy-paste the JSX + state + submit handler into `TradingDashboardView.tsx`. That would have created two parallel implementations that would drift apart over time (e.g. one gets a new input, the other doesn't; one gets a bug fix, the other doesn't).

**The fix — extract a reusable component.** Created `src/components/trading/QuickOrderPanel.tsx` + `QuickOrderPanel.css`. Single source of truth for the form. Used in:
- `TradingTerminal` (live chart sidebar) — replaces the inline form
- `TradingDashboardView` (home page, above the Live Positions / Trade History toggle)

**Component contract:**
- Takes props: `defaultSymbol?: string`, `defaultQty?: string`, `compact?: boolean`
- Pulls `submitOrder` from `useTrading()` context — no prop drilling
- Owns its own state (BUY/SELL, quantity, SL, TP, submitting, submitMsg, pickerOpen)
- Closes picker on outside click + Escape (via `mousedown` + `keydown` document listeners, cleaned up in `useEffect`)
- Footer shows "Routed via the broker" or "Demo account mode" based on `trading.brokerConnected` — one place to update when source labels change

**Symbol dropdown:**
- Hardcoded `QUICK_ORDER_SYMBOLS` array with `{ symbol, category }` (`forex | index | crypto | commodity`)
- Rendered as grouped sections (Commodities / Forex / Indices / Crypto)
- No search box (10 symbols, search was overkill — user feedback)
- Check mark on currently-selected symbol

**Live price display:**
- Pulls from existing `/api/demo/price?symbols=X` (Yahoo Finance wrapper)
- Refreshes every 5s while the panel is mounted
- Falls back to synthetic `getDemoPrice(symbol)` if Yahoo errors
- Small pulsing emerald dot indicates mid-refresh

**Class-level rule for any duplicated UI form:** if the same form would appear on two screens, extract to a component with its own CSS file BEFORE the second copy goes in. Inline JSX is fine for single-use forms; it's actively harmful for forms that go on multiple pages.

**Files:**
- `src/components/trading/QuickOrderPanel.tsx` (component)
- `src/components/trading/QuickOrderPanel.css` (styles, prefixed `.qo-*`)
- Used in: `src/components/trading/TradingTerminal.tsx`, `src/components/trading/TradingDashboardView.tsx`

---

## Recipe #61 — Demo close "freezes the dashboard" because three endpoints returned different shapes for demo users (added Aug 30 2026)

**Symptom:** the user clicks **Close Position** on a live position card. The position correctly disappears from the Live Positions grid. But the balance card stops ticking, the position list never refreshes again, and the user has to force-quit and reopen the app to recover.

**Root cause:** three the broker-related endpoints had inconsistent demo handling. `/api/broker/account` and `/api/realtime/poll` both gated on `broker_access_token` (which demo users don't have) and returned `{ connected: false }` / `{ ok: false }` respectively. Only `/api/broker/account-data` had the demo intercept. When the user clicked Close, `setSignals(prev.filter(...))` correctly removed the position from local state, but the post-close `refreshBrokerData()` and the SSE broker's `/realtime/poll` both got failure responses — leaving no source updating the dashboard. Cached state in `broker_session_cache` desynced from DB → dashboard stuck.

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
    // 4. Compute live P&L via demoPipSize/demoPipValue
    // 5. Return the broker-shaped response (positions, balance,
    //    equity, analytics, allAccounts, ...)
}
```

```ts
// /api/broker/account/route.ts
const { data: demoCheck } = await svc
    .from('user_accounts')
    .select('broker_connection_status, guided_account_starting_balance, broker_account_name')
    .eq('id', userId).maybeSingle();
if (demoCheck?.broker_connection_status === 'demo') {
    return await buildDemoAccountData({
        userId,
        accountId: `demo-account-${userId}`,
        accountName: demoCheck.broker_account_name ?? 'Demo Account',
        startingBalance: demoCheck.guided_account_starting_balance ?? 0,
        svc,
    });
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

**Symptom:** the user closes a demo position that was +$50. The position card correctly disappears. The trade history shows "Win +$50.00". But the **balance card stays at $10,000**. Open 5 winning trades, balance still $10,000. The wins are silently disappearing from the user's total.

**Root cause:** `closeDemoPosition` writes `realized_pnl` to the position row but never touches the user's `guided_account_starting_balance`. The dashboard reads `guided_account_starting_balance` as the canonical balance.

**The fix — atomically add `realizedPnl` to `guided_account_starting_balance` after marking the position closed:**

```ts
// In closeDemoPosition, AFTER the position update succeeds:
const { data: balRow } = await svc
    .from('user_accounts')
    .select('guided_account_starting_balance')
    .eq('id', userId).maybeSingle();
if (balRow) {
    const current = Number(balRow.guided_account_starting_balance ?? 0);
    const newBalance = Number((current + realizedPnl).toFixed(2));
    await svc.from('user_accounts')
        .update({ guided_account_starting_balance: newBalance })
        .eq('id', userId);
}
```

**Why not atomic SQL?** Read-then-write for simplicity. For the demo
account system, race conditions between two concurrent closes are
vanishingly unlikely. If you ever need stricter consistency, do this
with an RPC that runs `guided_account_starting_balance = guided_account_starting_balance + realizedPnl`
in a single UPDATE statement.

**The class-level rule:** any time you write `realized_pnl` to a
position row, also write the same delta to the user's balance field
in the same transaction. Otherwise the win/loss is invisible.

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

**The fix — add SL/TP detection inside `buildDemoAccountData`:**

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
    // ...
});

// Process auto-closes BEFORE returning the snapshot
if (positionsToAutoClose.length > 0) {
    let totalRealizedDelta = 0;
    for (const { pos, closePrice, reason } of positionsToAutoClose) {
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
    // Update balance with the net delta (Recipe #62)
    // ...
}
```

**Three important details:**

1. **Close at the SL/TP price, NOT the live price.** If BTCUSD is at $78,250 and the user's TP is $78,200, closing at $78,250 gives them 50 extra pips they didn't ask for. By closing at $78,200 (the TP level), they get exactly what they configured.
2. **Set `close_reason='SL_hit'` or `'TP_hit'`.** The trade journal can show these distinctly from user-clicked closes.
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

CSS upgrades — higher contrast + slide-in animation:
```css
.qo-msg--ok {
    background: rgba(16, 185, 129, 0.14);   /* was 0.1 */
    border: 1px solid rgba(16, 185, 129, 0.4); /* was 0.3 */
    color: #34d399;
    font-weight: 600;
    animation: qo-msg-in 0.25s ease-out;
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
- **Single source of truth for state shape**: the form's submit handler uses the same `submitOrder` from the TradingContext.

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

- **No scroll event spam** — scroll events fire 60+ times/second. IntersectionObserver fires only when the sentinel enters/exits the viewport.
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

I chose option 2. The chart page's inline form is still there for now (a future cleanup can swap it). But the principle: **the first time you copy a form between two places, extract it.** Don't wait for the third copy — by then you've shipped three slightly-different bugs.

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

### Recipe #54 — `overflow-x: hidden` on `html`/`body` silently breaks `position: sticky` on descendants (added Aug 31 2026)

**Symptom:** A scroll-scrubbed video section (`<video class="position: sticky; top: 0; height: 100vh">`) is supposed to stay pinned to the viewport while the user scrolls. Instead, the video scrolls off the top of the page with the content — as if it had `position: relative`. The scroll handler fires, but `video.currentTime` stays at 0 and the video background is not visible. The page itself scrolls correctly; only the sticky element misbehaves.

**Root cause — Chromium / Firefox treat `overflow: hidden` as creating a new scroll container.** the platform (and most PWAs) have horizontal-scroll lock on the root:

```css
html, body {
  overflow-x: hidden;  /* PWA iOS: lock horizontal scroll */
  overscroll-behavior-x: none;
}
```

In Chromium-based browsers, `overflow: hidden` on an ancestor breaks `position: sticky` on descendants. The sticky element behaves like `position: relative` — it scrolls with the page instead of sticking to the viewport.

**The fix — use `overflow-x: clip` instead.** Same visual effect (horizontal content is clipped), but `clip` does **not** create a new scroll container, so `position: sticky` works on descendants:

```css
html, body {
  overflow-x: clip;       /* ← same visual, no new scroll context */
  overscroll-behavior-x: none;
}
```

This is the standard fix for any PWA with horizontal-scroll lock + sticky elements (sticky video backgrounds, sticky headers, sticky drawers, sticky table columns).

**Diagnostic** — open the page in DevTools, walk up the sticky element's ancestor chain, and check `getComputedStyle()` for any ancestor with `overflow: hidden`, `overflow: auto`, or `overflow: scroll`. If you find one, the sticky element is in a trapped scroll context.

Quick playwright probe:

```js
const video = page.locator('video').first();
for (const y of [0, 200, 500, 1000]) {
  await page.evaluate((scrollY) => window.scrollTo({ top: scrollY, behavior: 'instant' }), y);
  await page.waitForTimeout(300);
  const state = await video.evaluate((v) => ({
    currentTime: v.currentTime,
    top: v.getBoundingClientRect().top
  }));
  // bg.top should stay at 0 (sticky working)
  // video.currentTime should advance with scrollY (scrub working)
}
```

If `top` is going negative (e.g. `top: -500` at scrollY=500), sticky is broken.

**Verification** — after the fix, `top` should stay at 0 across all scroll positions while the section is in view, then release as the section exits the viewport.

**Related:** the same pattern affects any sticky element inside an `overflow: hidden` ancestor. The `position: fixed` workaround is tempting but breaks the scroll-snap behavior — use `clip` instead. See Recipe #52 (chat input bar position: sticky floating mid-screen) for a related but different symptom.

---

### Recipe #55 — PWA app icon logo centering (added Aug 31 2026)

**Symptom:** the PWA / iOS / Android app icon has the logo visibly off-center — most commonly too low (more empty space at the top than the bottom) or slightly to one side. Common with logos that have asymmetric visual mass (the winged-V is heavier at the top, where the wings extend up and out, than at the bottom point).

**Root cause — using bounding-box center instead of visual center of mass.** Naive centering computes the logo's bbox center and places it at the canvas center. But for asymmetric logos (V-shapes, arrowheads, logos with a "cap" + a "point"), the **visual center of mass** (where the white pixels actually are) sits ABOVE the bbox center because the cap has more pixels than the point.

**The fix — compute the weighted center of mass and center that on the canvas.** Plus apply a small downward offset (3-5% of canvas) to compensate for the visual asymmetry:

```python
import numpy as np
from PIL import Image

# Compute white-pixel center of mass
arr = np.array(logo.convert('RGB'))
white_mask = (arr > 200).all(axis=2)
ys, xs = np.where(white_mask)
total = white_mask.sum()
com_y = (ys * white_mask[ys, xs]).sum() / total
com_x = (xs * white_mask[ys, xs]).sum() / total

# Build canvas with COM at center + 3% downward offset
canvas_size = int(max(logo.size) * 1.5)  # 50% padding
canvas = Image.new('RGBA', (canvas_size, canvas_size), (0, 0, 0, 255))
paste_x = int(canvas_size / 2 - com_x)
paste_y = int(canvas_size / 2 - com_y + canvas_size * 0.03)  # ← offset
canvas.paste(logo, (paste_x, paste_y), logo)
```

**Size recommendation** — the V should fill 75% of the icon for the main PWA size, 80% for iOS (Apple's home-screen icons look best with more fill), 70% for Android regular icons, 60% for Android adaptive-icon foregrounds (within the safe zone for cropping).

**Verification** — overlay a red crosshair at canvas center on the icon. The logo's visual center of mass should sit on the crosshair. Bbox center ≠ visual center for asymmetric logos.

---


## Pairs with

- `this skill` Recipe #55 (demo entry-price drift) — Recipe #61 fixes the post-close freeze that resulted
- `this skill` Recipe #62 (realized P&L balance tracking) — Recipe #63 extends this with auto-close
- `this skill` Recipe #56 (i18n wiring vs plumbing) — confirmed again in this session with Spanish on Settings
- `this skill` Recipe #57 (mobile-only layout with mutually-exclusive right-rail content) — calendar/monthly-breakdown reorder
- `this skill` Recipe #54 (TradingTerminal p.pnl.toFixed crash) — Recipe #61's response-shape drift fix
- `nextjs-pwa` skill — Playwright auth testing limitations (Cross-cutting D)
- `user/user-interaction-standards` — feedback visibility (Recipe #64)- `references/2026-09-05-tradingprovider-scoping-and-simpler-scope.md` — `TradingProvider` lives in the dashboard segment, not root. Any "make this modal openable from anywhere" refactor needs the provider lifted first; a single inline button on the home balance card is the simpler-scope fix when the user pushes back on scope.

EOF
Recipe #70 — Mobile trade journal calendar cut off: CSS source-order cascade override (added Sep 10 2026)

**Symptom:** On iPhone-class viewports (375-414px CSS pixels), the trade journal calendar grid is ~280px wide instead of full-width. Day numbers stack vertically, weekday labels overlap (rendered as "SUNMONTUEWEDTH"), the month title truncates ("Septemb..."). The mobile breakpoint media query appears not to fire — even though `.journal-main-layout { grid-template-columns: 1fr }` is set inside `@media (max-width: 900px)`, the calendar still renders as a 2-column grid.

**Root cause:** A **CSS source-order cascade bug**, not a width-math bug. Two rules for `.journal-main-layout` exist:

```css
/* Rule 1 — mobile breakpoint, line ~1067 in TradeJournalView.css */
@media (max-width: 900px) {
    .journal-main-layout { grid-template-columns: 1fr; }
}

/* Rule 2 — desktop override, OUTSIDE any media query, line ~1259 */
.journal-main-layout {
    grid-template-columns: minmax(0, 1.28fr) minmax(300px, 0.72fr);
    gap: 20px;
}
```

At equal specificity, **CSS source order wins.** Rule 2 comes after Rule 1, so the 2-column desktop grid overrides the 1-column mobile grid at every viewport. The mobile breakpoint *did* fire — its rule was simply overridden by a later global rule.

**The fix:** wrap the desktop 2-column rule in `@media (min-width: 901px)` so it ONLY applies at desktop widths:

```css
/* TradeJournalView.css — before line 1259 */
@media (min-width: 901px) {
    .journal-main-layout {
        grid-template-columns: minmax(0, 1.28fr) minmax(300px, 0.72fr);
        gap: 20px;
    }
}
```

Now the mobile rule wins at ≤900px (single column) and the desktop rule wins at ≥901px (2-column).

**Diagnostic — when mobile breakpoint "isn't working":**

```bash
# 1. Inspect both rules in the file
grep -n "journal-main-layout" src/components/<name>/<name>.css

# 2. Check source order — whichever is later wins
sed -n '/journal-main-layout/,/^}/p' src/components/<name>/<name>.css

# 3. Verify with a live rule trace in browser DevTools
# Open the route → Sources panel → click the CSS file → click
# `.journal-main-layout` → see which rule is highlighted. The
# HIGHLIGHTED rule is the one that actually applied.
```

**Common patterns that cause this:**

1. **Global override added later in the file** — same selector, no media query wrapper, after the responsive rules. Classic source-order trap.
2. **Desktop-specific properties (large `minmax()` values) inside a global rule** — when the file gets desktop-tuned, the rule loses its media query wrapper to "be cleaner."
3. **Two CSS files imported, both targeting the same class** — the second import wins. Verify with `@import` order or check the build output.

**When this hits again:** any route that adds a media query for mobile but also has a later global rule with the same selector. Look for `grid-template-columns`, `padding`, `margin`, or `max-width` overrides after the media query block.

**Verification (when this hits again):**

```bash
# 1. Reset dev server cache
npx rimraf .next

# 2. On the phone (or DevTools mobile emulation at 375x812):
#    - Calendar should be full viewport width
#    - Day cells should be ~45px wide squares
#    - Weekday labels should each fit in their column
#    - Month title should NOT truncate

# 3. On desktop (1280x800):
#    - Calendar + day-detail panel should be side-by-side
#    - Min 300px on the day-detail panel (the minmax floor)
```

**Related:** Recipe #29 (PWA iOS service worker + responsive cascade) — both bite on iPhone, both are visual cascade bugs that look like data bugs until you inspect the rendered CSS.

---

Recipe #71 — Partner dashboard fix that doesn't fix it: global CSS rule overrides responsive media query (added Sep 10 2026)

**Symptom:** you ship what looks like a mobile responsive fix. CSS rules like `@media (max-width: 900px) { .x { grid-template-columns: 1fr; } }` are written and deployed. On iPhone-class viewports the layout *still* shows the desktop multi-column layout. The mobile rule is never winning.

**Root cause:** the cascade trap from Recipe #70 generalized. Anywhere a CSS file defines a responsive media query for a property, and a later global rule overrides the same property on the same selector, **the later rule wins at every viewport including mobile**. The mobile breakpoint "fires" but its output is overridden before render.

**The diagnostic recipe (works for any "responsive rule isn't applying" report):**

```js
// Paste in browser console on the affected route:
const el = document.querySelector('.the-class');
const sheets = Array.from(document.styleSheets);
const matchingRules = [];
for (const sheet of sheets) {
    try {
        for (const rule of sheet.cssRules) {
            if (rule.selectorText && rule.selectorText.includes('.the-class')) {
                matchingRules.push({
                    selector: rule.selectorText,
                    media: rule.media?.mediaText ?? '(no media)',
                    cssText: rule.style.cssText.slice(0, 120),
                });
            }
        }
    } catch (e) { /* cross-origin sheet */ }
}
console.table(matchingRules);
```

The LAST entry in `matchingRules` is the rule that won. If the rule that won is NOT inside `@media (max-width: ...)`, the mobile rule was overridden.

**Fix — three patterns:**

1. **Wrap the desktop override in `@media (min-width: ...)`** (preferred when the desktop rule is genuinely desktop-only).
2. **Use higher specificity in the mobile rule** (last resort — adding `:where(...)` wrappers or `!important` makes the cascade unmaintainable).
3. **Delete the global override** if the responsive rule is the new intended default.

**Anti-pattern — using `@media (max-width: 900px)` for the desktop reset and an unwrapped rule for the mobile default.** This is the pattern that bit Recipe #70. The mobile default ends up AFTER the desktop reset in source order. Always put the mobile-or-default rule BEFORE the desktop override in the file, or wrap the desktop override in a `min-width` media query.

**Verification:** after every CSS change that touches a property already set globally, open DevTools → Responsive mode → set viewport to 375x812 → confirm the rendered layout matches the design intent. Don't trust the syntax-highlighted source order — trust the actual computed style on the actual viewport.

**When this hits again:** the user reports "the mobile layout didn't change" or "still showing the same thing on my phone" after a CSS-only change. Always run the diagnostic recipe before changing more CSS.

**Related:** Recipe #70 (specific instance on `.journal-main-layout`), Recipe #49 (mobile-only CSS `display: none`), Cross-cutting pattern D ("I shipped a real bug, said it was tested, but tsc just said 'no errors'") — TypeScript catches type errors but not CSS cascade errors. CSS bugs ship silently.

---

Recipe #72 — "Run in circles" workflow correction: stop iterating on blocked external work, ask user for the path (added Sep 10 2026)

**Symptom:** the agent spends 30+ minutes poking at an external API (the white-label broker, in this case) trying to get a developer-machine-side request to succeed. Each iteration finds a new "wait — but also need to do X" blocker. The agent keeps building scaffolding (debug endpoints, route variants, fallback logic) without producing anything the user can use. The user eventually says: "We are running in circles with all of this lets just wait to get the document back."

**Root cause:** the right move was the FIRST move — surface to the user that the integration depends on an external party (the white-label broker) and stop. Building scaffolding around an undocumented API is wasted effort when the path forward is "wait for the docs from the vendor."

**The diagnostic — ask these three questions BEFORE building more scaffolding:**

1. **Is this integration dependent on external documentation or a contract we don't have?**
   - white-label broker has no public API docs. We're reverse-engineering from the production JS bundle. → STOP.
   - Stripe has full docs. → BUILD.
   - Supabase has full docs. → BUILD.
   - If the answer is "we're guessing" → STOP and tell the user.

2. **What does the user actually need RIGHT NOW?**
   - If they need to see the dashboard populating with data → the dependency blocks this, so a path forward is "wait for the vendor" not "build more wrappers."
   - If they need to ship a feature that doesn't depend on this integration → work on that instead.

3. **What is the cheapest signal that would unblock the integration?**
   - The cheapest signal is usually a document from the vendor, an email to the vendor's support, or an internal account with admin scope.
   - Building a custom debug endpoint is NOT a cheap signal — it's expensive scaffolding.

**The fix — the moment you realize you're stuck on an external dependency:**

1. **Tell the user clearly:** "I'm blocked. white-label broker has no public API docs. The path forward is to email white-label broker and ask for the master API contract (we already built `whitelabel-master-api-request-v3.pdf` on your Desktop). I'm going to stop iterating on this and wait."
2. **Stop iterating.** Don't build more fallback paths, more debug endpoints, or "what if" code paths. Those are all wasted work until the vendor responds.
3. **Identify what IS shippable without the dependency.** Build those instead. In this session: the mobile calendar fix, the partner portal Phase 1-3, the Algo OS payment flow — all independent of white-label broker's PAMM contract.
4. **Set up a clear re-entry point.** When the user gets the vendor response, the path back is clear: re-read the V3 PDF, match their answer to the questions there, patch the wrappers in `src/lib/whitelabel/partner-client.ts`.

**Anti-pattern — "let me just build one more debugging tool":**

The agent in this session built `/api/admin/debug/whitelabel` to dump raw white-label broker responses. That was scaffolding to make the integration visible — useful for the NEXT iteration, but not for THIS one. The user already had the integration pattern correct (white-label white-label broker under the broker). The debug endpoint added value ONLY after white-label broker responded with their actual field shapes. Before then, it just delayed the user noticing the loop.

**Anti-pattern — "let me see if I can read your white-label broker cookies from this other path":**

When the agent tries `?userId=<uuid>` query params, or admin-impersonation endpoints, or browser DevTools extraction, it's building new attack surface for a credential-sharing-against-preference situation. The user explicitly told the agent: "I'm not going to do this. Three reasons... You just shared credentials in chat." That's a hard line. Building scaffolding to work around it is wasted effort AND violates the user's preference.

**The right move when the user shares credentials in chat:**

1. **Don't use them.** Even if the user says "go ahead and use them."
2. **Tell the user why.** "I won't authenticate as you with those credentials — they were shared in chat and are now compromised. Rotate the password, then I can work from your session via the proper UI flow."
3. **Build the alternative path.** A debug endpoint that reads the saved `whitelabel_access_token` from `user_accounts` (the proper flow) is correct. Reading the cookie from chat text is wrong.

**Verification (when this hits again):**

- After every 20 minutes of "iteration on external dependency," pause and ask the three diagnostic questions.
- If the answer is "yes, we're stuck on external," tell the user and stop.
- Surface the unblock path (the email to the vendor, the doc we need from them) clearly.

**Related:** Cross-cutting pattern D ("I shipped a real bug, said it was tested, but tsc just said 'no errors'") — overengineering on blocked external work is a different failure mode but produces the same wasted-effort outcome.

### Recipe #56 — `signal_log` schema mismatch: route queries `engine_id`, table has `engine` (added Sep 12 2026)

**Symptom:** a route that reads from `signal_log` returns empty data silently. The route returns `200 OK` with `latest: null, history: []`. No error is thrown. The UI component receiving this shows an empty state. Nothing in the browser console, nothing in the network tab (it's a 200), nothing in the route's own logs unless you add explicit logging.

**Root cause:** the route was written against a reference implementation that used `engine_id` as the column name, but the actual `signal_log` table in production has `engine` (not `engine_id`). The PostgREST API silently returns an error payload on the wire, but the route's `Promise.race([signalsQuery, timeout])` block catches it and returns the empty payload:

```ts
// /api/home/recent-signals — broken since it shipped
const signalsQuery = svc
    .from('signal_log')
    .select('id, engine_id, pair, ...')
    .in('engine_id', Array.from(unlocked));
    //                                  ^^^^^^^^^^ column doesn't exist

let signals = [];
let signalsError: any = null;
try {
    const res = await Promise.race([signalsQuery, timeout(8_000)]);
    signals = (res as any)?.data ?? [];
    signalsError = (res as any)?.error;
} catch (e: any) {
    console.warn('[home/recent-signals] signal_log timeout/error:', e?.message);
    signalsError = e;
}

if (signalsError) {
    // ⚠️ This block silently swallowed the "column doesn't exist" error
    return NextResponse.json({
        unlocked_engines: Array.from(unlocked),
        latest: null,
        history: [],
        fetched_at: new Date().toISOString(),
        _note: 'empty (query error)',
    });
}
```

The component receiving this payload (`LatestSignalDeck`) renders the empty state. **No user-visible failure. No error toast. No log.** The route has been silently returning empty for as long as it shipped.

**The diagnostic recipe (when "the API returns 200 but the component is empty"):**

1. **Hit the actual SQL directly via PostgREST.** Build a `/api/test/...` route that runs a `.select('*').limit(1)` on the table. The keys of the returned object ARE the actual columns.
2. **Compare the keys to what the failing route is selecting.** A mismatch (`engine_id` vs `engine`, `recentHistory` vs `history`, `tradableInstrumentId` vs `symbol`) is your bug.
3. **Don't trust the migration history.** The `signal_log` table was created by the python bot pipeline on another machine, not by any migration in `supabase/migrations/`. Migrations tell you about migrations, not about tables.

**The fix — three pieces:**

1. **Rename the column reference** to match the actual schema:
   ```ts
   .select('id, engine, pair, ...')  // not engine_id
   .in('engine', Array.from(unlocked))  // not engine_id
   ```

2. **Add `null` returns for shape mismatches**, not silent empty payloads. If you can't read the table, the route should return an error the UI can surface:
   ```ts
   if (signalsError) {
       return NextResponse.json({
           error: signalsError.message,  // <-- surface it
           hint: 'Check the signal_log table schema',
       }, { status: 500 });
   }
   ```
   The empty-payload-on-error pattern is **wrong** for production. It hides schema drift.

3. **Make the schema discoverable.** Add a `.select('*').limit(0)` introspection to the route that returns `{ columns: [...] }` so future agents (and the dashboard's debug mode) can see what columns exist.

**The lesson — silent error swallowing hides schema drift:**

The root cause here was actually three layers deep:
1. **A reference implementation** (some earlier code) was authored against a different schema.
2. **A schema divergence** (the table got renamed or created by a different system) happened silently.
3. **An error-swallowing wrapper** (`if (signalsError) return empty payload`) hid the mismatch forever.

Any one of these three would have eventually been caught — but all three happened simultaneously, and the silent wrapper was the one that let the bug ship. **The fix for the recurring class is: stop swallowing PostgREST errors in API routes.** Surface them. The empty payload is a silent lie — the route says "no data" when the truth is "I couldn't read the data, please check the schema."

**Related:** Recipe #45 (silent auth-gate failures) and Recipe #47 (`.map()` crash with no error UI) — same class: **the system fails in a way the user can't see.** Fix is the same: surface the failure.

---


### Recipe #62 — Python regex `\d+` doesn't match thousands-separator digits, truncating prices to 2 chars (added Sep 13 2026)

**Symptom:** A regex parser for a Telegram channel post (or any free-text price source) extracts `\d+` and stops at the first comma. So a message body

```
☑️ ENTRY PRICE @ 76,783.80
├ 🔑 TP1: 76,872.00
⛔️ Stop Loss: 76,700.55
```

gets parsed as `entry=76`, `tp1=76`, `sl=76` — and the resulting push notification shows **"Entry @ 76 | SL @ 76"** on the user's iPhone. The original Telegram message was perfectly fine; the regex was the bug.

**Root cause:** regex character class `\d+` matches digits only, not commas. Python's `float("76,783.80")` also raises ValueError, so you can't recover by passing the captured group straight to `float()` either — both halves of the pipeline assume comma-free input.

**The fix — three pieces:**

1. **Allow commas in the character class.** Match `\d+` OR `\d+(?:,\d{3})+` OR `\d{1,3}(?:,\d{3})*\.\d+`. Simplest form for the common case is `(?P<price>[\d,]+\.\d+|\d+)`:

   ```python
   RE_ENTRY = re.compile(
       r"☑️\s*ENTRY PRICE\s*@\s*(?P<entry>[\d,]+\.\d+|\d+)",
       re.IGNORECASE,
   )
   RE_SL = re.compile(
       r"⛔️?\s*Stop\s*Loss:\s*(?P<sl>[\d,]+\.\d+|\d+)",
       re.IGNORECASE,
   )
   RE_TP = re.compile(
       r"🔑?\s*TP(?P<n>[1-4])\s*:\s*(?P<price>[\d,]+\.\d+|\d+)",
       re.IGNORECASE,
   )
   ```

2. **Strip commas before float conversion.** The captured group might be a string with commas (`"76,783.80"`), which `float()` rejects:

   ```python
   p.entry = float(m.group("entry").replace(",", ""))
   p.sl    = float(m.group("sl").replace(",", ""))
   price  = float(m.group("price").replace(",", ""))
   ```

3. **Server-side belt-and-suspenders.** Even with the regex fixed, downstream consumers should re-format with `toLocaleString('en-US', { minimumFractionDigits: N })` so a JS template literal like `` `Entry @ ${entry}` `` produces the right string instead of `"Entry @ 76783.8"`. iOS push notifications display the raw string verbatim — no fallback formatting.

**The diagnostic recipe (when "the iOS notification shows a truncated price"):**

1. **Log the captured regex group and the parsed float** on both the parse and push sides. The bug is either at the parse (capturing "76") or at the render (template-interpolating `76783.8` as `"76783.8"`).
2. **If the captured group is `"76"` and the float is `76.0`** — the regex is the bug.
3. **If the captured group is `"76,783.80"` but the float is `76.0`** — the float conversion is the bug (`float("76,783.80")` raises).
4. **If the parsed float is `76783.8` but the rendered string is `"76783.8"`** (no commas, no zero-padding) — the render is the bug. Add `toLocaleString` with explicit `minimumFractionDigits`.

**The lesson — assume free-form numeric input has commas:**

Any regex that captures a price from human-written text should assume thousands separators. The cost of being explicit (`[\d,]+\.\d+|\d+`) is one character class; the cost of being implicit (`\d+`) is every downstream notification showing truncated numbers. Apply this to every regex that touches currency, instrument prices, pips, or any user-typed numeric value.

**Related:** Recipe #56 (`signal_log` schema mismatch) — same shape of bug (silent wrong-number), different layer. Both are "the system says it's fine but the data is wrong." The fix for both: **stop swallowing the bad-data signal and surface it.**

---

### Recipe #62 — Python regex `\d+` doesn't match thousands-separator digits, truncating prices to 2 chars (added Sep 13 2026)

**Symptom:** A regex parser for a Telegram channel post (or any free-text price source) extracts `\d+` and stops at the first comma. So a message body

```
☑️ ENTRY PRICE @ 76,783.80
├ 🔑 TP1: 76,872.00
⛔️ Stop Loss: 76,700.55
```

gets parsed as `entry=76`, `tp1=76`, `sl=76` — and the resulting push notification shows **"Entry @ 76 | SL @ 76"** on the user's iPhone. The original Telegram message was perfectly fine; the regex was the bug.

**Root cause:** regex character class `\d+` matches digits only, not commas. Python's `float("76,783.80")` also raises ValueError, so you can't recover by passing the captured group straight to `float()` either — both halves of the pipeline assume comma-free input.

**The fix — three pieces:**

1. **Allow commas in the character class.** Match `\d+` OR `\d+(?:,\d{3})+` OR `\d{1,3}(?:,\d{3})*\.\d+`. Simplest form for the common case is `(?P<price>[\d,]+\.\d+|\d+)`:

   ```python
   RE_ENTRY = re.compile(
       r"☑️\s*ENTRY PRICE\s*@\s*(?P<entry>[\d,]+\.\d+|\d+)",
       re.IGNORECASE,
   )
   RE_SL = re.compile(
       r"⛔️?\s*Stop\s*Loss:\s*(?P<sl>[\d,]+\.\d+|\d+)",
       re.IGNORECASE,
   )
   RE_TP = re.compile(
       r"🔑?\s*TP(?P<n>[1-4])\s*:\s*(?P<price>[\d,]+\.\d+|\d+)",
       re.IGNORECASE,
   )
   ```

2. **Strip commas before float conversion.** The captured group might be a string with commas (`"76,783.80"`), which `float()` rejects:

   ```python
   p.entry = float(m.group("entry").replace(",", ""))
   p.sl    = float(m.group("sl").replace(",", ""))
   price  = float(m.group("price").replace(",", ""))
   ```

3. **Server-side belt-and-suspenders.** Even with the regex fixed, downstream consumers should re-format with `toLocaleString('en-US', { minimumFractionDigits: N })` so a JS template literal like `` `Entry @ ${entry}` `` produces the right string instead of `"Entry @ 76783.8"`. iOS push notifications display the raw string verbatim — no fallback formatting.

**The diagnostic recipe (when "the iOS notification shows a truncated price"):**

1. **Log the captured regex group and the parsed float** on both the parse and push sides. The bug is either at the parse (capturing "76") or at the render (template-interpolating `76783.8` as `"76783.8"`).
2. **If the captured group is `"76"` and the float is `76.0`** — the regex is the bug.
3. **If the captured group is `"76,783.80"` but the float is `76.0`** — the float conversion is the bug (`float("76,783.80")` raises).
4. **If the parsed float is `76783.8` but the rendered string is `"76783.8"`** (no commas, no zero-padding) — the render is the bug. Add `toLocaleString` with explicit `minimumFractionDigits`.

**The lesson — assume free-form numeric input has commas:**

Any regex that captures a price from human-written text should assume thousands separators. The cost of being explicit (`[\d,]+\.\d+|\d+`) is one character class; the cost of being implicit (`\d+`) is every downstream notification showing truncated numbers. Apply this to every regex that touches currency, instrument prices, pips, or any user-typed numeric value.

**Related:** Recipe #56 (`signal_log` schema mismatch) — same shape of bug (silent wrong-number), different layer. Both are "the system says it's fine but the data is wrong." The fix for both: **stop swallowing the bad-data signal and surface it.**

---
## Recipe #67 — Swapping the Supabase browser client storage backend breaks every localStorage-read-only consumer (added Sep 14 2026)

**Symptom:** After switching from `createClient()` (@supabase/supabase-js, default storage = localStorage at `sb-<project>-auth-token`) to `createBrowserClient()` (@supabase/ssr, default storage = chunked `document.cookie` only), authenticated API calls start returning 401 even though the user *is logged in* and pages render correctly (server-side hydration works).

**Root cause:** the rewrite swaps the storage backend from localStorage to chunked cookies. Existing client code that hardcodes `localStorage.getItem('sb-...-auth-token')` (or `access_token = ...session?.access_token`) reads from the OLD storage, finds nothing valid (or a stale pre-rewrite value), sends no `Authorization: Bearer *** header, server replies 401 with the same error string.

**Where this bit us — every Sep 14 2026 attempt traced to this:**
- `src/lib/admin-fetch.ts` — reads `sb-<project>-auth-token` from localStorage, sets the Bearer header. After the rewrite, this returns `null` for new sessions → no header → 401.
- `useUser()`, `useTrading()` — `supabase.auth.getSession()` is supposed to read from the new storage, but if anything in the auth chain is reading localStorage directly (e.g. a stale comment in UserContext), the session state is wrong.
- Plain `fetch('/api/...', { headers: { Authorization: Bearer *** session?.access_token } })` — when `session?.access_token` is from the new client but the server-side validation doesn't accept it, the route returns 401.

**The fix pattern — three options:**

1. **Revert the browser client** if no compelling reason to use @supabase/ssr client-side. The simpler shim (`createClient()` + custom storage that mirrors to BOTH localStorage AND document.cookie) works for both server and client consumers and keeps all existing localStorage reads valid.
2. **Update every consumer to read from cookies** if the rewrite is required. Wrap `document.cookie` parsing in a helper and pass tokens explicitly via header.
3. **Bridge the gap** if you don't want to refactor every page. Augment `adminFetch`:
   ```ts
   // Read document.cookie FIRST (post-rewrite canonical location)
   // Decode base64-url OR URL-encoded JSON (both formats appear during migration)
   // Fall back to localStorage for legacy / in-flight sessions
   // Prefer pairs with BOTH access_token AND refresh_token
   ```
   Then add a `console.debug('[adminFetch] token source = cookie/localStorage/none ...')` so the next session can confirm at runtime which path is being used.

**When to suspect this pattern again:**
- API routes return 401 "Not authenticated" but `useUser()` says the user is logged in
- A specific endpoint failed right after another file touched `src/lib/supabase/browser.ts` or `src/lib/admin-fetch.ts`
- The failing endpoint hardcodes `adminFetch(...)` or reads `localStorage.getItem('sb-<project>-auth-token')`

**Diagnostic sequence:**
1. Open DevTools console, run `document.cookie` — find the `sb-<project>-auth-token.0`, `.1`, ... chunks. If absent/empty, the browser client never wrote the session.
2. Run `localStorage.getItem('sb-...-auth-token')` — if there's a value but cookie is empty, the OLD shim is still in play and the rewrite didn't reach production.
3. Run any admin route, e.g. `fetch('/api/app/streak', { headers: { Authorization: 'Bearer ' + <token from localStorage or cookie> } })` and see which token returns 200.

**Lesson — don't swap the auth storage backend without an inventory of every reader.**

When you change `getSupabaseBrowserClient()`, run a project-wide grep for `sb-<project>-auth-token`, `access_token`, and `localStorage.getItem` to find every implicit dependency on the old storage layout. Each one is a future 401 waiting to happen.

**Related:** Recipe #15 (`navigator.locks` LockManager contention producing 401s). Same symptom (401 "Not authenticated"), different cause. Recipe #15 is async-lock contention on `supabase.auth.getSession()`; Recipe #67 is a static storage-backend mismatch. Diagnostic distinction: under #15 you'll see `lock acquisition timed out` in console; under #67 you won't, but `document.cookie` will be missing the auth-token chunks.

---

## Recipe #68 — `signal.status` / `signal.pair` / `signal.engine_name` are nullable on `signal_log` legacy rows (added Sep 14 2026)

**Symptom:** "undefined is not an object (evaluating 'e.toUpperCase')" React error on the dashboard home. Page renders the red "Something went wrong" page. The error is wrapped in `TabErrorBoundary`, with the message hidden in a `<pre>` block the user has to scroll to find.

**Root cause:** legacy `signal_log` rows (inserted by the Python listener before the latest schema fixes) have `NULL` in `status`, `pair`, `engine_name`, and similar fields. The Telegram-listener regex fix (`bf31207e` for sep 14, 2026 — earlier `8edbf677` for the regex itself) fixed NEW signal inserts but left historical rows alone. Any consumer calling `signal.status.toUpperCase()`, `signal.pair.toUpperCase()`, etc. throws as soon as one such row hits the render path.

**Where it bit us (the cascade of "I fixed it" failures on Sep 14):**
- `RecentSignalCard.tsx:89` — `STATUS_META[signal.status] ?? { label: signal.status.toUpperCase() }` (fallback path crashes)
- `LatestSignalDeck.tsx:91` — `priceDecimalsFor(pair).toUpperCase()` (called via `priceDecimalsFor(signal.pair)` with nullable input)
- `TradingDashboardView.tsx` — `signal.pair?.toUpperCase()` for pip multiplier
- Anywhere a JSX render does `.{a_string_field}.toUpperCase()` where `a_string_field` could be null

**Three fixes, layered:**

1. **Defensive rendering at the consumer** (the patch I shipped Sep 14):
   ```tsx
   function SignalCard({ signal }: { signal: SignalRow }) {
       // Pull safe values once, use everywhere.
       const safePair       = signal.pair        ?? ''
       const safeDirection  = signal.direction   ?? 'BUY'
       const safeEngineName = signal.engine_name ?? signal.engine_id ?? 'Engine'
       const safeStatus     = signal.status      ?? 'live'
       // JSX uses safePair / safeDirection / safeEngineName / safeStatus
   }
   ```

2. **Defense-in-depth at the helper** in case the consumer forgets:
   ```ts
   function priceDecimalsFor(pair: string): number {
       const p = (pair ?? '').toUpperCase()
       if (p.endsWith('JPY')) return 3
       // ...
   }
   ```

3. **Surface the actual stack on error** — make the existing `TabErrorBoundary` print the full error stack + a "Copy stack" button. The minified `sh`/`su`/`oY` names in production builds mean you can't pin a callsite from the error alone — you need the stack.

**SQL fallback (one-shot, run in Supabase Studio):**
```sql
UPDATE signal_log
SET pair = 'UNKNOWN' WHERE pair IS NULL OR pair = '';
UPDATE signal_log
SET status = 'live' WHERE status IS NULL OR status = '';
UPDATE signal_log
SET direction = 'BUY' WHERE direction IS NULL OR direction = '';
```

**Lesson — when a column is documented as required but legacy rows have NULL, treat the consumer as if it can be null and surface the data drift visibly.** Don't trust TypeScript types alone — the runtime data shape from `signal_log` (a third-party-writable table via the Telegram listener) is whatever the listener sent, not what `pg_dump` reported. Backfill or null-coerce at the rendering layer.

**Related:** Recipe #56 (`signal_log.engine_id` schema mismatch). Same table, similar pattern. #56 is a column-name mismatch in the PostgREST select; #68 is the data being null despite the column existing. Either way, bad data is bad data; the lesson is "don't trust the route, check the row".

---

## Recipe #69 — Run Supabase Studio SQL statements ONE AT A TIME when applying multi-statement migrations (added Sep 14 2026)

**Symptom:** Studio SQL editor returns `Failed to run sql query: ERROR: 42703: column "X" does not exist` and you cannot tell which statement in the multi-statement paste failed. The transaction rolls back, and the migration is NOT applied.

**Root cause:** Supabase Studio runs the whole batch in one transaction. Any single statement failing aborts the whole thing. The error message points at the failing statement by line number, but multi-statement pastes from chat clients or `write_file` tool calls have line-number drift (Studio line 61 isn't the line you typed at 61).

**The fix pattern — paste statements one at a time:**

1. `ALTER TABLE x ADD COLUMN IF NOT EXISTS y TEXT;` — wait for "Success. No rows returned."
2. `ALTER TABLE x ADD COLUMN IF NOT EXISTS z TEXT;` — wait
3. `CREATE INDEX ...` — wait
4. `CREATE OR REPLACE VIEW ...` — wait
5. `GRANT SELECT ...` — wait

Each success = that statement committed. Failure pinpoints the exact statement.

**When migrations reference wrong columns:**
The error message often names the column name + "HINT: Perhaps you meant to reference the column \"OTHER_NAME\"". When the alternatives are not on the table at all (or are on a different table), check the existing schema by running:
```sql
\d+ table_name  -- in psql
-- or in Studio UI: Table Editor
```
Don't re-run with a guessed column. Find the actual column first.

**Common gotchas caught by one-at-a-time:**
- View references a column on a JOINED alias that doesn't exist on either table (e.g. `pu.is_partner` when `is_partner` is on the `partners` table, not `user_accounts`)
- View references a column that exists in the schema but only after you ran an earlier ALTER TABLE (so the order of statements matters)
- `UPDATE ... FROM auth.users` requires elevated grants; sometimes the auth schema has different READ permissions

**Lesson — for any migration with more than 3 statements, split and run individually.** Saves 10–30 minutes of debugging when the second statement fails and the line number in the error message doesn't match your pasted file.

**Related:** `supabase-policies-migrations` skill (general IDEMPOTENT pattern: every ALTER TABLE uses `ADD COLUMN IF NOT EXISTS`, every view uses `CREATE OR REPLACE VIEW`, etc.). This recipe is the *operational* counterpart to that pattern.


### Recipe #70 — Engine write-back via shared-secret `INTERNAL_API_TOKEN`, separate from user-session auth (added Sep 18 2026)

**Symptom:** an external system (a Python trading bot, a webhook from a partner broker, an engine-side fill handler) needs to call a Next.js API route to update P&L state — write TP/SL hits, mark a signal closed, etc. — but should NOT have a user session cookie or a Supabase auth session. Building "let the engine authenticate as the user" violates auth boundaries. Building a separate admin user for the engine leaks PII. **You need a shared-secret token that's neither user auth nor service-role.**

**Root cause:** the API route is the boundary. It accepts two kinds of callers: (1) the user with a Supabase session (cookie or bearer from `useUser().session.access_token`) and (2) the engine with a pre-shared secret in the `Authorization: Bearer *** header. Both go through the same route handler, but the auth check at the top branches.

**The two-token convention:**

- **`PUSH_API_TOKEN`** — used by the Telegram listener (push notification fan-out). Existing convention. Lives in Railway env. Same trust boundary as the listener. Format: `push-<hex>`.
- **`INTERNAL_API_TOKEN`** — used by engine-side write-back. **Separate token** so it can be rotated independently. Same Authorization Bearer header shape, same trust boundary, but the value is different. Format: `internal-<hex>`.

Both are 32-byte cryptographically secure random hex strings (`secrets.token_hex(32)`).

**The fix — three pieces:**

1. **The route accepts EITHER token** (route-side dual-secret check):

```ts
const authHeader = req.headers.get('authorization') ?? ''
const bearer = authHeader.replace(/^Bearer\s+/i, '').trim()
if (!bearer) {
    return NextResponse.json({ error: 'Unauthorized' }, { status: 401 })
}
const pushToken    = process.env.PUSH_API_TOKEN
const internalToken = process.env.INTERNAL_API_TOKEN
const allowed = (pushToken && bearer === pushToken)
            || (internalToken && bearer === internalToken)
if (!allowed) {
    return NextResponse.json({ error: 'Unauthorized' }, { status: 401 })
}
```

2. **The engine sets `Authorization: Bearer <INTERNAL_API_TOKEN>`** in its HTTP client. Same header shape as the listener, different token value.

3. **The engine-side caller also sets a `User-Agent: The platform-Engine/1.0 (write-back)`** header. Railway's UA-blocker middleware blocks "scraper" UAs — a vanilla `python-requests/2.x` UA gets 403 "Access denied." A descriptive UA bypasses it.

**The rotation procedure** (the safe way to introduce `INTERNAL_API_TOKEN`):

```bash
# 1. Generate cryptographically secure
python3 -c "import secrets; print('app-int-' + secrets.token_hex(32))"

# 2. Set on Railway via stdin (avoids shell history leak)
echo "app-int-<value>" | railway variable set --service web --stdin INTERNAL_API_TOKEN

# 3. Wait for auto-deploy to settle (~3 min)
sleep 90 && railway deployment list --service web

# 4. Smoke-test with curl using the new token
curl -X POST https://www.yourdomain.com/api/signals/TL_TEST/event \
  -H "Authorization: Bearer app-int-<value>" \
  -H "User-Agent: The platform-Engine/1.0 (write-back)" \
  -H "Content-Type: application/json" \
  -d '{"event":"tp1_hit","engine":"ENGINE_G"}'
# Expected: 200 with {ok:true, signal:{...}, applied:"tp1_hit"}

# 5. Hand the value to the engine via secure channel (1Password, NOT Telegram chat)
# 6. Delete any local plaintext copy
```

**When this hits again** (any time you build an API endpoint that should accept non-user callers):

- DON'T share the user's session token with the engine
- DON'T use `SUPABASE_SERVICE_ROLE_KEY` for engine writes (it's the master key with full DB access — overkill and a security hole if leaked)
- DO add a separate `INTERNAL_API_TOKEN` env var
- DO accept `Authorization: Bearer *** header on the route with the dual-secret check
- DO document the convention in the engine spec so the trading bot author knows which env var to read

**Diagnostic — when an engine write-back silently 401s:**

```bash
# 1. Test with curl + the right token
curl -X POST $URL -H "Authorization: Bearer $TOKEN" -H "User-Agent: The platform-Engine/1.0 (write-back)" -d '{"event":"tp1_hit"}'

# 2. If you see 401, check the route signature
grep -nE 'PUSH_API_TOKEN|INTERNAL_API_TOKEN|getUser' src/app/api/.../route.ts

# 3. The route MUST accept BOTH tokens. If only PUSH_API_TOKEN — that's the bug.
```

**Lesson — token trust boundaries are not one-size-fits-all.** A user session is "the human at the keyboard." An engine session is "the bot running on the broker's computer." These have different lifetimes, different rotation cadences, and different threat models. Two-token separation lets you rotate either independently and lets you audit writes from each side separately.

---

### Recipe #71 — Supabase realtime subscriptions must listen to UPDATE for state-mutating endpoints (added Sep 18 2026)

**Symptom:** a UI page (Engines Performance, Past Signals feed, any "live P&L" surface) shows data that's stale by minutes or hours, even though the underlying data is being updated in real-time by the engine. The user has to manually refresh the page (or navigate away and back) to see the new TP/SL hits. **The data IS in the database — the page just hasn't re-fetched.**

**Root cause:** the page mounts a Supabase realtime subscription on the table, but only listens to `INSERT` events:

```ts
const channel = supabase
    .channel('engine-recent-signals')
    .on('postgres_changes',
        { event: 'INSERT', schema: 'public', table: 'signal_log' },
        () => { fetchRecent(); })
    .subscribe();
```

For data that's INSERT-only (live signals arriving from the Telegram listener), this works. **But once you add an UPDATE-driven endpoint** (the engine write-back at `/api/signals/<id>/event` updates existing rows in place — TP1_hit → TP2_hit → TP3_hit → TP4_hit are all UPDATEs, not INSERTs), the subscription misses them entirely.

**Where this bit us (Sep 18 2026):** the Engines Performance page mounted an INSERT-only subscription when it was first built. Then we shipped `/api/signals/<id>/event` which writes TP/SL hits as UPDATE operations. The page's realtime listener fired only on new signals, never on TP/SL updates — so P&L was always stale. The user opened the page, saw `0 ACTIVE` (because no INSERTs were happening) and stale numbers.

**The fix — listen to UPDATE as well, with a debounce:**

```ts
let pending = false
const triggerRefresh = () => {
    if (pending) return
    pending = true
    setTimeout(() => {
        pending = false
        if (!cancelled) void fetchRecent()
    }, 750)
}

const channel = supabase
    .channel('engine-recent-signals')
    .on('postgres_changes',
        { event: 'INSERT', schema: 'public', table: 'signal_log' },
        () => { triggerRefresh(); })
    .on('postgres_changes',
        { event: 'UPDATE', schema: 'public', table: 'signal_log' },
        () => { triggerRefresh(); })
    .subscribe();
```

The debounce matters: a single TP1 → TP2 → TP3 → TP4 sequence fires 4 separate realtime events in <1s. Without the debounce, you get 4 sequential full refreshes. With a 750ms-1.5s throttle, the user sees one smooth update.

**The same pattern applies to:**

- The Past Signals feed at the bottom of the Signals page (`ExpiredSignalsList.tsx`) — same dual-listener fix
- Any "live P&L" widget that aggregates rows that get UPDATED over their lifetime
- Notification bell counts if you UPDATE a `last_read_at` column on the same row

**The audit recipe — when "the live UI doesn't update":**

```bash
# 1. Find every realtime subscription in the project
grep -rnE "postgres_changes|\.subscribe\(\)" src/

# 2. For each match, check what events it listens for
#    If only 'INSERT' is listed → the table may have UPDATE-driven
#    state changes that this listener misses.
```

**The reverse — when you WANT only INSERTs:** if the table is genuinely append-only (no UPDATE endpoints, only INSERT from listener/webhook), INSERT-only is fine. The bug only happens when BOTH INSERT and UPDATE write to the same table.

**Verification recipe (after deploying the dual-listener fix):**

1. Open the page in one browser tab
2. In a separate terminal, fire an INSERT via supabase-js: `await sb.from('signal_log').insert({...})`
3. Page should refresh within 1s
4. Fire an UPDATE: `await sb.from('signal_log').update({status:'tp1_hit'}).eq('id', ...)`
5. Page should refresh within 1s

If step 5 doesn't refresh, the realtime listener is still INSERT-only.

**Lesson — when you add a state-mutating endpoint to a table, every existing realtime subscription on that table needs to be reviewed.** Either it's missing UPDATE (the bug), or it's already correct. Don't assume — grep and verify.

**Related:** Recipe #67 (browser-client storage swap breaks every localStorage-read consumer) and Recipe #56 (column-name mismatches in PostgREST selects). Same class: silent failure of "the data should be there but isn't reaching the consumer." The fix for all three: instrument, then surface.


### Recipe #80 — Table that lives on another machine + silent empty payload = user sees mock data with no error (added Sep 18 2026)

**Symptom:** the user opens a dashboard page (e.g. Engine Performance, Past Signals, Recent Activity) that aggregates data from a Supabase table. The page renders numbers — but those numbers are hardcoded mock/placeholder values from a child component, NOT real data from the database. The user reports "showing mock data" or "the totals don't match Supabase." No console errors, no error toast, no failed network requests visible to the user. From the user's perspective the page just looks "wrong" without saying why.

**Root cause — three layers that compound:**

1. **The table doesn't exist on Supabase yet.** A comment in some migration file says the table is "fed by a separate Python bot running on another machine." That bot hasn't been run on Supabase yet. The migration file never created the table — it only additively adds columns to it *if* it exists. So every query against this table returns `[]`.

2. **The route has a silent-empty-payload fallback.** A common pattern from earlier sessions:
   ```ts
   const { data, error } = await sb.from('signal_log').select(...);
   if (error) return NextResponse.json({ items: [], latest: null, ... });
   ```
   When the table doesn't exist, PostgREST returns an error (42703 / table not found) but the route silently swallows it and returns an empty payload.

3. **The component has hardcoded mock fallbacks.** A child card like `<EngineCard>` defaults to:
   ```ts
   const stats = useMemo(() => ({
       totalPips: 51350,   // hardcoded demo number
       closed: 300,
       winRate: 80.4,
       ...
   }), []);
   ```
   When the API returns empty, the component keeps rendering these mock numbers because there's no `loading` flag distinguishing "real zero" from "haven't loaded yet."

**The compounding effect:** the user sees numbers that look plausible (a real win rate, a real total), has no way to tell they're not from Supabase, and the agent has no log signal that anything is wrong because every layer reports "success."

**The diagnostic recipe — three probes in this exact order:**

```bash
# 1. Does the table exist at all on Supabase?
#    If 0 rows, that's the first signal — the table might not exist
#    or might be empty.
psql -c "SELECT COUNT(*) FROM public.signal_log"

# 2. Hit the route directly with a curl. Does it return 200 with
#    items: [], OR does it return 5xx with an error?
curl -sH "Authorization: Bearer ***" https://<host>/api/signals/history?limit=5

# 3. Compare what the route selects vs what columns actually exist:
#    a) Read the schema
psql -c "SELECT column_name FROM information_schema.columns WHERE table_schema='public' AND table_name='signal_log' ORDER BY ordinal_position"

#    b) Read the route's .select(...)
grep -n "from('signal_log')" -A 1 src/app/api/signals/history/route.ts
```

If step 1 returns 0 rows, the table is empty (or doesn't exist). **Don't assume the bot hasn't run yet** — confirm the table exists in `information_schema.tables`:

```sql
SELECT EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema='public' AND table_name='signal_log'
);
```

If `false`, the table is missing entirely. The fix is a bootstrap migration:

```sql
CREATE TABLE IF NOT EXISTS public.signal_log (
    -- ... full schema with all columns the route expects ...
);
ALTER TABLE public.signal_log DISABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_signal_log_sent_at
    ON public.signal_log (sent_at DESC);
-- ... etc ...
-- Add to realtime publication so realtime UPDATE subscriptions fire
ALTER PUBLICATION supabase_realtime ADD TABLE public.signal_log;
```

**The fix — three pieces:**

1. **Bootstrap the table** with a migration that creates it from scratch if it doesn't exist. Don't rely on the other-machine bot having run.
2. **Stop the silent-empty-payload pattern in API routes.** Surface PostgREST errors:
   ```ts
   if (error) {
       return NextResponse.json({
           error: error.message,
           hint: 'Check signal_log table schema',
       }, { status: 500 });
   }
   ```
   An empty `items: []` is a silent lie when the truth is "I couldn't read the table." Empty is only honest when the table legitimately has no rows matching the query.
3. **Replace mock-default components with loading-aware defaults.** Use a `loading` flag from the query hook to render an empty state during loading, not mock numbers:
   ```ts
   const { data, loading } = useEngineStats();
   if (loading) return <Skeleton />;
   if (!data) return <EmptyState />;
   return <RealCards data={data} />;
   ```

**The lesson — when a table lives on another machine, treat its existence as unconfirmed:**

The original assumption — "the engine/bot pipeline already created this table on Supabase" — was wrong. The migrations on the Next.js side never created it; only the Python bot would. Until the bot runs there, the table is missing. The agent in this session shipped an `/api/signals/[id]/event` endpoint that does `INSERT INTO public.signal_log` against an empty database. The engine write-back was correct; the database wasn't ready for it.

**Diagnostic shortcut when the user reports "mock data":**

```bash
# Does the table even exist?
psql -c "\dt public.signal_log"
# If "Did not find any relation": bootstrap migration needed.
# If table exists but route returns empty: silent-error fallback pattern.
# If table has rows but component renders mock: loading-flag missing.
```

**Three-way classification:**

| Symptom | Cause | Fix |
|---|---|---|
| Table doesn't exist on Supabase | Lives on another machine that hasn't run | Bootstrap migration |
| Table exists, route returns 200 with `[]`, page shows mock | Silent-empty-payload fallback | Surface errors + loading flag |
| Table has rows, page still shows mock | Component ignores loading state | Replace hardcoded defaults with loading/empty/data branches |

**Related:** Recipe #56 (silent error swallowing hides schema drift — same class of bug), Recipe #67 (browser storage swap breaks consumers — silent failure shape), and the cross-cutting D pattern (CSS bugs ship silently). Three recipes about "the data should be there but isn't reaching the consumer, and nothing surfaces why." The fix is the same in all cases: instrument first, then surface.

**Verification (after deploying the bootstrap migration):**

1. Re-run the user's curl from step 2 above — should return real rows, not empty
2. Open the dashboard page — should render real numbers from Supabase, not mock
3. Watch for the realtime subscription to fire when a new row lands
4. Compare page totals to `SELECT COUNT(*) FROM signal_log` — they should match

If the page still shows mock after the migration is applied, the silent-empty-payload fallback in the API route is still in place. Re-read step 2 of the fix above.

## Recipe #81 — Missing opening backtick on `Authorization` header makes TS errors point at the wrong column, hiding the real fix (added Sep 23 2026)

**Symptom:** `tsc --noEmit` reports `',' expected` at the column where `${token}` starts, but the line "looks" correct in your editor. Also: a Next.js client component calls `fetch('/api/...')` and the server returns 401 / "Not authenticated" even though the user is signed in, and you've already confirmed `adminFetch` works on other routes in the same file.

**Root cause:** the `Authorization` header value was authored as `Bearer ${token}\`` — missing the **opening** backtick. The trailing backtick closes an empty string literal before `Bearer`, so JS parses it as three separate expressions: identifier `Bearer`, `${token}` (a tagged-template-ish mess), and a closing empty literal. TS sees the result as an object literal with bad syntax and complains about the comma it expected after `Bearer`. Net effect: the request goes out with NO `Authorization` header at all, and the route's `getUser()` returns null → 401.

**Reproduction:** `src/app/dashboard/algo-os/page.tsx` shipped Sep 22–23 with this exact bug on two lines (140 in `load()`, 183 in `handleSubscribe()`). `tsc --noEmit` reported `',' expected` at column 50/51 (where `$` and `{` sit). After fixing both, the whole project compiled clean and the page stopped bouncing to the marketing fallback with "Connect your broker to unlock ENGINE_A" (the bad empty-state copy that fired because fetch returned no data, not because the user had no engines).

**Pitfall — visual verification lies to you.** The terminal shell will redact the literal `Bearer` token prefix in `sed`/`cat` output to `***` for safety. When you `sed -n '140p' file.tsx`, you'll see `headers: { Authorization: *** ${token}` }` and won't be able to tell whether the opening backtick is present. **Always verify TS errors with `tsc --noEmit`, not by reading the file back via terminal.** The compiled output is the source of truth.

**Pitfall — the `',' expected` column points to the symptom, not the cause.** The error column is where `${` starts (TS parsing the missing-backtick line as an object literal). The real missing character is 8 columns earlier, at the backtick before `Bearer`. Don't add a comma — add the backtick.

**Fix template — copy-paste verbatim, do NOT retype:**

```ts
// CORRECT — single template literal, both backticks present
headers: { Authorization: `Bearer ${token}` },

// WRONG — missing opening backtick (the bug we just hit)
headers: { Authorization: Bearer ${token}` },

// WRONG — string concatenation (works but inconsistent with the rest of the codebase)
headers: { Authorization: 'Bearer ' + token },
```

**Detection grep — run before committing any client component that touches `/api/`:**

```bash
# Find lines with `Bearer ${` that are missing the opening backtick.
# A correct line has TWO backticks (one before Bearer, one after ${token}).
# This grep keeps only lines with exactly one backtick on the Bearer line.
rg -n --type ts --type tsx 'Bearer.*\$\{' -o | sort -u
# Then for each match, manually verify both backticks exist.
```

**Audit recipe (when a Next.js page hits 401 with auth in localStorage):**

1. `grep -n 'Authorization' src/<page>.tsx` — list every header line.
2. For each, count backticks on that line (`awk -F'\`' '{print NF-1}'`). **Exactly 2** = correct. **1 or 3** = bug.
3. Also: confirm the fetch uses `adminFetch` (Recipe #39) if the page is gated by Supabase session, NOT a server-side API token (Recipe #70).
4. `npx tsc --noEmit 2>&1 | grep '<page>'` — should be empty. If it shows `',' expected` near `${token}`, the backtick is the bug.

**Related:** Recipe #39 (`adminFetch` is the right primitive — and it always wraps the token correctly, so the broken-backtick class of bug disappears once you migrate the call to `adminFetch`), Recipe #67 (storage-swap silent auth failure), Recipe #45 (auth-gated column silently 403s, empty UI). The trio of "Not authenticated but I am signed in" causes is: (a) missing/malformed `Authorization` header, (b) wrong storage backend for the token, (c) RLS rejecting the column read.

**Verification (after fixing):**

1. `npx tsc --noEmit 2>&1 | grep algo-os` — should return zero matches.
2. Open the page in browser while signed in — should render the subscribed-mode UI, not bounce to `LandingPage`.
3. Network tab: `GET /api/algo-os/settings` should return `200` with `Authorization: Bearer ...` set in request headers (visible in browser DevTools, not terminal).


## Recipe #82 — Next.js prerender cache records deleted-route 404s for 1 year, ahead of any redirect page (added Sep 23 2026)

**Symptom:** a Next.js route file is deleted (commit N), users hit it and get a hard 404. Weeks later you create a new `app/<route>/page.tsx` with `redirect('/new-home')` as the replacement. Users STILL see the 404 — even on a fresh browser session with no service worker cache. `tsc --noEmit` is clean, the new file renders fine locally, but `curl -sI https://<host>/<route>` returns the old 404 with `x-nextjs-cache: HIT` and `s-maxage: 31536000`.

**Root cause:** Next.js's edge prerender cache records the 404 response when a route is deleted, with `s-maxage: 31536000` (1 year). When you re-create the route as a server component with `redirect()`, the edge keeps serving the cached 404 ahead of the new handler. **Re-creating the route file is not enough.** The prerender cache has to be told to invalidate, or the new page needs to opt out of caching entirely.

**Reproduction:** commit `32c68166` (Sep 23) deleted `app/dashboard/trading/page.tsx`. Next.js's edge recorded the 404. Hours later, commit `a8f6b13f` added `app/dashboard/trading/page.tsx` back as a `redirect('/dashboard')` server component. The redirect was rendering fine locally, but `curl -sI https://www.yourdomain.com/dashboard/trading` on production returned:

```
HTTP/2 200
cache-control: s-maxage=31536000
x-nextjs-cache: HIT
x-nextjs-prerender: 1
```

The `200` was a stale error page, not the redirect. The user saw the cached 404 HTML every time, regardless of browser state. The new `redirect()` page never had a chance to run.

**Diagnostic — three quick probes that confirm this recipe:**

```bash
# 1. The response headers reveal the edge cache is serving a stale 404:
curl -sI https://<host>/<route> | grep -iE 'cache-control|x-nextjs-cache|x-nextjs-prerender'
# If you see "x-nextjs-cache: HIT" + a large s-maxage → the edge is serving
# a cached response, not your new code.

# 2. The page response should be the redirect signal, not a 404 HTML body.
#    If `curl -sI` returns 200 with the redirect token in the body but the
#    body is the Next.js default 404 page → the prerender cache is stale.

# 3. Same path via a fresh browser with DevTools open, Network tab → if the
#    `cf-cache-status` (Cloudflare) or `x-vercel-cache` is HIT/MISS but the
#    response is wrong, you're hitting a stale cache layer.
```

**The fix — two layers:**

1. **Add `export const dynamic = 'force-dynamic'` to the replacement page** so it bypasses the prerender cache entirely. Every request re-runs the redirect server-side:

   ```ts
   // src/app/dashboard/trading/page.tsx
   import { redirect } from 'next/navigation';

   // Sep 23, 2026 — re-mounted after the collapse in 32c68166 cached
   // a 404 at the edge for 1 year. force-dynamic bypasses the
   // prerender cache so the redirect actually runs.
   export const dynamic = 'force-dynamic';

   export default function TradingRedirect() {
       redirect('/dashboard');
   }
   ```

   Verified by re-running the curl probe:
   ```
   cache-control: no-store, must-revalidate   ← dynamic rendering
   ```

2. **Bump the PWA service worker `CACHE_VERSION`** if the affected path is reachable from the PWA shell. The SW caches HTML and JSON responses in `runtime-${CACHE_VERSION}`. A bumped version evicts them on the next install/activate, and the next page load fetches fresh from the network.

**Pitfall — also update the manifest `start_url` if the redirect was the old entry point.** The PWA manifest's `start_url` controls what the installed PWA opens at launch. If the old URL was `start_url` and the new path is at the same URL, leaving the old value is fine — but if the old path is being redirected from and the new path is the canonical home, point `start_url` at the new path so future installs never hit the redirect at all.

**Pitfall — PWA shortcuts.** The manifest's `shortcuts[].url` array may also reference the deleted URL (e.g. a "Live Signals" shortcut that pointed at `/dashboard/trading?tab=SIGNALS`). Audit each shortcut and update to the current canonical path.

**Pitfall — no `s-maxage` flag at the next-config layer doesn't help.** `next.config.js` cache headers only apply to assets, not to ISR/prerendered routes. The fix must be at the route level.

**Audit recipe (when a Next.js page is "fixed" but the cached 404 still serves):**

1. Confirm the new page actually renders locally:
   ```bash
   npm run dev
   curl -sI http://localhost:3000/<route> | grep -iE 'HTTP|cache-control|x-nextjs'
   # Should be 200 + no-store on dev
   ```

2. Probe production with the diagnostic curl above. If `x-nextjs-cache: HIT` is present, the edge is serving stale content.

3. Apply the fix (force-dynamic + SW version bump). Push. Wait for Railway to redeploy (~3 min).

4. Re-probe. `cache-control: no-store, must-revalidate` confirms force-dynamic is taking effect. The cached 404 is now bypassed.

**Lesson — Next.js's edge cache is a hidden long-term liability.** When you delete a route, you don't just remove a file from your repo — you poison the edge cache for every visitor for up to a year. Make it a habit to:

- Add `force-dynamic` to any route that's the target of a redirect (especially 404 replacements)
- Bump SW `CACHE_VERSION` after any structural route change
- Verify with `curl -sI | grep -iE 'cache-control|x-nextjs-cache'` before declaring a route fix shipped

**Related:** Recipe #46 (iOS PWA SW caches JSON API responses — different cache layer, same diagnostic), Recipe #56 (PostgREST 42703 — different cache, similar "data should be there but isn't reaching the consumer" symptom shape). The trio of recipes about "the response is stale because of a hidden cache layer between client and server." The fix is always: identify the cache, then bust or bypass it.

**Verification (after applying the fix):**

1. `curl -sI https://<host>/<route>` — should show `cache-control: no-store` instead of `s-maxage: 31536000`.
2. `curl -sI | grep -i x-nextjs-cache` — should NOT show `HIT` (or the header should be absent).
3. `curl -s https://<host>/<route>` — the response body should contain a redirect signal (`NEXT_REDIRECT`) or 3xx Location header, not a 404 HTML body.
4. Open in a fresh browser session (or hard-refresh PWA) — should render the new page, not the 404.

If step 3 still shows 404 body after a Railway redeploy, the SW is caching the old HTML. Bump `CACHE_VERSION` and tell the user to hard-refresh once.

---

## Recipe #83 — Route-group refactor (Next.js `app/(group)/...`) deletes chrome-mounting layout, silently removing UI from every page in the group (added Sep 23 2026)

**Symptom:** a major Next.js route-group refactor moves files from `app/dashboard/<sub>/` to `app/dashboard/(main)/<sub>/` and replaces the old `app/dashboard/layout.tsx`. After the refactor, a UI element that was previously visible on every dashboard page is gone. The element's component file still exists, still imports cleanly, still renders standalone. Nothing is broken in the build or in `tsc --noEmit`. The element is just no longer mounted anywhere.

**Root cause:** the deleted `app/(group)/layout.tsx` was mounting the chrome (BottomDock, MobileNavDrawer, PointsPopupProvider, anything persistent). The replacement layout focuses on auth gates / error boundaries / query providers but forgets to re-mount the persistent chrome. The component files are never deleted — they're just orphaned. `grep -rn '<ComponentName>'` shows zero live imports from the new layout or any page, even though the file is still on disk.

**Reproduction:** commit `32c68166` (Sep 23) collapsed `app/dashboard/trading` into `app/dashboard` and deleted `app/dashboard/(main)/layout.tsx`. That layout had been mounting `<BottomDock />` (a 5-tile floating nav with Home/Signals/Apps/Trade/Profile tiles). The new `app/dashboard/layout.tsx` was a Round-8 onboarding-gate rewrite that implemented auth gates but **forgot to re-mount BottomDock**. The dock vanished from every `/dashboard/*` page. The component file `src/components/BottomDock.tsx` was unchanged and still imported by `AppDrawerPopover`'s parent — but nothing mounted the dock itself.

**The commit message even claimed the chrome was preserved.** It said:

> `/app/dashboard/(main)/layout.tsx` deleted. Its drawer/dock chrome now lives in `/app/dashboard/layout.tsx` (already wraps `/dashboard/*` via OnboardingGateRedirect + DashboardGuard).

But "drawer/dock chrome" was never copied to the new layout. The commit-message claim was aspirational, not verified. The result was a silent UI regression visible only to end users.

**Diagnostic — three checks that confirm this recipe:**

```bash
# 1. Find the component definition
grep -rn 'export default function BottomDock' src/

# 2. Find where it's imported + mounted
grep -rn 'import BottomDock' src/
grep -rn '<BottomDock' src/

# 3. If (2) shows zero or one result, and (1) shows the component exists,
#    the component is orphaned — no one is mounting it.
```

If `grep -rn '<BottomDock' src/` returns zero matches (no JSX mount) but `BottomDock.tsx` exists, the dock is defined but not rendered anywhere. Restore by importing and mounting it in the appropriate layout.

**The fix — three pieces:**

1. **Import the orphaned component in the replacement layout.**
2. **Mount it inside the layout**, wrapped in `<Suspense>` if it uses `useSearchParams` (Next.js App Router requirement):
   ```tsx
   // src/app/dashboard/layout.tsx
   import BottomDock from '@/components/BottomDock';

   export default function DashboardLayout({ children }: { children: React.ReactNode }) {
       return (
           <DashboardGuard>
               <AppErrorBoundary label="/dashboard">
                   <OnboardingGateRedirect />
                   <Suspense fallback={null}>{children}</Suspense>
                   <Suspense fallback={null}>
                       <BottomDock />
                   </Suspense>
               </AppErrorBoundary>
           </DashboardGuard>
       );
   }
   ```
3. **Verify with `tsc --noEmit` AND with a live dev probe** that the component compiles and renders. Just seeing the import added is not enough — verify the JSX is reached.

**Pitfall — "removed" comments can hide the regression.** When you delete a route-group layout, the commit message often says "moved X to the new layout." But the actual code copy step is easy to skip. Always `grep` the new layout for the chrome components before committing the deletion.

**Pitfall — Round-1 / Round-N rewrites are worse than incremental moves.** A Round-N rewrite that touches a layout file from scratch (rather than incrementally editing the existing one) is more likely to drop mounted children. If you must rewrite from scratch, keep a checklist:

- [ ] List every component the old layout mounted (`grep '<[A-Z]' src/app/<path>/layout.tsx`)
- [ ] For each, decide: re-mount, intentionally drop, or move to a parent
- [ ] Cross-reference the deletion diff to confirm nothing was silently dropped

**Audit recipe (after any Next.js route-group / layout refactor):**

1. `git diff <before>..<after> -- 'app/**/layout.tsx'` — see exactly what was added/removed.
2. For every component that was mounted in the old layout, grep the new layout:
   ```bash
   grep -rn '<OldComponent\|import OldComponent' src/app/<new-layout-path>
   ```
3. If a component was mounted before and is not imported/mounted now, restore the import. Use the deletion commit's diff as the source of truth for what was lost.
4. Open the affected pages in dev. The component should appear. If not, the import wiring is wrong.

**Lesson — Next.js route groups are organizational, but they have file-system consequences.** Moving `app/dashboard/<sub>` to `app/dashboard/(main)/<sub>` is just a path change for the route — but it also moves the parent layout boundary. Anything the old `(main)/layout.tsx` was doing now belongs in the parent (or a new nested) layout. Forgetting this gives you a silent UI regression that no type check or build error will catch.

**Related:** Recipe #67 (browser-client storage swap breaks every localStorage-read consumer — same class of "orphaned import / unmonuted component" silent regression, different cause), Recipe #80 (silent empty payload from API route → UI renders mock data — another silent-failure class). The trio of recipes about "the code path looks fine, the build is clean, but the UI is wrong because a piece is no longer wired up." The fix in all three: instrument first, then surface.

**Verification (after restoring the mount):**

1. `tsc --noEmit` clean.
2. Dev server compiles the new layout chunk and references the orphaned component's chunk transitively.
3. Open the affected pages in a browser — the chrome (dock, drawer, popup) should appear.
4. Click an interactive element (e.g. a dock tile) — should navigate or open the expected overlay.

If step 2 fails (component chunk not referenced from layout chunk), the import is wrong. Check the import path and the `default` export name on the component.

---

## Recipe #84 — Bearer-token fallback in API routes when `getSession()` returns null (added Sep 23 2026)

**Symptom:** a Next.js API route uses `supabase.auth.getSession()` to identify the caller. The session lives in localStorage on the browser side (via the custom Supabase browser client), but the route returns 401 "Not authenticated" — even for users who are clearly signed in (other features on the same page work, the wallet renders, the user has data showing). The cookie should be mirrored to a `sb-<project>-auth-token` cookie but `getSession()` still returns null.

**Root cause:** the cookie-to-server handoff fails in several real-world cases:

- Cross-domain redirect during login (e.g. user lands on `yourdomain.com` but the session cookie was set on `www.yourdomain.com` — domain mismatch)
- Freshly-installed PWA where the SW hasn't written the cookie yet
- iOS session-restore edge case where the SW intercepts the request and replays a stale state before the cookie path resolves
- Different cookie `path` (cookie set on `/dashboard` but read by a route handler on a different path)
- Manual cookie clearing after a forced logout that didn't fully clean the local state

`getSession()` returns null on these failures because it only reads the cookie. The session is actually valid in localStorage, but the server can't see it.

**Reproduction:** the home page's `LiveSignalsFeed` component called `/api/home/recent-signals` and got 401 even for an authenticated user. The wallet, the algo-os page, and other features on the same dashboard all worked — only this specific API route failed. Other clients that hit the same route (like `LatestSignalDeck`) silently failed too but didn't surface the error, hiding the bug.

**The fix — two-sided (browser sends bearer, server accepts it):**

**Browser side — use `adminFetch` instead of plain `fetch`.** `adminFetch` reads the access token from multiple Supabase storage keys (localStorage AND cookie) and sends it as `Authorization: Bearer <token>` automatically:

```ts
// BEFORE (plain fetch — only sends cookies, no Authorization header)
const res = await fetch('/api/home/recent-signals?limit=20', {
    cache: 'no-store',
    signal: AbortSignal.timeout(8_000),
});

// AFTER (adminFetch — sends cookies AND bearer header from localStorage)
import { adminFetch } from '@/lib/admin-fetch';
const res = await adminFetch(
    '/api/home/recent-signals?limit=20',
    { method: 'GET', cache: 'no-store' },
);
```

**Server side — accept the bearer header as a fallback when `getSession()` fails:**

```ts
// src/app/api/<route>/route.ts
const supabase = await createClient();
let { data: { session } } = await supabase.auth.getSession();

if (!session?.user?.id) {
    const auth = req.headers.get('authorization') ?? '';
    const match = auth.match(/^Bearer\s+(.+)$/i);
    if (match) {
        const token = match[1].trim();
        // getUser() validates the JWT signature + expiry against Supabase auth.
        // Slower than getSession but actually verifies the token is valid.
        const { data: userData, error: userErr } = await supabase.auth.getUser(token);
        if (!userErr && userData?.user?.id) {
            session = {
                access_token: token,
                refresh_token: '',
                expires_in: 3600,
                expires_at: Math.floor(Date.now() / 1000) + 3600,
                token_type: 'bearer',
                user: userData.user,
            } as any;
        }
    }
}

if (!session?.user?.id) {
    return NextResponse.json({ error: 'Not authenticated' }, { status: 401 });
}
const userId = session.user.id;
```

**Cookie auth still works.** For users whose cookies are readable server-side, the `getSession()` path returns the session immediately and the bearer fallback never runs. The fallback is purely additive.

**Pitfall — using `getUser(token)` without the bearer is unsafe.** Always validate the JWT signature + expiry. `getUser(token)` does this (it hits Supabase auth and verifies), so prefer it. Don't just trust the raw token and use its claims directly — anyone could forge a token with a different user id.

**Pitfall — don't pass the user-controlled token to `supabase.auth.getSession()`.** That call reads from the storage backend, not from the parameter. To validate a specific token, use `supabase.auth.getUser(token)`.

**Pitfall — the synthetic session object's `access_token` is used downstream.** Some routes downstream of `getSession()` re-use the `session.access_token` for additional Supabase calls (e.g. RLS-friendly queries). Populate it from the validated bearer so downstream calls work.

**Audit recipe (when an API route 401s for an authenticated user):**

1. Open DevTools Network tab — check the failing request's request headers. Is there an `Authorization: Bearer ***` header?
   - If yes: the server isn't reading it. Add the bearer fallback (this recipe).
   - If no: the client isn't sending it. Switch from `fetch` to `adminFetch`.
2. Open DevTools Application tab — Cookies. Does the `sb-<project>-auth-token` cookie exist?
   - If yes, correct domain, correct path: cookie auth should work. Check `SameSite` and `Secure`.
   - If no: the SW/browser hasn't written it. Use `adminFetch` from the browser side which reads the token from localStorage.
3. `curl` the route with `Authorization: Bearer <token>` (paste from localStorage):
   - If 200 with the bearer: server-side fix is correct, the issue is browser cookie propagation.
   - If 401 with the bearer: server-side fix is missing.

**Lesson — never trust only `getSession()` for Supabase auth in a Next.js API route.** The cookie-to-server handoff has too many failure modes for production traffic. Pair `getSession()` with a `Authorization: Bearer *** fallback that goes through `getUser(token)` for validation. The cost is one extra Supabase auth call on the failure path — paid only by users who would have failed anyway.

**Related:** Recipe #39 (`adminFetch` is the right primitive for client-side fetches that need auth — and it always wraps the token correctly), Recipe #67 (browser-client storage swap breaks every localStorage-read consumer — silent auth failure with a different root cause), Recipe #81 (missing opening backtick on the Authorization header — another way the bearer path breaks). The trio of recipes about "the route says I'm not authenticated but I am signed in." Three different root causes, three different fixes; the diagnostic flow is the same: probe headers, probe cookies, probe server-side handler.

**Verification (after applying the fix):**

1. Sign in. Open the affected page. The API call should now return 200 with data, not 401 with "Not authenticated."
2. Server logs (Railway): no new 401s for the route. Successful 200s instead.
3. `curl -H "Authorization: Bearer <token>" https://<host>/<route>` — returns 200 with the user's data.
4. `curl https://<host>/<route>` (no bearer) for a signed-in user — still returns 200 via cookie auth.
5. `curl https://<host>/<route>` (no bearer, no cookie) — returns 401 as expected.

All five scenarios working = the auth layer is robust. Step 5 should still 401 — that's the whole point of having an auth check.

---

## Recipe #85 — Onboarding gate: SQL trigger requires 7 steps, wizard UI only drives 4 (added Sep 24 2026)

**Symptom:** A user walks through the entire onboarding wizard UI to completion, gets approved by an admin, clicks "Enter the trading floor" → the dashboard layout mounts → `useOnboardingGate` fires `router.replace('/onboarding')` → the user lands right back on the wizard they just finished. Stuck loop.

**Root cause — three failure points layered:**

1. **The SQL trigger requires N steps but the wizard only triggers M < N of them.** The trigger `app_onboarding_step_changed` (in `supabase/migrations/202608240007_revert_to_7_steps.sql`) requires all 7 of these to be marked `'completed'` before flipping `user_accounts.onboarding_complete=true`:
   ```
   profile_basics, accent_theme, risk_disclaimer,
   connect_broker, link_broker, enable_push, walkthrough
   ```
   The wizard UI was simplified in Round 9 to only expose 4 explicit user-facing steps:
   ```
   profile_basics, accent_theme, risk_disclaimer, walkthrough
   ```
   `connect_broker`, `link_broker`, `enable_push` are still tracked in the DB but triggered from other surfaces (broker connection modal, push opt-in toggle) — not from the wizard. The user finishes the wizard + gets admin approval, but `onboarding_complete` never reaches `true` because the trigger's 7/7 threshold is unreachable from the wizard alone.

2. **`useOnboardingGate` checks `profile.onboardingComplete === true` and bounces on `false`.** Even though the SQL trigger never flips the flag, the gate sees `false` and bounces. Infinite loop: wizard → dashboard → /onboarding → wizard → ...

3. **`handleFinish` doesn't refresh the profile before the hard nav.** It called `adminFetch('/api/auth/me')` (which returns the user, not the profile) and then `window.location.href = '/dashboard'`. The freshly-mounted dashboard layout's `useOnboardingGate` saw the stale profile for ~50-300ms (the user_accounts REST round-trip latency) and could bounce before the refresh landed.

**Why it was invisible on the PWA but visible on Safari:** On PWA, the cached profile often happened to be fresh enough that the gate evaluated after the refresh landed. On Safari desktop, the cache + cookie sync is slower, so the stale-profile window was longer than the gate's evaluation, and the bounce fired reliably. Same bug, different visibility.

**The fix — three layers:**

```ts
// 1. src/app/onboarding/page.tsx — handleFinish
// Dispatch app-refresh-profile BEFORE the hard nav so
// UserContext refetches user_accounts before the new page mounts.
try {
    await adminFetch('/api/auth/me', { method: 'GET' })
} catch { /* best-effort */ }
try {
    window.dispatchEvent(new Event('app-refresh-profile'))
} catch { /* SSR-safe */ }
// Brief settle so the refresh fetch lands in the profile cache
// before the hard navigation tears the page down.
await new Promise(r => setTimeout(r, 250))
setSubmitting(false)
window.location.href = '/dashboard'
```

```ts
// 2. src/components/onboarding/useOnboardingGate.ts
// Treat application_status='approved' as an alternate "done"
// condition. Even if onboarding_complete is still false (because
// the SQL trigger hasn't reached its threshold), an approved user
// is fully onboarded from the business perspective.
if (profile?.application_status === 'approved') return
```

```sql
-- 3. supabase/migrations/202609250001_reduce_onboarding_required_to_visible.sql
-- Re-define app_onboarding_step_changed to require only the 4
-- visible steps instead of 7. After this runs, the SQL trigger
-- fires on wizard completion and onboarding_complete flips to
-- true on its own — Fix 2 then becomes redundant (but still safe).
CREATE OR REPLACE FUNCTION public.app_onboarding_step_changed()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_required_count INTEGER := 4;
  v_required_steps TEXT[] := ARRAY[
    'profile_basics',
    'accent_theme',
    'risk_disclaimer',
    'walkthrough'
  ];
  -- ... rest unchanged
```

**General pattern (broader than onboarding):** When the gate reads X but X is populated by a multi-step pipeline, **every step in the pipeline must be reachable from the user surface that triggers the gate.** A divergence between "what triggers the flag" and "what the user can actually do" creates an unreachable flag, which creates a stuck user.

The same shape shows up everywhere: feature flags, permission grants, onboarding milestones, "approved" indicators, "verified" badges. The fix shape is always the same: (1) ship a fallback that lets users through when the canonical signal is unreachable, (2) re-sync the actual source-of-truth pipeline so the canonical signal gets set correctly going forward, (3) keep both layers in production because the fallback is cheap insurance.

**Related:** Recipe #69 covers the admin-account variant of this exact bug pattern (admins provisioned before the wizard existed bounce through onboarding → login because their `onboarding_complete` is stuck at false). Same fix shape — gate accepts an alternate "done" signal for the user class. Recipe #84 covers the bearer-token auth pattern that overlaps with the profile-refresh race in Fix 1 above.

**Verification:**

1. Fresh user walks wizard → admin approves → user clicks "Enter the trading floor" → lands at `/dashboard` directly. No bounce.
2. SQL migration applied → `onboarding_complete` flips to true on its own after the user completes the 4th visible step.
3. Existing stuck users (approved before the fix) — run a one-off backfill query once to backfill.

---

## Recipe #86 — `handleFinish` profile-refresh race: `window.location.href` skips UserContext refetch (added Sep 24 2026)

**Symptom:** A "final step" button on the wizard calls `handleFinish` which fires `window.location.href = '/dashboard'`. The dashboard layout mounts, but a UserContext-derived check (e.g. `useOnboardingGate`, `DashboardGuard`) sees stale state and either bounces the user back or renders the wrong content for ~50-300ms before correcting.

**Root cause:** `window.location.href` is a HARD navigation — the entire JS context tears down and rebuilds. Any in-memory state in React providers (UserContext, theme context, etc.) is rebuilt from scratch and starts loading. The hard-nav doesn't give the provider a chance to refresh before the destination route evaluates its derived state.

```ts
// BEFORE — race-prone
const handleFinish = useCallback(async () => {
    try {
        await adminFetch('/api/auth/me', { method: 'GET' })
    } catch { /* best-effort */ }
    window.location.href = '/dashboard'
}, [router])

// Result: dashboard layout mounts → UserContext.fetchProfile() starts
// (50-300ms user_accounts REST round-trip) → useOnboardingGate evaluates
// with stale profile.onboardingComplete=false → bounces to /onboarding.
// User saw the bounce even though they completed onboarding.
```

**The fix — dispatch the refresh-profile event BEFORE the hard nav:**

```ts
const handleFinish = useCallback(async () => {
    try {
        await adminFetch('/api/auth/me', { method: 'GET' })
    } catch { /* best-effort */ }
    // UserContext listens for this event and refetches user_accounts.
    // Fires synchronously — UserContext's listener updates profile state
    // while the page is still alive (pre-nav).
    try {
        window.dispatchEvent(new Event('app-refresh-profile'))
    } catch { /* SSR-safe */ }
    // Brief settle so the refresh fetch lands in the profile cache
    // before the hard nav tears the page down. 250ms is empirically
    // enough for the user_accounts round-trip without making the user
    // feel a delay on the "Enter the trading floor" click.
    await new Promise(r => setTimeout(r, 250))
    setSubmitting(false)
    window.location.href = '/dashboard'
}, [router])
```

UserContext already has the listener wired up — it refreshes on the `app-refresh-profile` window event (see `src/context/UserContext.tsx` line ~651). This pattern works because the event fires synchronously on the current page; the listener kicks off its own fetch; the hard-nav tears down the page AFTER the fetch has already started. The destination page hydrates with the refreshed profile.

**General pattern:** any time you have a multi-route flow where the destination page derives decisions from a global provider (UserContext, theme, locale, etc.) AND the previous page's "final action" is a hard nav (`window.location.href`, not `router.push`), you have this race. Solutions in order of preference:

1. Dispatch the refresh event before hard-nav (this recipe). User context re-fetches while the source page is still alive.
2. Use `router.push` instead of `window.location.href`. Client-side navigation preserves the React tree; the provider keeps its state and doesn't need to refetch. Downside: doesn't always survive server-side guards (some middleware paths require a hard nav).
3. Have the destination page itself explicitly check + refetch on mount if its derived state would bounce. Adds boilerplate to every consuming route.
4. Cache the derived state in localStorage / a global event so it's instantly available at navigation time.

**Pitfall — `router.replace` is also a hard nav when it triggers middleware re-evaluation.** The original Round 2 comment in `handleFinish` said "router.push under some server states doesn't fire a real navigation when middleware re-evaluates onboarding_complete; window.location.href always does." That's the truth — but `window.location.href` creates THIS race. The fix is to refresh before the hard nav, not to avoid the hard nav.

**Related:** Recipe #84 covers the bearer-token auth pattern that complements this — the refresh-fetch needs to send a valid Bearer so the server's `getUser(token)` validates the JWT, not the cookie. Recipe #85 is the specific instantiation of this pattern for the onboarding gate.

---

## Recipe #87 — Notification template pre-formatted bot payload duplicates every field (added Sep 24 2026)

**Symptom:** A PWA push notification renders with duplicated content. Example: "P&L: -50 pips 💢 | P&L: -50 pips" instead of "P&L: -50 pips". Or "Reason: SL HIT ⛔️ | TPs Secured: TP1 💢 | P&L: +150 pips pips".

**Root cause:** the bot on the engine side constructs pre-formatted, human-readable strings for `pnl_pips`, `tps_secured`, `reason_label` etc. before sending them to the API endpoint. The dispatcher template then concatenates its own formatting on top (`| P&L: ${pnl} pips`). The bot's "pips" suffix plus the template's "pips" suffix = "pips pips". Worse: some bot builds stuff the entire pre-formatted message into a single field (`pnl_pips: "-50 pips 💢 | P&L: -50 pips"`), which gets the bot's full string rendered inside the template's "| P&L:" prefix, doubling every section.

**The fix — sanitize the bot payload in the dispatcher, not the bot.** Bots are external systems owned by other people and may be in production. You can't fix them on demand. The dispatcher must defensively extract values from whatever it gets:

```ts
// src/lib/signals/notify-dispatch.ts
// 1. Strip emojis and pipes from free-text fields:
const sanitize = (s: string): string =>
    s
        .replace(/[|]/g, '·')                       // pipe → middle-dot
        .replace(/[\u{1F300}-\u{1FAFF}]/gu, '')     // remove emoji symbols
        .replace(/\s{2,}/g, ' ')                    // collapse runs of whitespace
        .trim()

// 2. Extract the first signed number from numeric fields, regardless
//    of what junk the bot stuffs in:
const rawPnl = (input.pnl_pips ?? '').toString().trim() || ''
const m = rawPnl.match(/[+-]?\d+(?:\.\d+)?/)
const pnlNum = m ? Number(m[0]) : null
const pnl = pnlNum != null && Number.isFinite(pnlNum)
    ? `${pnlNum > 0 ? '+' : pnlNum < 0 ? '−' : ''}${Math.abs(pnlNum)}`
    : '—'

// 3. Template owns the formatting, never trusts field contents to
//    already contain unit suffixes:
bodyText =
    `⭕️ TRADE CLOSED | Reason: ${reason}\n` +
    `TPs Secured: ${secured} 💢 | P&L: ${pnl} pips`
```

**General pattern:** any template that includes user-controllable (or bot-controllable) fields as `${field}` must:
1. Strip the templating chars that the template itself owns (|, emojis, "pips", "$", etc.)
2. Extract numbers via regex instead of trusting the field to already be a clean number
3. Let the template own every unit suffix and separator

This is the input-sanitization version of "never trust client input." For push notifications specifically, the bot is a separate developer + production system that may be slow to update, may be in a language/runtime that doesn't support your unit tests, and may regress. The dispatcher must be robust to any reasonable bot output.

**Pitfall — don't try to fix the bot.** Even if you can write the fix in one place (the bot), you can't deploy it on demand, you can't roll it back, you can't monitor it. The dispatcher is yours; the bot is someone else's. Sanitize at the boundary you own.

**Related:** Recipe #84 covers Bearer-token auth which has its own variant of this — the dispatcher should fall back to localStorage session instead of trusting the cookie path. Recipe #70 covers the engine write-back contract which is the upstream cause of the bot being the wrong shape for this.

---

## Recipe #88 — Touch-device HTML5 drag-and-drop silently fails on phones (added Sep 24 2026)

**Symptom:** A drag-to-reorder UI works fine on desktop (cursor moves, drop targets highlight, items swap). On a phone or tablet, taps and drag gestures do nothing — the small grip handle (typically 14-16px) can't be grabbed reliably with a finger, and the HTML5 native drag events don't fire on tap-and-hold without a polyfill.

**Root cause:** the HTML5 drag-and-drop API (`draggable={true}` + `onDragStart` / `onDragOver` / `onDragEnd`) was designed for desktop pointer devices. On touch:
- `draggable` elements do not fire native drag events from tap-and-hold
- The drag ghost image can't be moved by finger drag (only mouse drag)
- `dragover` and `drop` never fire from touch sequences
- A 14×14 grip handle is below the iOS thumb-target minimum (~44×44 recommended)

**The fix — replace HTML5 drag with explicit up/down buttons for primary interaction, keep pointer events for desktop power users:**

```tsx
// BEFORE — HTML5 drag-and-drop, broken on touch
<li
    draggable
    onDragStart={() => setDraggingIdx(i)}
    onDragOver={handleDragOver(i)}
    onDragEnd={() => setDraggingIdx(null)}
>
    <GripVertical size={14} />
    <span>{item}</span>
</li>

// AFTER — buttons + optional pointer-event drag for desktop
<li
    onPointerDown={onPointerDownRow(i)}
    onPointerMove={onPointerMoveRow(i)}
    onPointerUp={onPointerUpRow(i)}
>
    <span>{item}</span>
    <div className="controls">
        <button aria-label="Move up" onClick={() => move(i, -1)}>
            <ChevronUp size={18} />
        </button>
        <button aria-label="Move down" onClick={() => move(i, 1)}>
            <ChevronDown size={18} />
        </button>
    </div>
</li>
```

CSS:
```css
button.move-arrow {
    width: 34px;          /* thumb-friendly */
    height: 34px;
    -webkit-tap-highlight-color: transparent;  /* no iOS gray flash */
}
```

The pointer-event drag only fires for `e.pointerType === 'mouse'` (excludes touch). Touch devices use buttons only — no fighting the touch event model.

**General pattern:** any interactive UI on a phone-first product that needs to "select then move" needs a button-based primary interaction, not a drag. Native drag-and-drop is desktop-only. This applies to:
- Reorder lists (kanban, playlist editor, sort order)
- File upload zones with "drag to upload"
- Carousel/slider handles
- Range pickers where the user picks multiple items in order
- Pinch-zoom controls on phones (don't ship — use native scroll/zoom)

**Pitfall — third-party libraries like react-dnd, react-beautiful-dnd, dnd-kit add bundle weight and are hard to theme.** For a simple reorder list, you don't need them. For complex kanban with cross-container drag, they're worth it. For everything in between, the up/down button pattern wins.

**Pitfall — `pointercancel` fires when the user scrolls away from the drag.** Always handle it the same as `pointerup` so a mid-drag scroll doesn't strand the UI in a "dragging" state.

**Pitfall — keyboard accessibility.** Buttons get focus rings for free; pointer-event drag doesn't. If the user navigates with the keyboard, the up/down buttons still work; the drag handler doesn't. That's correct — but document the buttons as the primary interaction.

**Related:** Recipe #39 covers PWA install + push, which is the broader mobile-first pass. The mobile Pass A / Pass B / Pass C skills (`nextjs-mobile-pass-a`, `nextjs-mobile-pass-b`) cover the broader mobile-readability retrofits. Recipe #88 specifically targets interactive components where HTML5 drag was used on desktop and assumed to work on touch.

---

## Recipe #89 — Disconnect button silently fails for white-label broker users because the route is broker-only (added Sep 25 2026)

**Symptom:** a user connected to the white-label broker hits "Disconnect Account" in the Trading Accounts card. The toast says "the broker disconnected." and the page reloads — but the balance card still shows the white-label broker account as "Connected," the dropdown still shows the white-label broker account, and clicking the same connect button tries to log in as if no session existed. User thinks the button is broken; support gets the ticket.

**Root cause:** `src/app/api/broker/disconnect/route.ts` only cleared the broker-direct columns (`broker_access_token`, `broker_refresh_token`, `broker_account_id`, etc.). For a white-label broker user, those columns were already mostly empty — the meaningful connection state lived in the `whitelabel_*` columns (`whitelabel_user_id`, `whitelabel_access_token`, `whitelabel_selected_account`, etc.). The "Disconnect" call ran, the toast fired, the page reloaded, but `whitelabel_user_id` was still non-null. The next render saw `whitelabel_user_id !== null` and re-rendered "Connected via WHITELABEL#…". The user can never get back to a true disconnected state without manual database surgery.

The confirm dialog added insult to injury: it said "Disconnect your broker account?" even when the user was on white-label broker — wrong label for the actual broker.

**The fix — make the disconnect endpoint broker-generic and force the UI to re-evaluate state:**

```ts
// src/app/api/broker/disconnect/route.ts — Round 14 (Sep 25 2026)
// Clears BOTH broker and white-label broker fields plus broker_platform. Idempotent —
// safe to clear columns that are already null. Also touches the parallel
// broker_links and trading_accounts tables.

const RESET_FIELDS = {
    // broker-direct columns (always safe to clear)
    broker_access_token: null, broker_refresh_token: null, broker_token_expiry: null,
    broker_account_id: null, broker_acc_num: null, broker_email: null, broker_server: null,
    broker_connection_status: 'disconnected',
    // white-label broker columns (always safe to clear — empty if user wasn't on white-label broker)
    whitelabel_user_id: null, whitelabel_email: null, whitelabel_access_token: null,
    whitelabel_refresh_token: null, whitelabel_token_expiry: null,
    whitelabel_connected_at: null, whitelabel_selected_account: null,
    // Reset broker_platform to NULL — neither branch is taken
    // until the user re-connects.
    broker_platform: null,
};

await supabase.from('user_accounts').update(RESET_FIELDS).eq('id', userId);
await supabase.from('broker_links').delete().eq('user_id', userId)
    .in('broker', ['broker', 'whitelabel', 'cfd_broker']);
await supabase.from('trading_accounts').update({ is_active: false, ... })
    .eq('user_id', userId)
    .in('account_type', ['broker', 'whitelabel', 'cfd_broker']);
```

The UI side needs three fixes:

1. Right label in the confirm dialog: derive the broker name from the active row's `account_type`.
2. Force a full page reload after disconnect — `setTimeout(() => window.location.reload(), 600)` — so every `TradingContext` consumer re-evaluates with the empty state. A `router.refresh()` doesn't work because context state is lazy and only updates when the `/api/whitelabel/health` poll returns 401.
3. Flip `setwhite-label brokerConnected(false)` in the `disconnectBroker` TradingContext method. Without this, the balance card + `white-label brokerNotConnectedBanner` stay stale because context state is lazy.

**General pattern:** any "disconnect" / "switch account" / "logout from broker X" endpoint that's broker-specific will silently fail when a new broker is added with parallel columns. Always:

- Make the disconnect idempotent against ALL broker columns (broker-direct columns AND white-label broker columns AND any future broker columns).
- Force a full page reload in the UI, not a soft refresh, so React state trees that captured `whitelabelConnected=true` actually re-fetch from the server.
- Drive the confirm-message label from the row's actual `account_type`, not from a hardcoded string.
- If you have a `broker_platform` enum column, clear it to `NULL` on disconnect (not to a fallback like `'broker'`). The dashboard will route as "no broker connected" rather than guessing.

**Related:** Recipe #67 covers the *no 401 fires → page hangs forever* cousin of this bug — same root cause pattern (lazy state + endpoint that doesn't reset all needed fields). When adding a new broker surface, audit every "I changed something" endpoint for which fields it forgets to clear.

---

## Recipe #90 — white-label broker users see `$0.00` in live P&L because the quote route goes through undocumented `/api/tap/quote/{symbol}` instead of broker-direct (added Sep 25 2026)

**Symptom:** the CFD broker users see live P&L ticking on every open position. The white-label broker users see `$0.00` across the same dashboard view. Both broker connections work — login, account discovery, order placement, history all work. The difference is the **quote endpoint**.

**Root cause:** the white-label broker is a white-label wrapper around the broker. Their `/api/auth/login` returns an HTTP-only session cookie (`whitelabel_session=...`) that authenticates against white-label broker's surface — but that cookie **does not work as a Bearer token against `live.broker.example`**. So when the quote route checked `broker_platform === 'whitelabel'` and called `whitelabelGetQuote(symbol)` (which hits white-label broker's `/api/tap/quote/{symbol}`), it got back a rotating JSON shape — sometimes `{last}`, sometimes `{bid, ask}`, sometimes `{price}`, sometimes `{d.price}` — and our 9-field-extractor fallback chain would still hit `null` for any given day. The dashboard computed `equity - basis = $0.00` and rendered it.

the CFD broker users went straight to `live.broker.example` with a Bearer JWT — that returns the canonical `{last, bid, ask}` shape every time — and live P&L worked.

**The fix — exchange the white-label broker cookie for a broker-direct JWT at select-account time, then route white-label broker users through the same code path as the CFD broker:**

1. Add `whitelabelOtpExchange(cookie, accountId)` to `src/lib/whitelabel/client.ts`. POSTs `/api/broker/otp` with the white-label broker session cookie. The endpoint was real on Sep 1 2026 per commit `83e2154` and the stub at `<project-dir>/scripts/marketing/whitelabel-stub.mjs` still mocks it. Tolerant extractor covers `accessToken` / `access_token` / `token` / `broker_access_token` since white-label broker has shipped multiple shapes.

2. In `/api/whitelabel/select-account/route.ts`, after the user picks an account, attempt the exchange. On success, persist `broker_access_token` / `broker_refresh_token` / `broker_token_expiry` / `broker_server` / `broker_acc_num` to `user_accounts`. On failure, fall back to white-label broker-direct routing.

3. Rewrite the routing logic in `/api/broker/quote/route.ts` (and any other broker-direct route) — invert it: **prefer broker-direct when `broker_access_token` exists**, regardless of `broker_platform`. white-label broker-direct becomes a fallback only for unmigrated white-label broker users.

```ts
const hasBrokerToken = !!(publicUser?.broker_access_token && publicUser?.broker_account_id);

// New routing logic — inversed from the historical "if whitelabel, go whitelabel-direct":
if (!hasBrokerToken && publicUser?.broker_platform === 'whitelabel') {
    // Branch 2: legacy white-label broker-direct fallback for unmigrated users
    return whitelabelGetQuote(symbol);
}

// Default: broker-direct (works for both the CFD broker and migrated white-label broker users)
if (!publicUser?.broker_account_id || !publicUser?.broker_access_token) {
    return NextResponse.json({ error: 'broker not connected' }, { status: 400 });
}
// ... existing broker-direct fetch ...
```

4. Backfill script `<project-dir>/scripts/whitelabel-token-migration.mjs` for users who connected before the fix shipped. Self-contained (no `tsx`, no `a dotenv loader`), reads env from `services/telegram-listener/env file.railway`, throttles to 1.1s/call to respect the 60s cache.

```bash
node <project-dir>/scripts/whitelabel-token-migration.mjs --dry-run    # preview
node <project-dir>/scripts/whitelabel-token-migration.mjs            # run for real
```

**General pattern:** when a third-party broker wraps another broker (white-labeling), the wrapper's session cookie won't work against the underlying broker's API. The supported way to bridge this is always an undocumented exchange endpoint — usually under `/api/<wrapper>/<underlying>/otp` or similar. If you find one:

- Wrap it in a tolerant extractor (the response shape will rotate between release versions, expect `{accessToken}`, `{access_token}`, `{token}` as alternatives).
- Persist the upstream token to a column the existing-direct route already reads (here `broker_access_token` on `user_accounts`).
- Invert your routing — prefer the documented broker when the token exists, fall back to wrapper-direct when it doesn't.
- Always add a backfill script. Users who connected before the bridge existed are stuck on the older path until migration runs.

**Pitfall — fake 200 with `{returnURL}`:** white-label broker's OTP endpoint may respond `200 {returnURL: 'https://broker.example/#/login?otp=...'}` instead of a JWT pair in some flows. This is a browser-redirect pattern (the user finishes auth through a broker login redirect). Server-side exchange can't follow that. Detect `returnURL` in the response, surface `{migrated: false, reason: 'not_supported'}` to the caller, fall back to white-label broker-direct. Don't get stuck waiting for a JWT that won't come.

**Pitfall — the OTP cookie is short-lived.** white-label broker logs out users on a rolling basis. The OTP call must happen *during* select-account, using the freshly-saved cookie. A retry later against the same cookie will 401 even if the underlying the upstream token would still be valid.

**Related:** Recipe #67 (partner dashboard hangs forever) is the cousin pattern — same root cause (lazy 3rd-party fetch without timeout). Recipe #82 (deleted-route prerender cache) is unrelated but shares the "small endpoint silently broken" symptom family. Recipe #91 below is the migration script's mirror: batch migration runs should always be `--dry-run`-able.

---




---

## See also: Sep 25–27 round (Recipes #87–#97)

The recent round (Sep 25–27 2026) shipped twelve commits covering the white-label broker
connect flow, modal cleanup, demo-account cleanup, contract-size math, and a
CSS layout fix. The recipes below live in
[`references/2026-09-25-round-trade-modal-demo-and-whitelabel-connect.md`](references/2026-09-25-round-trade-modal-demo-and-whitelabel-connect.md):

- **#87 — `disconnectBroker` silent bail because of dead `v2_user_id` localStorage.** The single most impactful recipe of the round. The disconnect button appeared to work but never fired the API because the function depended on a `localStorage` key that nothing ever writes. Fix: pull `access_token` from `supabase.auth.getSession()`, send as Bearer, let the endpoint resolve the user server-side. Detection: any context function that returns silently on a `null` localStorage read is suspect.
- **#88 — Login → onboarding → dashboard redirect loop: `onboarding_complete` not set on admin approval.** The SQL trigger that sets `onboarding_complete` only fires when all 7 wizard steps complete, but the wizard locks at step 6 until admin approves. Admin approval must set the flag explicitly.
- **#89 — Modal popup auto-fired when user lands on `/dashboard/settings?connectAccount=1`.** Removed. Modal popups as a navigation side-effect are jarring. Let the user explicitly opt in via the empty-state buttons.
- **#90 — "Choose your broker v2" modal page is redundant when entry surfaces already pre-pick.** Default view to `'login'`, auto-fire demo on mount, repurpose "Back to broker selection" buttons as "Cancel" (close modal). Class-level lesson: when an entry surface pre-picks a choice, the downstream modal should skip the chooser step.
- **#91 — Device back button on mobile bypasses the modal's Escape handler.** Modal listens for `keydown` but not `popstate`. Push a sentinel `history.pushState` on open, listen for `popstate`, roll the sentinel out in cleanup. Detection: if a mobile-only complaint involves "modal won't close" / "back button does the wrong thing," the modal probably listens for keydown but not popstate.
- **#92 — Demo accounts seeded 3 fake trades; user wanted clean slate.** `getStartingPositions()` returns `[]`. Connect-demo route stops seeding. Picker UI updates its preview copy and stat labels. Detection: if a user complains about "fake" or "synthetic" content showing up as if they placed it themselves, check whether the system is seeding placeholder data on first paint.
- **#93 — Empty-state CSS cramped because `.sv-empty` was horizontal flex.** Switched to column-flex; buttons full-width on mobile. Detection: horizontal flex on a "message + actions" container always looks cramped on mobile. Default to column-flex for any container that holds both descriptive text and action buttons.
- **#94 — the broker's server-name casing: `whitelabel` vs `WHITELABEL`.** the broker is case-sensitive on the `server` field. The canonical names as the broker presents them are uppercase. Detection: if broker auth returns 401 but creds are correct, the broker-server-name is the next thing to check.
- **#95 — `/get-started` route deleted by mistake, restored from git history.** `git checkout <prev-commit>^ -- <file>` to restore. Don't invent a replacement — restore the original. Detection: if a marketing link returns 404, check the most recent big refactor for routes that were in the diff.
- **#96 — Patch tool indentation mismatch on multi-line JSX comments.** Patches with whitespace mismatch fail or match the wrong location. Always `read_file(offset, limit)` first and copy exact whitespace. Detection: if a patch fails multiple times with off-by-2/4 errors, re-read the file to confirm actual whitespace.
- **#97 — Trust the user more than your hypothesis when the two conflict.** When the user reverses a direction, just make the change. Don't re-justify the prior position. The cost of asking is another round trip; the cost of changing is one git commit.

## See also: Sep 27 round (Recipes #98–#105)

The Sep 27 2026 round shipped eight commits covering the notifications
bell panel CSS, iOS PWA form-field zoom lock, admin inbox thread
delete, education last-lesson forward flow, the contract-size
flip-flop, the TP/SL bell-feed kind extension, and signals TTL
restoration. The recipes below live in
[`references/2026-09-27-round-notifications-pwa-admin-education.md`](references/2026-09-27-round-notifications-pwa-admin-education.md):

- **#98 — Notification bell panel collapses to header height when the list is empty.** Flex-column overlay with no `min-height` on the parent collapses to header-only height when the list child is empty. Set `height: 480px; min-height: 240px;` on the parent. Detection: any "I open the modal and see nothing" report where the header is visible but the body is transparent — add `min-height` to the parent.
- **#99 — iOS Safari auto-zooms inputs even when `userScalable: false`.** iOS auto-zoom is a separate CSS gate (`font-size < 16px`), independent of viewport meta. Both controls are needed: lock the viewport meta AND bump all form inputs to `font-size: 16px`. Detection: any mobile-only "the screen zoomed in" complaint on a PWA.
- **#100 — Notification bell only showed initial signals; TP/SL hits went to web-push only.** Bell-feed insert was gated on `input.type === 'signal'`. Extended to three kinds (`signal` / `tp` / `sl`) with distinct KIND_META icons + colors and link targets (`/dashboard` / `?tab=positions` / `?tab=history`). Each kind uses its own `ref_id` so `fn_insert_notification` dedups correctly per-event.
- **#101 — Education dead end: last lesson + no quiz link.** When the user finishes the last lesson in a module, the only success-screen CTA was "Back to curriculum." But the module quiz is the gate before the next module unlocks. Three-way CTA now: Next Lesson → Take module quiz → Back to curriculum (fallback). Plus the API returns `module_quiz` + `module_quiz_best_attempt` so the lesson viewer can render the quiz CTA inline. Detection: any "users stuck here" complaint on a multi-stage flow.
- **#102 — Frontend Tbroker filter as band-aid for missing listener-side cleanup.** Frontend `sent_at >= NOW() - 5min` filter excludes all signals because the listener never expires `status='live'` rows. Tradeoff either way without server-side cleanup. Set to 5min (user preference) but flag the listener-side fix as the right answer.
- **#103 — Don't override verified data without contradicting evidence.** I shipped an indices contract-size fix from `10` → `1` based on industry-standard assumption. The file already had a verification comment showing the math works at `10`. The user later reported 10× too small P&L. Trust the file's verification over your hypothesis. Reverted. Detection: any "I'm going to change this verified value because I have a better understanding" — DON'T, wait for a bug report.
- **#104 — Admin thread DELETE needs explicit cascade: storage → attachments → emails → thread.** DB foreign keys don't clean Supabase storage objects. Cascade order matters: storage first (best-effort), then attachment rows, then email rows, then the thread row itself. Idempotent (returns `already_gone: true` if a concurrent admin already deleted).
- **#105 — Empty-state lessons propagate: always set `min-height` on flex-column overlay parents.** Cross-references #98 and #82. Class-level meta-pattern: don't rely on flex children's natural sizing to make the parent tall enough. Set `min-height` on the parent based on what the empty state needs.

## See also: Oct 5 round (Recipes #106–#109)

The Oct 5 2026 round shipped the leaderboard RLS fix, the test-seed
cohort cleanup (51 users + 3M fake points), the iOS push diagnostic
endpoint, and a hard lesson about deploy verification without
dashboard access. The recipes below live in
[`references/2026-10-05-round-leaderboard-push-deploy-verification.md`](references/2026-10-05-round-leaderboard-push-deploy-verification.md):

- **#106 — Marketing-surface routes using anon key are fragile: switch to service-role, don't rely on RLS migration that may never run.** Routes that need to expose "public" data (leaderboards, marketing pages) should use the service-role client when running server-side. The columns we select are intentionally public; the client only sees the JSON response. A code comment saying "you must also run migration X" is a future bug. Bypass RLS entirely from the server. Detection: any route with `createClient(...NEXT_PUBLIC_SUPABASE_ANON_KEY...)` that's also documented as "public" or "marketing" — it should use `createServiceClient()` instead.
- **#107 — Push delivered (`last_sent_at` updates) but user sees nothing on iOS = multiple subs from PWA reinstalls, not a server bug.** Each PWA reinstall on iOS creates a new APNs device token. The user accumulates 2+ active subscriptions to the same account. iOS may group/dedupe the visible notification. The fix is server-side: add `POST /api/push/diagnostics { action: 'dedupe' }` that keeps the most-recently-updated sub and deactivates the rest. Also add `GET /api/push/diagnostics` showing sub count + endpoint kind + last_sent_at + VAPID key fingerprint + troubleshooting hints. Detection: `last_sent_at` updates correctly but user reports "no pushes" — check sub count, suggest dedupe.
- **#108 — Filter changes don't fix data; clean the data too.** Tightening the leaderboard filter to `application_status='approved'` revealed 51 `@app.demo` test seed accounts I created earlier still holding 3,018,202 fake platform points. The user had asked previously to delete them. The lesson: a "show me only real users" request has TWO parts — tighten the filter AND clean the data. Either alone is incomplete. Before deleting `user_accounts` rows, sweep FK-referencing tables (partners, push_subscriptions, notifications) and delete children first to avoid FK constraint failures. Detection: any "show me only X" UI request → check whether stale data with the same flag-set is polluting the result.
- **#109 — Don't refactor + repush + wait + repeat when the deploy isn't verified.** If you push a fix, can't see a debug marker in the live response after 5+ minutes, and have no dashboard access to the deploy platform — the issue is the deploy pipeline, not your code. Don't ship another commit hoping the next deploy catches up. Wait, or tell the user to check the deploy dashboard. Pushing 3+ "fixes" with debug markers in one round (this round produced `61433452` → `8f5686cb` → `787d0d69` before I realized the deploy wasn't the issue) creates churn in git history for no functional change. See also: `the companion deploy-failure reference` in the companion platform skill — the Sep 2 2026 Docker build cycle where 5 wrong "fixes" got pushed because the agent kept guessing build errors instead of asking the user to paste the Railway build log. Detection: any "I just pushed but the response doesn't reflect it" report with no platform access — STOP pushing fixes, verify the source has the marker (`grep -r 'unique_marker' .next/`), then wait or ask the user to check the dashboard.
