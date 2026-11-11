# Aug 26 2026 — Admin inbox access + iOS PWA render exception

Recipes #45–#48 below, all surfaced on Aug 26 2026 during the admin inbox incident. The underlying cause was a silent 403 on `/api/admin/email/*` because `user_accounts.inbox_access` was false on the active admin account. The user-visible symptom was "I can't see any sent or received mail" inside the admin Inbox.

---

## Recipe #45 — Auth-gated column on `user_accounts` silently fails as 403 (added Aug 26 2026)

**Symptom:** an admin user reports that a feature in the admin panel is broken (empty list, blank screen, "no data"). The API endpoint returns `403 Forbidden`. The page renders an empty state (e.g. "No messages yet", "Loading failed", or a blank list) with NO error toast, NO banner, NO console error in the user's view.

**Root cause:** admin routes gate on auth-gated columns like `user_accounts.inbox_access` or `is_admin`. The gate lives at the API layer (`if (!auth.profile?.X) return 403`). The UI side often only checks `res.ok` and silently fails when the API returns 403 — there's no error toast, no banner, no log visible to the user. The user sees "No messages yet" or a blank screen and assumes the system is empty.

**The diagnostic trap:** in normal cases where the system has no data, the API returns 200 with an empty array and the UI shows the empty state. In the broken case, the API returns 403 and the UI **also** shows the empty state. The two are visually indistinguishable to the user. The only way to tell them apart is to look at the network tab or the server logs.

**The fix pattern — three pieces:**

1. **Add a UI fallback for 403**: in `loadThreads` (or equivalent), check `res.status` and dispatch a visible error: `setError('Your account does not have access to this view. Contact an admin.')`. Never let a 403 look like an empty list.
2. **Always seed the gate explicitly for admins**: in `user_accounts`, set `inbox_access = true` (or whatever flag the route checks) on every `is_admin = true` user. If a new flag gets added to the schema, run a backfill migration:
   ```sql
   UPDATE public.user_accounts
   SET inbox_access = true
   WHERE is_admin = true AND (inbox_access IS NULL OR inbox_access = false);
   ```
   Otherwise you get drift where admin A has access (set explicitly) and admin B doesn't (default false).
3. **Default the flag to `true` on schema create** — or at least add a NOT NULL default that makes sense. `inbox_access BOOLEAN DEFAULT false` is OK if all admin paths set it explicitly; prefer `inbox_access BOOLEAN DEFAULT true` for admin-shaped columns so new admins get it for free and only non-admins need explicit denial.

**The diagnostic flow when this happens:**

```sql
-- 1. Find the user's auth id from their email
SELECT id, email FROM auth.users WHERE email = '<user email>';

-- 2. Check the user_accounts row for the flag
SELECT id, email, is_admin, inbox_access FROM public.user_accounts WHERE id = '<auth id>';

-- 3. If inbox_access = false and is_admin = true, that's the bug
UPDATE public.user_accounts SET inbox_access = true WHERE id = '<auth id>';

-- 4. Verify
SELECT email, is_admin, inbox_access FROM public.user_accounts WHERE id = '<auth id>';
```

```bash
# From the browser, confirm what the API actually returns:
curl -sL -H "Authorization: Bearer <token>" https://www.yourdomain.com/api/admin/email/threads
# Expected on success: { "threads": [...] }
# Expected on the bug:  { "error": "Inbox access not granted" }
```

---

## Recipe #46 — iOS PWA service worker caches JSON API responses (added Aug 26 2026)

**Symptom:** the user opens the admin Inbox on their phone (or a PWA-installed desktop), sees "17 unread" in the header count, but the thread list is empty. The same URL from a fresh curl returns `200 OK` with 25 threads. The user thinks the feature is broken; the developer thinks the data layer is broken.

**Root cause:** iOS PWAs cache aggressively via the service worker (`public/sw.js`). When the API returns data, the SW intercepts the response and stores it in `runtime-${CACHE_VERSION}`. Subsequent navigations within the same session, and even subsequent visits across days, hit the cached response. When you ship new server-side code (e.g. changing the query, filtering banned users, adding new endpoints), the PWA continues serving the OLD response from cache — and the OLD response may not have the data the user expects (in our case, the count was correct because it was a derived computation, but the list was filtered to zero because the cached response was from before a fix).

The classic case: you deploy a fix, the server log shows the fix is being served, but the user still sees the old behavior. You spend an hour debugging "why isn't my fix taking effect?" only to realize the SW has been serving a cached response for 4 hours.

**The fix — three layers, all three are needed:**

1. **Add `Cache-Control: no-store, no-cache, must-revalidate`** to the API response, even for GETs:

   ```ts
   return NextResponse.json(
       { threads: data ?? [], total: count ?? 0 },
       {
           headers: {
               'Cache-Control': 'no-store, no-cache, must-revalidate',
               'Pragma': 'no-cache',
               'Expires': '0',
           },
       },
   );
   ```

   This prevents the BROWSER from caching the response. The SW can still cache it (it runs at a lower level than browser HTTP cache), but at least normal browser navigation won't.

2. **Bump `CACHE_VERSION` in `public/sw.js`** so the SW itself evicts the old runtime cache:

   ```js
   const CACHE_VERSION = 'app-v56'; // bumped from v55
   ```

   Bumping the version causes the `activate` handler to delete `runtime-app-v55` and `static-app-v55`, forcing a fresh fetch.

3. **Tell the user to hard-refresh the PWA.** On iOS PWA: swipe the app away from the app switcher, then re-open. On Chrome PWA: hard refresh (Cmd+Shift+R). The bundled SW update mechanism (`skipWaiting()` + `clients.claim()`) helps once the new SW is fetched, but until the user opens the app once after the deploy, they still have the old SW installed.

**The diagnostic when this happens:**

```bash
# Check what the SW currently serves:
curl -sL https://www.yourdomain.com/sw.js | grep CACHE_VERSION

# Compare against the deployed version:
# - If you bumped the version in code but the live SW is still old,
#   the deploy didn't include sw.js (it lives at /public/sw.js, not
#   under /_next/static/, so it ships independently — verify it made
#   it into the build artifact).
# - If the live SW version IS new but the user still sees old data,
#   the user's PWA is still running the old SW — they need to hard-refresh.

# Check the API directly (bypasses the SW):
curl -sL https://www.yourdomain.com/api/admin/email/threads -H "Authorization: Bearer <token>"
```

---

## Recipe #47 — React `.map()` silent crash when a single row has malformed data (added Aug 26 2026)

**Symptom:** an admin list page shows the right count (e.g. "17 unread") but renders zero rows. The API returns valid data. The page has no error toast, no console error in the user's view. The UI is just empty.

**Root cause:** `threads.map(t => <button>{addressName(t.participant_addrs.find(...))}`) — if a single row has `participant_addrs: null`, an unexpected shape, or a field that crashes `addressName()`, the entire `.map()` callback throws. React's reconciliation handles sibling rendering per-item, but when an item throws during render, **the whole sibling list** is silently skipped. The user sees an empty list with no error indicator.

In one case we hit: `participant_addrs.find(a => a !== 'info@yourdomain.com' && !a.includes('yourdomain.com'))` returned `undefined`, then `?? t.participant_addrs[0]` evaluated to `undefined` because `participant_addrs[0]` was `undefined` (the array was `null` in the DB row), then `?? 'Unknown'` worked. So that specific path didn't crash. The crash was elsewhere — but the PATTERN is real and future-proofing is worth doing.

**The fix — defensive render with explicit defaults:**

```tsx
threads.map(t => {
    // Guard every field before render.
    const addrs = Array.isArray(t.participant_addrs) ? t.participant_addrs : []
    const external = addrs.find(
        (a: string) => typeof a === 'string'
            && a !== 'info@yourdomain.com'
            && !a.includes('yourdomain.com')
    ) ?? addrs[0] ?? 'Unknown'
    const preview = typeof t.last_message_preview === 'string'
        ? t.last_message_preview
        : ''
    const subject = typeof t.subject === 'string' && t.subject
        ? t.subject
        : '(no subject)'
    return (
        <button key={t.id} ...>
            ...
            <span>{addressName(external)}</span>
            <span>{subject}</span>
            <div>{preview}</div>
        </button>
    )
})
```

Three rules:
- `Array.isArray(x)` before calling `.find()` or `[0]`
- `typeof x === 'string'` before calling string methods
- Coerce `null`/`undefined` to safe defaults at the top of the `.map()` callback

This is belt-and-suspenders. The cost is one or two extra lines per render and the benefit is that **one bad row never takes down the entire list**.

---

## Recipe #48 — Supabase soft-delete via `banned_until` when hard-delete is blocked (added Aug 26 2026)

**Symptom:** you need to delete a user from `auth.users` to clean up an admin panel listing or remove a typo account. `DELETE /auth/v1/admin/users/{id}` returns `500 Internal Server Error`. The user stays in the database.

**Root cause:** Supabase's admin API has historically had inconsistent support for hard-delete depending on the user's setup (foreign keys from `public.user_accounts` to `auth.users.id`, MFA factors, SSO providers, etc.). Hard-delete fails silently with a 500. The user remains in `auth.users` even after the request "succeeds" (the migration ledger marks it applied but the row stays).

**The fix — soft-delete via `banned_until`:**

```bash
# 1. Try hard-delete (it might work):
curl -X DELETE -H "apikey: $KEY" -H "Authorization: Bearer $KEY" \
  https://<project>.supabase.co/auth/v1/admin/users/<user_id>
# If 500: use the soft-delete fallback.

# 2. Soft-delete via banned_until (100-year ban):
curl -X PUT -H "apikey: $KEY" -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  -d '{"ban_duration": "876000h"}' \
  https://<project>.supabase.co/auth/v1/admin/users/<user_id>
# 876000 hours = 100 years. Effectively permanent.

# 3. Clean up dependent rows in user_accounts:
curl -X DELETE -H "apikey: $KEY" -H "Authorization: Bearer $KEY" \
  -H "Prefer: return=representation" \
  "https://<project>.supabase.co/rest/v1/user_accounts?id=eq.<user_id>"

# 4. Verify the user can no longer log in:
curl -X POST -H "apikey: $KEY" -H "Content-Type: application/json" \
  -d '{"email": "<email>", "password": "<password>"}' \
  https://<project>.supabase.co/auth/v1/token?grant_type=password
# Expected: 403 or 400, NOT 200 with a session.
```

**Important caveat:** banned users STILL appear in `GET /auth/v1/admin/users` (they show with `banned_until: <future date>`). To filter them out of admin listings, filter at the API layer:

```ts
const liveUsers = rawUsers.filter((u: any) => {
    const until = u?.banned_until;
    if (!until) return true;
    const t = Date.parse(until);
    return !(Number.isFinite(t) && t > Date.now());
});
```

Without this filter, banned accounts clutter the admin customers panel forever.

---

## General pattern: when an admin feature reports "empty" — assume it's auth, not data

Across this session, three separate admin bugs presented as "the page is empty":
- the maintainer's inbox access flag was false (Recipe #45)
- I shipped a fix that was cached by the iOS PWA (Recipe #46)
- React `.map()` crashed silently on a row with malformed data (Recipe #47)

When an admin page shows an empty state but the count badge is correct, the **data is fine** — it's either auth (gate returning 403 silently), caching (SW serving old response), or render exceptions (one bad row kills the list). All three patterns are now in this skill. Always check all three.

Verification flow when an admin user reports "X feature is empty":

1. **Hit the API directly** with their bearer token (`curl`). If 403 → auth flag (Recipe #45). If 200 with data → cache or render (Recipes #46, #47).
2. **Check the user's PWA SW version** vs. the live version. Stale SW → Recipe #46.
3. **Look for runtime render errors** in their browser DevTools. React silent crash → Recipe #47.
