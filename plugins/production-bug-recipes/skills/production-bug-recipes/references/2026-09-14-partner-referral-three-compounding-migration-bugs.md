# 2026-09-14 — Partner referral migration had THREE compounding column-reference bugs

The user repeatedly hit SQL errors pasting a single migration I claimed was "idempotent." Each attempt surfaced a different mistake in the SAME migration. This file captures the lesson: when a feature depends on a migration, the migration's actual surface area is what dictates whether the feature works in production — not whether it parses locally.

## The three bugs in `20260911_partner_referral.sql`

| # | Symptom on paste | Root cause | Fix landed in commit |
|---|---|---|---|
| 1 | `column "whitelabel_referral_url" of relation "partners" does not exist` | The view `v_qualified_partners` references `p.whitelabel_referral_url`, but the file was missing the `ALTER TABLE public.partners ADD COLUMN IF NOT EXISTS whitelabel_referral_url TEXT` statement. View ran before the column was added. | `ca7a4d58` then folded into `936341ba` |
| 2 | `column pu.first_name does not exist` | The view references `pu.first_name, pu.last_name` but those columns were never on `user_accounts` (only `full_name` exists there). They live in `auth.users.raw_user_meta_data` but were never synced down. | `ca7a4d58` (new migration `20260914_fix_qualified_partners_view.sql` adds the columns + backfill) |
| 3 | `column pu.is_partner does not exist` | The view references `pu.is_partner` — wrong alias. `is_partner` lives on `public.partners`, not `public.user_accounts`. The column flag for "this user is a partner" splits: `user_accounts.is_master_partner` (yes/no) vs `public.partners.is_partner` (yes/no). | `599caa96` folded into `936341ba` |

All three lived in the same migration file. All three produced a confusing SQL error on first paste. All three required a separate fix commit. The user asked "What do you see in this image?" after error #3, and I had to admit the migration file referenced an aliased column that didn't exist on that table.

## The general check: before claiming a migration is "idempotent"

A migration is idempotent only if every statement inside it is itself idempotent **AND references objects that exist at the time the statement runs.** The first time I thought "I added `ALTER TABLE … ADD COLUMN IF NOT EXISTS` so we're safe." That was wrong because I never even added the `ALTER TABLE` for `whitelabel_referral_url` in that file — it lived in someone else's mental model of what the migration was supposed to contain.

### Pre-deploy checklist for any new Supabase migration

Before shipping a migration that a feature depends on, walk this list manually:

```bash
# 1. Every column the SQL mentions must have a CREATE / ALTER that adds it
#    earlier in the SAME file (or in a file that's been applied earlier
#    in production). The migration should be standalone — don't depend
#    on a sibling migration being applied.
grep -E "(\\.toUpperCase|\\.first_name|\\.is_partner|\\.last_name|\\.email|\\.status)" <file>
# ↑ for each match, find the corresponding CREATE TABLE or ALTER TABLE that adds it.
# If the column doesn't exist in any column-list: BUG.

# 2. Every column reference uses the correct table alias.
#    `pu.foo` means `user_accounts.foo`. If `foo` is on `public.partners`,
#    use `p.foo` not `pu.foo`. SQL doesn't tell you that `is_partner`
#    is on a DIFFERENT table — the name is identical.
#    Mitigation: alias your `JOIN`s based on the column being read, not
#    the column being filtered.

# 3. Backfill idempotency. Anything that runs `UPDATE foo SET x = ...`
#    must be safe to run twice — `WHERE x IS NULL OR x = ''` clauses.
#    Otherwise the second run will overwrite the first run's corrections.

# 4. View definitions rebuilds cleanly. CREATE OR REPLACE VIEW is OK
#    but if the view bodies reference functions or tables that don't
#    exist, the CREATE itself fails and rolls back the transaction.
```

### When the user reports a SQL error on paste

Each error the user reports is a NEW bug in the file. Don't tell them "try again" or "paste the rest." Diagnose:

1. Get the EXACT error line from the user
2. Read the line in the file
3. Check what `column <X> of relation <Y> doesn't exist` means literally — Y is the table the SQL is reading from, X must live on Y or in any joined Y
4. If the column exists on a different table: alias mismatch (bug #3 above)
5. If the column doesn't exist anywhere in any active migration: missing ALTER TABLE (bug #1 above)

In the partner-referral incident, all three were present and shipped one by one because each fix landed BEFORE the user re-ran the full SQL.

## Schema-location cheatsheet (Sep 14 2026 snapshot)

| Concept | Table | Column |
|---|---|---|
| User master toggle (admin) | `user_accounts` | `is_admin` |
| User trader toggle | `user_accounts` | `is_trader` (added Sep 7) |
| User partner-master toggle | `user_accounts` | `is_master_partner` (added Sep 10) |
| **User partner toggle** | **`public.partners`** (separate table) | **`is_partner`** |
| Partner referral URL | `public.partners` | `whitelabel_referral_url` (added Sep 11) |
| Referred-by partner for a user | `user_accounts` | `referred_by_partner_id` (FK → `partners.id`) |
| Partner display name (for dropdown) | view `public.v_qualified_partners` | joins `partners` LEFT `user_accounts`, filters on either `is_master_partner` OR `is_partner` |

The naming split: `user_accounts.is_master_partner = true` means "this user is the platform's master partner (typically `support@yourdomain.com`); we should auto-provision a partner row in `public.partners` when they sign up." `public.partners.is_partner = true` means "this is a normal partner, anyone who's applied to the IB program and been accepted."

`UserContext.isPartner` returns true when EITHER the master-partner flag OR a row in `public.partners` exists with `is_partner=true`.

## Code change: where the partner check lives

`/api/partners/me/whitelabel-referral/route.ts` was the consumer of these columns. Original code (broken) used the wrong table:

```ts
// ❌ Before — asking user_accounts for a column that doesn't exist there
const { data: pu } = await svc
    .from('user_accounts')
    .select('is_partner, is_master_partner, partners_id')
    .eq('id', userId).single()
if (!pu?.is_partner && !pu?.is_master_partner) return 403
if (!pu?.partners_id) return 400
```

Fixed version (in commit `1473e323`):

```ts
// ✅ After — partners.is_partner from public.partners; master from user_accounts; auto-provision master
const { data: partnerRow } = await svc
    .from('partners').select('id, is_partner')
    .eq('user_id', userId).eq('is_partner', true).maybeSingle()
const { data: pu } = await svc
    .from('user_accounts').select('is_master_partner')
    .eq('id', userId).maybeSingle()
if (!partnerRow && pu?.is_master_partner) {
    // Auto-create a partners row for masters so they can save referral URLs immediately.
    await svc.from('partners').upsert({ user_id: userId, is_partner: true, ... }, { onConflict: 'user_id' })
}
```

The auto-provision pattern means master-partner users (the user themselves) don't have to run a SQL `INSERT` to start saving white-label broker URLs — the API does it on first request.

## Files touched during the partner-referral incident

| File | Commit | Fix |
|---|---|---|
| `supabase/migrations/20260911_partner_referral.sql` | `936341ba` | Added `whitelabel_referral_url` ALTER TABLE + first_name/last_name columns + corrected `p.is_partner` alias |
| `supabase/migrations/20260914_fix_qualified_partners_view.sql` | `ca7a4d58` | Helper migration for users who'd already applied the broken 20260911 in production |
| `src/app/api/partners/me/whitelabel-referral/route.ts` | `1473e323` | Authoritative check against `public.partners.is_partner`, auto-provision masters |

## Recipe anchor

When the next feature migration ships, walk the four-step pre-deploy checklist above BEFORE the user pastes. Most bugs discovered at paste time are pre-discoverable by grep + reading.

The inverse lesson, from a session where the agent claimed it could apply
SQL when it could not: be honest about what you can't apply. This file's lesson: be sure what you CAN apply is actually correct before the user finds out.
