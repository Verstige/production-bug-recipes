# Recipes #73, #74, #75 — Added Sep 14 2026

These are the three new recipes appended to the canonical
`this skill` library. The skills librarian will fold
them into SKILL.md at the next curator pass. Until then, this file
holds the body content so it's searchable.

## Recipe #73 — Switching to `@supabase/ssr`'s `createBrowserClient` silently breaks every client-side reader that pulled the access token from localStorage

**Symptom:** you rewrite `src/lib/supabase/browser.ts` to use `createBrowserClient` from `@supabase/ssr@0.8+`. Type checks pass, build is clean, deploy succeeds. Then the user reports a fleet of "Not authenticated" / 401 errors on routes they were hitting fine 10 minutes ago — the most common being:

- Daily streak card showing "unauthenticated"
- Trading balance tile not loading
- Partner Save throwing 401
- `/api/admin/*` returning 401 in the Customer 360 admin panel

The "fix" for several of these may already be deployed, yet they still fail. The basic auth check (`useUser()` showing a session) still works, so the user IS logged in — but server-side API routes don't know who they are.

**Root cause:**

`@supabase/ssr`'s `createBrowserClient` is **not** a drop-in replacement for `@supabase/supabase-js`'s `createClient`. The two libraries write to different storage:

| Library | Default storage | Format |
|---|---|---|
| `@supabase/supabase-js` `createClient` | localStorage | `{ "access_token": "eyJ..." }` at key `sb-<project>-auth-token` |
| `@supabase/ssr` `createBrowserClient` | document.cookie (chunked) | chunked `sb-<project>-auth-token.0`, `.1`, base64-url encoded with `base64-` prefix |

When you swap the library, **every existing caller that reads the access token from localStorage** breaks:

- `adminFetch()` helper functions
- Plain `fetch()` calls that pull `session.access_token` from `useSupabaseClient()` which now reads stale localStorage from before the rewrite
- Any code that does `getSupabaseBrowserClient().auth.getSession()` and then forwards the access token to a server route

The severity is masked by the fact that the new browser client STILL writes a one-time legacy session to localStorage during migration, so `getSession()` returns a "valid-looking" session whose access token isn't what the server expects.

**The diagnostic — three callsites to check at once:**

1. `grep -rn "localStorage.getItem" src/lib/admin-fetch.ts src/lib/os-points/client.ts src/app/api/` — find every place that reads the token.
2. Open DevTools → Console → run `document.cookie` — confirm chunked `sb-...-auth-token.0` cookies exist.
3. Run `localStorage.getItem('sb-<project-ref>-auth-token')` — if it returns a token, that's the *old* (pre-rewrite) session; the new session is in cookies only.

**The fix — three pieces:**

1. **Read cookies first, then localStorage as fallback.** In `adminFetch()` and any other token-reader helper:

```ts
const candidates = [
    'sb-<project>-auth-token',         // legacy single-key (old client)
    'sb-<project>-auth-token.0',       // new cookie chunks
    'sb-<project>-auth-token.1',       // ...
    'sb-<project>-auth-token-code',    // PKCE flow split
    'app-auth-token',             // historical backup
]
// Try document.cookie FIRST (new client lives there), then localStorage
```

Decode both formats:
- URL-encoded JSON (`encodeURIComponent(JSON.stringify(session))`)
- base64-url prefixed (`base64-eyJ...` — strip prefix, replace `-`/`_` with `+`/`/`, then `atob()`)

2. **If the migration is small enough, DO NOT switch libraries.** A `createClient` from `@supabase/supabase-js` with a custom storage shim that ALSO writes to `document.cookie` as URL-encoded JSON works fine for both sides. The whole @supabase/ssr rewrite isn't necessary if you only need cookies to be visible to the server.

3. **If you must switch libraries, add runtime logging to verify** the new storage path. Add `console.debug('[<helper>] token source = cookie|localStorage|none ...')` and check the user's DevTools console.

**The verification gate:**

- Hard-refresh, open `/dashboard/(main)/trading`, watch the network tab for `/api/app/streak`, `/api/whitelabel/account-data`, `/api/admin/...`. All should be 200.
- Run the helpers' debug log. `token source = cookie` (new) or `localStorage` (legacy) — neither is `none`.

**The revert path — keep `createClient` from `@supabase/supabase-js` with a working cookie shim:**

```ts
// src/lib/supabase/browser.ts (working pre-rewrite)
const client = createClient(supabaseUrl, supabaseAnonKey, {
  auth: {
    persistSession: true,
    storage: {
      setItem(key, value) {
        if (typeof document === 'undefined') return
        localStorage.setItem(key, value)
        if (key.startsWith('sb-') && key.endsWith('-auth-token')) {
          try {
            const encoded = encodeURIComponent(value)
            document.cookie = `${key}=${encoded}; path=/; SameSite=Lax; Secure`
          } catch {}
        }
      },
      // ...getItem / removeItem mirror
    },
  },
})
```

This is what was working before `bf31207e`. If you ever consider the rewrite again, do an isolated `git revert bf31207e` first, then enumerate **every** caller that does `localStorage.getItem` against an sb-prefixed key, then make sure they all have the dual-read fallback in place. THEN consider the rewrite.

**Lesson — the auth subsystem is wider than the consumer.** A "small" refactor of `getSupabaseBrowserClient` affects:
- `useUser()` reads
- `useTrading()` reads
- `useSession()` reads
- Manual `fetch()` calls forwarding `session.access_token` to API routes
- `adminFetch()` helper functions
- 3rd-party clients that don't import our helpers but still read `sb-...-auth-token` directly

Five back-to-back commits (`bf31207e`, `f19b7ace`, `c9588832`, `cc74ac8d`, `2f85f4c9`) were required to recover. The lesson: a one-commit swap of the browser auth client without a planned rollout is a multi-day tail risk.

**Related:** Recipe #47 (defensive render when field is null). Same pattern: trust the type, not the storage.

---

## Recipe #74 — Multiple unguarded `value.toUpperCase()` callsites in the same render path require a wide audit, NOT per-file guess-and-patch

**Symptom:** user reports `undefined is not an object (evaluating 'e.toUpperCase')` on a dashboard page. You patch the first `e.toUpperCase()` you find. The user reports the same error after deploy. You patch the next. Same error. You add a "Copy stack" button to the error boundary. User reports same error. You eventually find the actual callsite after 3-4 commits.

**Root cause:** in any data-driven render path (e.g. a signal card list fed by `signal_log`), multiple JSX branches independently call `.toUpperCase()` on different fields of the same row:

```tsx
// SignalCard render — all four of these crash independently if data is null:
{signal.pair.toUpperCase()}              // line A
{signal.direction.toUpperCase()}         // line B  
{signal.status.toUpperCase()}            // line C
{signal.engine_name.toUpperCase()}       // line D
```

A single missing guard means the whole render throws. Patching line A does not fix lines B-D.

**The diagnostic — survey ALL `.X.toUpperCase()` calls in the broken render path BEFORE you patch any of them:**

```bash
# Find every unguarded .toUpperCase() in the file/module:
grep -nE "[a-zA-Z_]+\.[a-zA-Z_]+\.toUpperCase\(\)" src/components/.../SignalCard.tsx
# Then audit each one: can the receiver be null at runtime given the data shape?
```

Read the data type at the consumer (`type SignalRow = { pair: string, direction: 'BUY'|'SELL', status: string, ... }`), then read what the API actually returns. **For Supabase / PostgREST tables that are fed by a third-party listener (e.g. Telegram),** the data shape is whatever the listener wrote, NOT what the schema migration said.

**The fix — two patterns (use BOTH):**

1. **Single source of truth at the top of the component:**

```tsx
function SignalCard({ signal }) {
  // Sep 14, 2026 — null-safe accessors. signal_log rows
  // occasionally have null fields (status/pair/engine).
  const safePair       = signal.pair        ?? ''
  const safeDirection  = signal.direction   ?? 'BUY'
  const safeEngineName = signal.engine_name ?? signal.engine_id ?? 'Engine'
  const decimals       = priceDecimalsFor(safePair)
  // JSX then uses safePair, safeDirection, safeEngineName throughout
}
```

2. **Defense-in-depth inside the helper:**

```ts
function priceDecimalsFor(pair: string): number {
  const p = (pair ?? '').toUpperCase()    // defensive at the helper level
  // ...
}
```

This is belt-and-suspenders. Either pattern alone would prevent the crash; together, they survive any future field additions the listener makes.

**The verification gate:**

- Spot-check 5-10 legacy rows from `signal_log` in Supabase Studio for null fields: `SELECT pair, status, direction, engine_name FROM signal_log WHERE pair IS NULL OR status IS NULL LIMIT 10`
- Hard-refresh the page that crashed
- Render once, then once with `localStorage.clear()` (forces a fresh fetch)
- If the page renders without the error boundary firing, the patch is good

**The SQL escape hatch (rare — used only when all patches still fail):**

If you cannot find the offending callsite in reasonable time, normalize the bad data at the source:

```sql
UPDATE signal_log SET pair = 'UNKNOWN' WHERE pair IS NULL OR pair = '';
UPDATE signal_log SET status = 'live' WHERE status IS NULL OR status = '';
UPDATE signal_log SET direction = 'BUY' WHERE direction IS NULL OR direction = '';
```

This works in emergencies but is NOT a substitute for defensive code — new rows from the listener may reintroduce the same null fields.

**Lesson — when you patch an error and the user reports it persists, the patch was wrong OR incomplete. Stop patching defensively and instrument the runtime instead.** Add the "Copy stack" button to your error boundary BEFORE the third retry, so future sessions can read the actual `sh`/`su`/`oY` minified callsite directly off the stack trace.

**Related:** Recipe #47 (defensive render when single row is malformed). Recipe #47 covers an `Array.isArray(x)` style guard on a row; #74 covers entire paths where MULTIPLE fields can be null.

---

## Recipe #75 — Supabase views referencing `pu.X` when `X` is on a different joined alias produce unhelpful errors that don't point at the actual join problem

**Symptom:** pasting a migration like this into Supabase Studio:

```sql
CREATE OR REPLACE VIEW public.v_qualified_partners AS
SELECT p.id, pu.id, pu.first_name, pu.last_name, ..., pu.is_master_partner, pu.is_partner
FROM public.partners p
LEFT JOIN public.user_accounts pu ON pu.id = p.user_id
WHERE pu.is_master_partner = true OR pu.is_partner = true;
```

Studio returns `ERROR: 42703: column "pu.is_partner" does not exist LINE 8: pu.is_partner` with the helpful hint `Perhaps you meant to reference the column "p.is_partner"`.

The mistake is reasonable: when most user_accounts columns live on `pu`, you assume all "user-shaped" columns live there. **But `is_partner` is on `partners`, not on `user_accounts`** — the relation between the two tables and which columns live where is asymmetric.

**Root cause:** aliases in SQL JOINs don't propagate the column schema. `pu` is just a name for `user_accounts`; columns that the migration logic suggests should be on `pu` may actually live on `p`. The error message WOULD name the wrong-alias column literally — but only if you're paying close attention to `pu.X` vs `p.X` in the error.

**The diagnostic — when a `42703` error doesn't appear to match the schema:**

1. **Read the alias.** Is the error naming `pu.X` or `p.X` or a non-aliased column?
2. **Run a column probe in psql or Table Editor:**
   ```sql
   SELECT column_name FROM information_schema.columns
   WHERE table_schema = 'public' AND table_name = 'partners'
   ORDER BY column_name;
   ```
3. **Cross-reference which columns are where** before guessing.

**The fix — three patterns:**

1. **Use the right alias in the SELECT and WHERE:**

```sql
SELECT ..., pu.is_master_partner, p.is_partner   -- both pulled from their actual tables
FROM public.partners p
LEFT JOIN public.user_accounts pu ON pu.id = p.user_id
WHERE pu.is_master_partner = true OR p.is_partner = true;
```

2. **For column-existence checks at migration time,** before adding a view reference, dump the columns:

```bash
psql -h db.<project>.supabase.co -U postgres -d postgres -c "\d public.partners" 2>&1 | head -30
psql -h db.<project>.supabase.co -U postgres -d postgres -c "\d public.user_accounts" 2>&1 | head -30
```

3. **For migrations being added to `supabase/migrations/*.sql`, write them once correctly.** Don't ship a migration that assumes column locations — every subsequent maintainer who runs it fresh will hit the same `42703`.

**The asymmetric-columns trap (specific to the platform):**

| Column | Table |
|---|---|
| `is_admin` | `user_accounts` |
| `is_trader` | `user_accounts` |
| `is_master_partner` | `user_accounts` |
| `is_partner` | `partners` (NOT on `user_accounts`) |
| `referral_code` | `partners` |
| `whitelabel_referral_url` | `partners` |
| `first_name`, `last_name` | `user_accounts` (added Sep 14, 2026) |

When writing a view that joins both tables, the asymmetric columns to verify per-call are:
- `is_master_partner` lives on `user_accounts`
- `is_partner` lives on `partners`

If you only ever join these tables, ALWAYS assume a column could be on the other side until verified.

**Lesson — before adding a CREATE OR REPLACE VIEW to a migration, run a `\d` dump of every FROM table and check column ownership against every line of the SELECT.** Saves 30-60 minutes when the migration is applied and breaks a downstream view query.

**Related:** Recipe #56 (`signal_log.engine_id` schema mismatch). Same family — column-name/source mismatch producing silent or loud error. Recipe #69 (run migration statements one at a time in Studio) is the operational companion.
