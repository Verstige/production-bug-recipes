# Aug 23 2026 — Onboarding lifecycle: SQL migration push recovery + wizard/auth gate recipe (drop-in for SKILL.md merge)

This file is a curated delta for the autonomous SKILL.md curator.
Drop-in content for `this skill's SKILL.md`.

## Recipe #21 — Multi-version recovery dance when a SECURITY DEFINER function partial-applies (added Aug 23 2026)

**Symptom:** you push a migration via `supabase db push --dns-resolver https` that contains a `CREATE OR REPLACE FUNCTION public.os_X(p_user_id uuid) ... LANGUAGE plpgsql SECURITY DEFINER`. The CLI reports "migration applied". But when you hit the new RPC for the first time, it 400s with `column "X" does not exist` or `column "Y" does not exist`. The function exists but references columns that don't exist in production (because they were renamed in a later migration that this round didn't apply).

You can't `db push` the same version twice (PK conflict on `schema_migrations.version`). You can't `DROP FUNCTION` and re-CREATE in place because that loses the migration ledger consistency.

**Root cause:** column-name drift between the migration as-written and production. In the Round-2 onboarding lifecycle push, the function body referenced:
- `user_accounts.last_seen_at` — production column is `last_active_at` (renamed in an earlier migration)
- `auth.users.user_metadata` — production column is `raw_user_meta_data` (PostgREST aliasing hides this; SECURITY DEFINER functions have to use the real column name)

Both errors fire when the new RPC runs and trys to read those columns. The CLI doesn't catch these at push time (it can't introspect a SECURITY DEFINER function against the live schema without executing it).

**The fix — three-version recovery dance:**

```bash
# Round 1: the original migration. Marked applied, but partial-applied.
# File: supabase/migrations/202608250001_lifecycle_steps.sql
# It contains the broken function (with last_seen_at, user_metadata refs).
supabase db push --include-all --dns-resolver https

# Verify in the live DB
curl -X POST 'https://<project>.supabase.co/rest/v1/rpc/app_get_user_lifecycle' \
  -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" \
  -d '{"p_user_id":"<test-uuid>"}'
# Expected: HTTP 400 with "column last_seen_at does not exist" (not 200)
# If 200, the bug didn't happen — don't proceed.

# Round 2: tell the CLI to forget about the partial-applied migration,
# then move the file to a fresh version stamp.
supabase migration repair --status reverted 202608250001

mv supabase/migrations/202608250001_lifecycle_steps.sql \
   supabase/migrations/202608250002_lifecycle_steps_fixup.sql

# Edit the SQL — replace column references with the production names:
#   last_seen_at       → last_active_at
#   user_metadata      → raw_user_meta_data

# Round 3: push the fixup as a brand-new migration that
# CREATE OR REPLACE FUNCTION the corrected version.
supabase db push --include-all --dns-resolver https --dry-run
supabase db push --include-all --dns-resolver https
```

**The reusable idea:** when a SECURITY DEFINER function partial-applies due to a column-name mismatch, **don't try to repair the same version**. **Use `migration repair --status reverted` to release the version stamp, then ship a NEW migration with a fresh version** that does the same `CREATE OR REPLACE FUNCTION` with corrected column references. The migration ledger stays consistent, the function gets the corrected body, and the column-error 400 from the RPC call goes away.

**Why not just edit the existing migration file in place?** Because the CLI sees the file's content hash, and once a version is in `schema_migrations.version`, the CLI won't re-apply it. You'd also confuse any future audit (git blame on the migration doesn't match the ledger).

**The pre-flight check (before calling the RPC the first time):**

```sql
-- Does the new RPC exist?
SELECT proname FROM pg_proc WHERE proname = 'app_get_user_lifecycle';

-- Does the function body reference columns it shouldn't?
SELECT prosrc
FROM pg_proc WHERE proname = 'app_get_user_lifecycle'
  AND prosrc ~ '(last_seen_at|user_metadata)';
-- If this returns rows, the function is referencing drifted column names.
-- Don't bother testing the RPC — fix the function body first.

-- Are the columns it references actually there?
SELECT column_name FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'user_accounts'
ORDER BY ordinal_position;
-- Confirm whether it should be last_seen_at or last_active_at.
```

**The broader diagnostic for "migration applied but a NEW function in it doesn't work":**

1. **CLI reports applied** — but only the parts of the file that succeeded ran. SECURITY DEFINER functions don't crash the migration if they reference missing columns at parse time, only at call time. The ledger gets the row, the function exists but is broken.
2. **`pg_proc.prosrc` IS the source of truth.** If a brand-new function returns 400 with `column X does not exist`, `prosrc` will contain the bad reference. The fix is always: `CREATE OR REPLACE FUNCTION` with corrected references in a fresh migration.
3. **The migration tool's `repair --status` lets you flip the ledger without re-running SQL.** Use it when you need to mark a partially-applied migration as "not done, redo it." This is the only escape hatch when the version is locked but the SQL needs to change.

**When this hits again:** any brand-new SECURITY DEFINER function whose body references columns that may have been renamed by intervening migrations. The defensive recipe:

```sql
-- BEFORE writing the function body, verify ALL columns it touches:
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = '<target_schema>'
  AND table_name = '<target_table>'
ORDER BY ordinal_position;

-- Common drift points in the platform:
--   auth.users:    raw_user_meta_data (NOT user_metadata)
--   user_accounts:  last_active_at   (NOT last_seen_at)
--   position_snapshot: no `id` column (composite PK on user_id, broker_position_id)
--   brokers/broker_links: depends on which migration ran
-- Always verify before writing.
```

A 5-second `information_schema.columns` lookup beats a 30-minute "why does the RPC 400" debug. Always do it as part of the migration draft, not after.

**Pair with:** `supabase-policies-migrations` skill (idempotency / naming rules), and the existing Recipe #20 in SKILL.md (the `--dns-resolver https` push from a sandbox).

## Recipe #22 — Hard-redirect auth gate via Next.js middleware cookie decode (added Aug 23 2026)

**Class of work:** the canonical way to gate `/dashboard/*` for users who haven't completed onboarding, sitting at the edge before the page even renders.

**The pattern** (used in `src/middleware.ts` for the Round-2 onboarding gate):

```typescript
export default async function middleware(request: NextRequest) {
  const { pathname } = request.nextUrl;

  // ── 1. Decide which paths are gated ─────────────────────
  const GATED_PREFIXES = ['/dashboard', '/trading-dashboard'];
  const ONBOARDING_ALLOW = ['/onboarding', '/onboarding/accent',
                              '/onboarding/risk', '/onboarding/tour'];
  const AUTH_ALLOW = ['/auth', '/login', '/signup', '/signin',
                      '/forgot-password', '/reset-password'];

  const underGate = GATED_PREFIXES.some((p) => pathname.startsWith(p));
  const allowed = AUTH_ALLOW.some((p) => pathname.startsWith(p))
    || ONBOARDING_ALLOW.some(
         (p) => pathname === p || pathname.startsWith(p + '/')
       );

  if (underGate && !allowed) {
    // ── 2. Pull the user id from the supabase auth cookie ──
    const all = request.cookies.getAll();
    const sbCookie = all.find((c) => c.name.includes('auth-token'));
    let userId: string | null = null;
    if (sbCookie) {
      try {
        // Supabase stores the session as `<base64(json)>` containing
        // { access_token, refresh_token, user, ... } (some clients
        // also wrap it as `[{ access_token, ... }, ...]` — array of segments).
        const decoded = JSON.parse(
          Buffer.from(
            (sbCookie.value.split('.')[0] || '').replace(/-/g, '+').replace(/_/g, '/'),
            'base64',
          ).toString('utf8'),
        );
        const accessToken: string | undefined = decoded?.access_token
          || decoded?.[0]?.access_token;
        if (accessToken) {
          // Decode the JWT payload (sub = user id).
          const payloadJson = Buffer.from(
            accessToken.split('.')[1].replace(/-/g, '+').replace(/_/g, '/'),
            'base64',
          ).toString('utf8');
          const payload = JSON.parse(payloadJson);
          userId = payload?.sub || null;
        }
      } catch { userId = null; }
    }

    // ── 3. Check onboarding_complete ────────────────────────
    const done = await isOnboardingComplete(request, userId);
    if (!done) {
      const url = request.nextUrl.clone();
      url.pathname = '/onboarding';
      url.search = '';
      return NextResponse.redirect(url, 302);
    }
  }

  // ── 4. Existing UA-block / rate-limit logic runs UNCHANGED ──
  // ...
}
```

**The key — supabase stores the auth cookie TWO possible ways:**

- **Newer supabase-js** (v2.x): `sb-<project-ref>-auth-token` cookie contains a single base64-encoded JSON `{ access_token, refresh_token, user, ... }`.
- **Some custom flows** wrap the session as `[{ access_token, ... }, ...]` (array of segments). The cookie name might also be `app-auth-token` instead of `sb-<project-ref>-auth-token`.

The decode handles BOTH shapes by checking `decoded.access_token || decoded?.[0]?.access_token`.

**Compromise the cookies if the platform uses Cookie Auth:** the Supabase SSR Auth Helpers set `sb-<project-ref>-auth-token` directly. If you call `supabase.auth.signInWithPassword()` from a client page, the cookie is set automatically. The middleware sees it on the very next request.

**The service_role lookup — pattern:**

```typescript
async function isOnboardingComplete(req: NextRequest, userId: string | null): Promise<boolean> {
  if (!userId) return false;     // not logged in → /login (handled elsewhere)

  const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!supabaseUrl || !serviceKey) return true;  // fallback: don't bounce

  try {
    const res = await fetch(
      `${supabaseUrl}/rest/v1/user_accounts?id=eq.${userId}&select=onboarding_complete`,
      {
        headers: {
          apikey: serviceKey,
          Authorization: `Bearer ${serviceKey}`,
        },
        cache: 'no-store',  // never cache; onboarding_complete can change at runtime
      },
    );
    if (!res.ok) return true;  // fallback: don't bounce on transient DB error
    const rows = await res.json();
    return Array.isArray(rows) && rows[0]?.onboarding_complete === true;
  } catch {
    return true;  // belt-and-braces: don't bounce during a network blip
  }
}
```

**The defensive return-on-failure pattern:** if the lookup fails for ANY reason (missing env, network error, non-OK response), **return `true` (allow through)**, not `false` (bounce). If the DB has a transient issue, the cost of bouncing a legitimate user to `/onboarding` is higher than the cost of letting them through. The user-facing fix (if it's a real problem) is the wizard complaining on the next page load — which the client-side `useOnboardingGate` hook also handles.

**The client-side companion hook — defense in depth:**

```tsx
// src/components/onboarding/useOnboardingGate.ts
export function useOnboardingGate(): { onboardingComplete: boolean; loading: boolean } {
  const router = useRouter()
  const { profile, loading } = useUser()
  const onboardingComplete = profile?.onboardingComplete === true

  useEffect(() => {
    if (loading || !profile) return
    if (onboardingComplete) return
    if (typeof window === 'undefined') return
    const p = window.location.pathname
    if (p === '/onboarding' || p.startsWith('/onboarding/') || p === '/') return
    router.replace('/onboarding')
  }, [loading, profile, onboardingComplete, router])

  return { onboardingComplete, loading }
}
```

Mount this in `src/app/dashboard/layout.tsx` so EVERY dashboard page gets the gate. Middleware covers hard-loads and bots; client hook covers in-app SPA navigation.

**Suspense boundary required when using `useSearchParams()`:**

```tsx
// Next.js 16 — useSearchParams() requires a Suspense boundary at the page
// that uses it, or static prerender fails with "useSearchParams() should be
// wrapped in a suspense boundary". Wrap the body in a small Suspense + skeleton.

export default function OnboardingWizardWithSuspense() {
  return (
    <Suspense fallback={<OnboardingSkeleton />}>
      <OnboardingWizard />
    </Suspense>
  )
}

// Aug 22 2026 — also force dynamic rendering so next build doesn't
// try to static-prerender the page.
export const dynamic = 'force-dynamic'
```

`useSearchParams()` returns null during SSR pre-render. Without `<Suspense>`, Next.js 16's build step fails. The `dynamic = 'force-dynamic'` is belt-and-braces; you can also just keep `<Suspense>` and Next will use SSR. Pick whichever your build pipeline is happier with.

**When this hits again:** any new feature that needs to gate a route based on a DB-derived flag (onboarding_complete, hasKYCVerified, isEducator, etc.) and the gate fires for /dashboard/* sub-routes. Use the cookie-JWT-decode → user_accounts-service_role-REST-lookup pattern, fall back to allow-on-failure, and mount the client hook in the layout for SPA navigation coverage.

**Pair with:** Recipe #12 (UserContext loading race) — the gate only works if `profile.onboardingComplete` is set BEFORE the page renders. If `loading=false` flips before the DB query completes, the page renders `onboardingComplete=false` and the client hook bypasses the gate. Same fix: flip `loading=false` AFTER all DB-derived flags resolve, not before.

## What I deliberately did NOT do in this session (out of scope, future work)

- **Partner portal "Lifecycle" column + side-drawer** — the `app_get_user_lifecycle` RPC exposes everything needed (`partner_status.{pill, color}`, per-step `completed_count`/`required_count`, per-step state). Wiring it into `src/components/partners/PartnerPortal.tsx` (`src/app/api/partners/dashboard` already returns the downline rows; need a JOIN to `app_get_user_lifecycle` per downline row + a new "Lifecycle" column in the table) is the next ticket but is a UI-feature class, not a bug/recipe.
- **`trader_profiles` / `telegram_trader_signals` migration to add `trader_id` to the public view** — already noted in the conversation summary for Round-1; the route-side augmentation (Recipe #16) covers it for now.
- **Apply the same telemetry / observability pass to the new onboard wizard** — the `/api/onboarding/complete-step` route currently doesn't log accepted vs rejected completions. Add this when there's a real complaint about a missing transition.
