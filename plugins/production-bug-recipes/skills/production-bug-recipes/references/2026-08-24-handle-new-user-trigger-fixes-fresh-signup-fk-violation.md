# Recipe — `handle_new_user` trigger must create ALL dependent rows, not just `partners` (added Aug 24 2026)

## Symptom

A brand-new Supabase auth signup completes in `auth.users` but
**no `user_accounts` row gets created**. Every subsequent onboarding
step POST returns 400 or 500:

- `POST /api/onboarding/complete-step` with `step_key: 'profile_basics'`
  → `{"ok":false,"error":"step_not_complete:avatar_not_set"}` even
  though `user_accounts.avatar_url` is set
- `POST /api/onboarding/complete-step` with `step_key: 'walkthrough'`
  → `500 insert or update on table "user_progress" violates
  foreign key constraint "user_onboarding_progress_user_id_fkey"`
- The lifecycle API returns the right shape, but the wizard can
  never complete

The user is **stuck on the onboarding wizard forever** even though
they're a brand new signup that should auto-progress.

## Root cause

The `handle_new_user()` trigger on `auth.users` only inserted into
`partners`, never into `user_accounts`. Looking at
`supabase/migrations/202604021103_fix_trigger.sql`:

```sql
CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public
AS $$
BEGIN
    INSERT INTO partners (user_id, is_partner)
    VALUES (NEW.id, false)
    ON CONFLICT (user_id) DO NOTHING;
    RETURN NEW;
END;
$$;
```

But **`partners` and `user_accounts` are two different tables**, and
`user_accounts` is the table that:

1. Holds `avatar_url`, `full_name`, `risk_acknowledged_at`,
   `broker_connection_status` — the data the wizard's step checks read
2. Has the FK relationship to `user_progress.user_id`

So the wizard's step checks always see an empty row (no `user_accounts`),
refuse the flip, and then the SQL upsert on `user_progress`
fails the FK constraint.

The bug was masked for the grandfathered admin and any user who
went through `/get-started` (which calls `/api/signup/register`
that upserts a `user_accounts` row). Brand-new Supabase signups that
went straight to onboarding — exactly the first-50 launch wave — hit it.

## The fix

Rewrite the trigger to also create a `user_accounts` row with safe
defaults, and backfill all existing auth users. Idempotent.

`supabase/migrations/202608240000_handle_new_user_creates_user_accounts.sql`:

```sql
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public
AS $$
DECLARE
    v_display_name TEXT;
BEGIN
    -- Derive a sensible display name from user_metadata or email local-part.
    v_display_name := COALESCE(
        NULLIF(NEW.raw_user_meta_data->>'full_name', ''),
        NULLIF(split_part(NEW.email, '@', 1), '')
    );

    -- Create the partners row (existing behavior).
    IF NOT EXISTS (SELECT 1 FROM public.partners WHERE user_id = NEW.id) THEN
        INSERT INTO public.partners (user_id, is_partner)
        VALUES (NEW.id, false);
    END IF;

    -- Create the user_accounts row with safe defaults. (THE FIX.)
    INSERT INTO public.user_accounts (id, email, full_name)
    VALUES (NEW.id, NEW.email, v_display_name)
    ON CONFLICT (id) DO NOTHING;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- Backfill existing users who don't have a user_accounts row.
INSERT INTO public.user_accounts (id, email, full_name)
SELECT
    au.id,
    au.email,
    COALESCE(
        NULLIF(au.raw_user_meta_data->>'full_name', ''),
        NULLIF(split_part(au.email, '@', 1), '')
    )
FROM auth.users au
LEFT JOIN public.user_accounts pu ON pu.id = au.id
WHERE pu.id IS NULL
ON CONFLICT (id) DO NOTHING;

-- Same backfill for partners rows.
INSERT INTO public.partners (user_id, is_partner)
SELECT au.id, false
FROM auth.users au
WHERE NOT EXISTS (SELECT 1 FROM public.partners p WHERE p.user_id = au.id);
```

**Two key things to get right:**

1. The `INSERT ... ON CONFLICT (id) DO NOTHING` on `user_accounts`
   because `user_accounts.id` IS the PK — there's a unique constraint,
   so the conflict target is `id`. For `partners`, `partners.user_id`
   has NO unique constraint, so `ON CONFLICT (user_id) DO NOTHING`
   fails with `there is no unique or exclusion constraint matching the
   ON CONFLICT specification` — use a `NOT EXISTS` guard instead.

2. **The backfill is critical** — without it, all existing auth.users
   continue to have no `user_accounts` row. The trigger only fires on
   new signups; it doesn't reach back in time.

## The diagnostic recipe — when a user reports "I can't complete onboarding"

1. **Check if `user_accounts` has a row for that user:**
   ```sql
   SELECT id, email, full_name, onboarding_complete
   FROM public.user_accounts
   WHERE id = '<user_id>';
   -- If 0 rows: trigger did not fire / did not insert into user_accounts
   ```

2. **Check if the trigger exists and is bound:**
   ```sql
   SELECT proname, prosrc
   FROM pg_proc
   WHERE proname = 'handle_new_user';
   -- Should return ONE row showing the function body
   ```
   ```sql
   SELECT tgname, tgrelid::regclass, tgenabled
   FROM pg_trigger
   WHERE tgname = 'on_auth_user_created';
   -- Should return ONE row pointing at auth.users with tgenabled = 'O' (origin)
   ```

3. **Check the trigger body for the user_accounts INSERT:**
   - If the function body ends after `INSERT INTO partners ...` (the
     pre-fix state), the trigger is the bug.
   - If it has `INSERT INTO public.user_accounts ...`, the trigger is
     fine — look for an FK violation somewhere else (the `partners`
     table has `user_id` as FK to `auth.users` but no NOT NULL, so it
     can coexist with a missing user_accounts row).

4. **Try a fresh signup from scratch to verify:**
   ```js
   const r = await fetch(`${SUPABASE_URL}/auth/v1/signup`, {
       method: 'POST',
       headers: { apikey: SERVICE_KEY, 'Content-Type': 'application/json' },
       body: JSON.stringify({ email: 'e2e@yourdomain.com', password: '...' })
   })
   const { user } = await r.json()
   // Wait 1.5s for the trigger
   await new Promise(r => setTimeout(r, 1500))
   // Verify user_accounts row exists
   const pu = await fetch(
       `${SUPABASE_URL}/rest/v1/user_accounts?id=eq.${user.id}`,
       { headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}` } }
   ).then(r => r.json())
   console.log('user_accounts rows:', pu.length)  // should be 1, not 0
   ```

5. **Verify the lifecycle flips to 7/7:**
   ```bash
   node scripts/smoke_onboarding.mjs
   # Should print: 15 passed, 0 failed (15 total)
   ```

## The smoke test that catches this in CI

`scripts/smoke_onboarding.mjs` (added Aug 24 2026) walks the entire
onboarding flow as a brand-new Supabase auth signup. Step 2 of the
test is the canary: "verify the handle_new_user trigger created a
user_accounts row". If step 2 ever fails, you have this bug again.

```js
const pubRes = await fetch(
    `${SUPABASE_URL}/rest/v1/user_accounts?id=eq.${userId}`,
    { headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}` } }
)
const pubRows = await pubRes.json()
if (pubRows.length === 1) pass('2. handle_new_user trigger fired', 'user_accounts row exists')
else { fail('2. handle_new_user trigger', `expected 1 user_accounts row, got ${pubRows.length}`); return }
```

Run this in CI on every commit that touches `supabase/migrations/` or
`src/lib/auth/`. The 6-second runtime is worth the catch.

## When this hits again

The class is: **"the auth trigger creates a subset of dependent rows,
not all of them."** Variations:

- Adding a new table that should auto-create per user? Update
  `handle_new_user` in the same migration that creates the table.
- Modifying `user_accounts` columns? Verify the trigger's
  `INSERT INTO user_accounts` matches.
- Adding a new FK constraint on a `public.*` table? Backfill the
  parent rows BEFORE creating the FK, or the migration will fail.

**The general rule:** every `auth.users` INSERT must trigger a
**complete** set of `public.*` row creations, not a partial set.
"Missing user_accounts" manifests as silent wizard-stuck states
because the check helpers return null (no row → no `data` → null)
and the steps flip to `step_not_complete:*` for the wrong reason.

## Companion: the partners.user_id non-unique gotcha

The `partners` table has `user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE`
— no `UNIQUE` constraint. So `INSERT ... ON CONFLICT (user_id) DO NOTHING`
**fails** with:

```
ERROR: there is no unique or exclusion constraint matching the
ON CONFLICT specification (SQLSTATE 42P10)
```

Use `IF NOT EXISTS` guards instead:

```sql
IF NOT EXISTS (SELECT 1 FROM public.partners WHERE user_id = NEW.id) THEN
    INSERT INTO public.partners (user_id, is_partner)
    VALUES (NEW.id, false);
END IF;
```

Or add a unique constraint to `partners.user_id` (which would have
been the right schema choice years ago).

## Test result on prod

15 / 15 pass — the smoke test confirms signup → trigger → user_accounts
row → 7 onboarding steps → onboarding_complete=true → /dashboard/trading
returns 200. The fix unblocks the first-50 launch wave.
