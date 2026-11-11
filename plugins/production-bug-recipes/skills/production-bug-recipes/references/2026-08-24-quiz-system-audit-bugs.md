# Aug 24 2026 — Quiz system audit bugs (drop-in for SKILL.md merge)

Three real bugs found while auditing the quiz system for the "no popup / step doesn't mark complete" report. The root cause is **not** in the popup or the completion logic — it's in the lesson-completion gate that hardcodes a 80% threshold while several quizzes pass at 70%.

The session's other work (cookie mirror, dashboard nav removal, application-approved step, etc.) is captured in `references/2026-08-24-onboarding-hero-glitch-and-partner-portal-v3.md`.

---

## Recipe #38 — Lesson-completion gate uses a hardcoded 80% pass threshold (added Aug 24 2026)

**Symptom:** user passes a micro-quiz (popup fires, points credit, "you passed" message shows). The lesson does NOT flip to "completed." The next lesson stays locked. The user says: "I passed the quiz but the lesson doesn't mark off as complete."

**Root cause — the lesson progress route hardcodes 80% as the pass threshold for the micro-quiz gate, but the actual quizzes pass at either 70% or 80% depending on the quiz:**

```ts
// src/app/api/education/lesson/[id]/progress/route.ts
const microQuizPassed = newMicroQuizScore !== null
    ? newMicroQuizScore >= 80
    : (prev?.micro_quiz_passed ?? false)
```

50 micro-quizzes exist in the DB (query `education_quizzes WHERE scope='module'`). Of those:
- Quizzes 21-23 (Markets, Price Action, Trade Mechanics module-end quizzes): `pass_pct=70`
- Quizzes 38-40, 54-56, 70 (module-end quizzes for Candles, Structure, Indicators, Position Sizing, Stop Placement, Drawdown, Broker Connection): `pass_pct=70`
- The other 35 micro-quizzes: `pass_pct=80`

A user who passes a 70%-threshold quiz with a score of 75%:
- ✅ Quiz attempt POST returns `passed: true, pointsEarned: 50`
- ✅ Popup fires (because `pointsEarned > 0`)
- ❌ Lesson progress gate fails (75 < 80) → lesson NOT marked complete
- ❌ `course_complete` never fires (it depends on all lessons in a track being completed)
- ❌ `course_complete` bonus never awarded

**The fix — read the actual `pass_pct` from the `education_quizzes` table, do not hardcode:**

```ts
// Fetch the actual pass_pct for this lesson's micro-quiz
const { data: quiz } = await svc
    .from('education_quizzes')
    .select('id, pass_pct')
    .eq('id', lessonRes.data.micro_quiz_id)
    .maybeSingle()
const requiredPct = quiz?.pass_pct ?? 80  // fallback to 80 only if the quiz is missing

const microQuizPassed = newMicroQuizScore !== null
    ? newMicroQuizScore >= requiredPct
    : (prev?.micro_quiz_passed ?? false)
```

The check is a single extra query, runs server-side, and matches the actual `pass_pct` the user sees in the UI. Falls back to 80 only if the `micro_quiz_id` points to a missing quiz (data integrity issue, not a user-facing one).

**Alternative fix — kill the lesson-side gate entirely and trust the quiz route's `passed` flag:**

The quiz attempt route already returns `passed: true/false` based on `score >= quiz.pass_pct`. That's the source of truth. The lesson progress route doesn't need a redundant pass threshold — it should just trust the `quiz_attempts.passed` column:

```ts
// Simpler — one query
const { data: attempt } = await svc
    .from('quiz_attempts')
    .select('passed, score')
    .eq('user_id', auth.userId)
    .eq('quiz_id', lessonRes.data.micro_quiz_id)
    .eq('passed', true)
    .order('attempt_at', { ascending: false })
    .limit(1)
    .maybeSingle()
const microQuizPassed = !!attempt
```

This is the right fix long-term — the lesson doesn't need to know the quiz's pass threshold, it just needs to know whether the user has ever passed. The `quiz_attempts` table is the canonical record of quiz passes.

**The diagnostic for "is this bug biting me?":**

```sql
SELECT id, title, pass_pct
FROM public.education_quizzes
WHERE scope = 'module' AND pass_pct < 80
ORDER BY pass_pct, id;
```

If you get any rows back, the bug is active for those quizzes. As of Aug 24 2026, this returns 9 module-end quizzes that fail to flip their lesson status when the user scores between 70% and 79%.

**When this hits again:** any code path that translates between two related thresholds (a quiz's `pass_pct` and a lesson's "is this quiz done?" gate). Read the canonical source instead of hardcoding. Better yet, trust the result that the upstream route already computed (the `passed` flag in this case).

---

## Recipe #39 — Two ledger tables, two writers, no reader (added Aug 24 2026)

**Symptom:** the user's points balance updates correctly when they earn points. The points popup fires. But the activity log / ledger view shows nothing for that user — no record of the award. The user can see their points went up but can't see WHERE they came from.

**Root cause — there are TWO ledger tables in the DB, written by different code paths, read by no single source of truth:**

| Table | ID | Columns | Written by | Read by |
|---|---|---|---|---|
| `app_point_ledger` (no S) | BIGSERIAL | `amount, reason, ref_id, metadata, created_at` | admin clawback path in `/api/admin/os/adjust` | the legacy points-history view |
| `points_ledger` (with S) | UUID | `delta, balance_after, reason, ref_id, meta, source, created_at` | `award_log()` SQL function (quiz pass, lesson complete, level up, etc.) | `/api/app/ledger` |

The names are one character apart. The `award_log()` function (the canonical points award path, last REPLACEd in `202608170019_streak_column_name_fix.sql`) writes to `points_ledger`. The admin clawback path in `/api/admin/os/adjust` writes to `app_point_ledger`. The user's recent awards never appear in `app_point_ledger` because the canonical function bypasses it.

The two schemas also have different column conventions:
- `app_point_ledger` uses `amount` (signed integer)
- `points_ledger` uses `delta` (signed integer)
- `app_point_ledger` has `metadata` (JSONB)
- `points_ledger` has `meta` (JSONB)
- `points_ledger` adds `balance_after` (INTEGER) and `source` (TEXT) for richer history

**The fix — pick ONE canonical table and migrate all writers + readers to it. Two options:**

**Option A — keep `points_ledger` (with S) as the canonical table (recommended, it has more useful columns):**

1. Update `/api/admin/os/adjust` to write to `points_ledger` (not `app_point_ledger`). One-line change.
2. Update any other reader of `app_point_ledger` (the legacy points-history view) to read from `points_ledger` instead.
3. Backfill the 10 historical rows from `app_point_ledger` into `points_ledger` with the correct column mappings (`amount` → `delta`, `metadata` → `meta`, etc.).
4. After backfill, drop `app_point_ledger`.

**Option B — keep `app_point_ledger` (no S) as the canonical table:**

1. Update the `award_log()` function in `202608170019_streak_column_name_fix.sql` to insert into `app_point_ledger` instead of `points_ledger`.
2. Update `/api/app/ledger` to read from `app_point_ledger`.
3. Drop `points_ledger` after the migration.

**The diagnostic — is the audit trail split right now?**

```sql
-- Count rows in each ledger
SELECT 'app_point_ledger' AS tbl, count(*) AS rows
FROM public.app_point_ledger
UNION ALL
SELECT 'points_ledger' AS tbl, count(*)
FROM public.points_ledger;
```

If the counts are wildly different (e.g. 10 vs 30+), the split is biting. Both tables should have the same count of historical user awards (modulo schema migrations).

**The broader rule — never have two tables with the same name plus/minus a letter in production.** When a migration changes a column or schema, drop the old table in the same migration. The "I'll get to it later" approach leaves production with two tables forever, and bugs are inevitable when readers and writers disagree on which is canonical.

**When this hits again:** any schema evolution where you "rename by creating a new table and forgetting the old one." Either:
- (a) Rename in-place with `ALTER TABLE ... RENAME TO` (preserves history)
- (b) Create the new table, migrate data, drop the old table IN THE SAME MIGRATION

Never leave the two coexisting.

---

## Recipe #40 — `award_log()` reason-key case-mismatch bypasses all cap enforcement (added Aug 24 2026)

**Symptom:** a user grinds through every education lesson + quiz in a single day. The user earns `lesson_complete` (25) 50+ times, `quiz_pass` (50) 50+ times. None of the daily caps, weekly caps, or lifetime caps are enforced. The user's `points` total balloons to thousands in a few hours. The user also accrues engine-unlock promotions that should have been blocked by the `lifetime_cap: 100` on `lesson_complete`.

**Root cause — the DB stores reason keys in UPPERCASE, the TypeScript config and route code pass LOWERCASE:**

```sql
-- /api/education/quiz/[id]/attempt calls award_log with lowercase:
award_log({p_reason: 'quiz_ace', p_amount: 100, ...})

-- But the DB registry is uppercase:
SELECT * FROM app_point_reasons WHERE reason_key = 'QUIZ_ACE'
-- Returns the row, base_amount=100, daily_cap=NULL, lifetime_cap=NULL
```

The SQL `WHERE reason_key = 'quiz_ace'` is **case-sensitive** in PostgreSQL (it uses the column's collation, which defaults to the database collation — usually `en_US.UTF8` or `POSIX`, both byte-wise case-sensitive). So the lookup fails, `v_reason_record` is NULL, `FOUND` is false, and the function falls back to `p_amount` (50 or 100, passed in by the caller).

But more importantly, the cap checks are wrapped in `IF FOUND`:

```sql
-- 202607310101_points_hard_mode.sql line 280
IF FOUND AND v_reason_record.daily_cap IS NOT NULL THEN
    -- daily cap check
END IF;
```

When `FOUND` is false (because the case-sensitive lookup missed), ALL the cap checks skip. The hourly velocity limit (500/hr, line 414) IS enforced because it's hardcoded — but daily, weekly, monthly, and lifetime caps are NOT.

**Verified via direct test call:**

```sql
SELECT * FROM award_log(
    p_user_id := '614d4229-...',
    p_amount := 100,
    p_reason := 'QUIZ_ACE',  -- uppercase
    p_ref_id := 'test_1'
);
-- Returns: ok=true, amount=100, new_total=300
-- Ledger row written: ✓ (with reason='QUIZ_ACE', which is the actual case stored)
```

vs

```sql
SELECT * FROM award_log(
    p_user_id := '614d4229-...',
    p_amount := 100,
    p_reason := 'quiz_ace',  -- lowercase (what the code passes)
    p_ref_id := 'test_2'
);
-- Returns: ok=true, amount=100, new_total=400
-- Ledger row written: ✓ but with reason='quiz_ace' (different case!)
-- But: the reason lookup FAILED, so the cap checks skipped.
```

**The fix — three options in order of preference:**

**Option 1 (best) — fix the DB registry to use lowercase keys that match the code.** A migration that does `UPDATE app_point_reasons SET reason_key = lower(reason_key) WHERE reason_key =***` (preserving the relationship via a temporary mapping). Then the SQL lookup just works because both sides agree.

**Option 2 — fix the SQL to do a case-insensitive lookup:**

```sql
-- Replace `WHERE reason_key = p_reason` with:
WHERE LOWER(reason_key) = LOWER(p_reason)
```

The fix loses the index optimization (the `reason_key` index becomes useless for this query), but the table is small enough that a seq scan is fine.

**Option 3 — fix the code to pass uppercase keys.** Touch every call site:

```ts
// src/lib/os-points/config.ts — keys are already lowercase, types are right
// But the SQL registry has them as uppercase. Either:
//   (a) Make the registry lowercase
//   (b) Add a `toUpper()` wrapper in the award_log helper
```

**The diagnostic — is this happening to me right now?**

```sql
-- Check the case mismatch
SELECT key_type, count(*)
FROM (
    SELECT 'uppercase_only_in_db' AS key_type FROM app_point_reasons
    WHERE reason_key ~ '[A-Z]'
    UNION ALL
    SELECT 'uppercase_in_code' FROM (
        SELECT DISTINCT reason
        FROM app_point_ledger
    ) s WHERE reason ~ '[A-Z]'
    UNION ALL
    SELECT 'lowercase_in_code' FROM (
        SELECT DISTINCT reason
        FROM app_point_ledger
    ) s WHERE reason ~ '[a-z]'
) sub
GROUP BY key_type;
```

If you get rows in `lowercase_in_code` and `uppercase_only_in_db`, the bug is live and the cap checks are skipping for those reasons. As of Aug 24 2026, the DB has all 50 reasons in UPPERCASE and the canonical recent writes use LOWERCASE (e.g. `quiz_pass`, `quiz_ace`, `lesson_complete`).

**The broader rule — the SQL registry and the TypeScript enum must agree on case.** Pick one case and stick to it. Code reviews should reject any `award_log()` call with a `p_reason` value that doesn't `lower()`-match the registry.

**When this hits again:** any time a SQL function does a string-key lookup on a registry table. Either normalize both sides at the boundary (preferred) or normalize the lookup with `LOWER()` / `UPPER()` (cheaper to add, costs an index).

---

## Recipe #41 — Quiz `migrations/202608010004_education_live.sql` seed never sets `lesson_id` on quizzes with `scope='module'` (added Aug 24 2026)

**Symptom:** the catalog shows 50 micro-quizzes with `scope='module'`, but every single one has `lesson_id=NULL`. The lessons correctly point to their micro-quizzes via `lessons.micro_quiz_id`, but the reverse FK from quiz → lesson is missing. Any feature that needs the canonical link (e.g. "find the lesson for this quiz") has to do a JOIN through the lessons table instead of a direct lookup.

**Root cause — the migration that creates these micro-quizzes uses `scope='module'` and never sets `lesson_id`:**

```sql
-- supabase/migrations/202608010004_education_live.sql and the follow-ups
WITH new_quiz AS (
    INSERT INTO public.education_quizzes (scope, lesson_id, title, pass_pct)
    VALUES ('module', NULL, 'Forex & Currency Pairs micro-quiz', 80) RETURNING id
),
```

The `lesson_id` is hardcoded to `NULL` because the seed is grouped by MODULE, not by lesson. The micro-quizzes are supposed to attach to lessons via the `lessons.micro_quiz_id` FK, but the seed never closes the loop in the OTHER direction (quiz → lesson). The intent was for `scope='module'` to mean "applies to all lessons in the module" — but the schema doesn't actually model that. The micro-quiz is really a lesson-scoped quiz, just with `scope='module'` to bypass the module-quiz aggregation logic.

**The fix — set `lesson_id` correctly in the seed migration OR rename the column to clarify the intent:**

**Option A (best) — fix the seed to point the quiz at the right lesson:**

```sql
-- For each micro-quiz, set lesson_id to the lesson whose micro_quiz_id points here
UPDATE public.education_quizzes q
SET lesson_id = (
    SELECT id FROM public.education_lessons l
    WHERE l.micro_quiz_id = q.id
    LIMIT 1
)
WHERE q.lesson_id IS NULL
  AND q.scope = 'module'
  AND EXISTS (SELECT 1 FROM public.education_lessons l WHERE l.micro_quiz_id = q.id);
```

This closes the reverse FK. Any feature that does `SELECT * FROM education_quizzes WHERE lesson_id = $1` will work correctly.

**Option B — leave the schema as-is, but document the asymmetry.** A comment in the SQL:

```sql
COMMENT ON COLUMN public.education_quizzes.lesson_id IS
    'Back-reference from quiz to its parent lesson. NULL for module-end
    quizzes that cover all lessons in a module. Set for micro-quizzes that
    attach to a specific lesson (where the canonical FK lives in
    education_lessons.micro_quiz_id).';
```

**The diagnostic — what state are the quizzes in right now?**

```sql
-- Micro-quizzes with no reverse FK
SELECT count(*) AS orphaned_micro_quizzes
FROM public.education_quizzes q
WHERE q.lesson_id IS NULL
  AND q.scope = 'module'
  AND EXISTS (SELECT 1 FROM public.education_lessons l WHERE l.micro_quiz_id = q.id);
-- As of Aug 24 2026: 47 (all the micro-quizzes)
```

**The broader rule — when a model has two tables with a 1:1 relationship, model the FK on BOTH sides.** Even if the data layer enforces it on only one side (the table with the FK), the other table should still have the column for query convenience. Migrations that seed data should close BOTH sides of the loop.

**When this hits again:** any time you have a `parent_id` column on table A pointing to B, and table B has a `child_id` column pointing to A. The "many children per parent" case is fine, but the "exactly one" case (1:1) MUST close both sides. SQL ORMs and query tools assume the bidirectional relationship exists.

---

## Session diagnostics that paid off

The audit caught all three bugs by following this order:

1. **Call the actual API with a real user.** Set up a JWT via `/auth/v1/admin/generate_link` + `/auth/v1/verify`, hit the actual route, read the response. Don't try to deduce behavior from code reading alone.

2. **Read back the DB state after the API call.** Check `quiz_attempts`, `user_accounts.points`, AND both ledger tables. The route claimed `pointsEarned: 100` but `user_accounts.points` went up while NO ledger row existed in `app_point_ledger` — the platform points system was bypassing the audit trail.

3. **Query the SQL function directly via RPC.** When the route's behavior is suspicious, call `award_log()` directly and see what it does. Reveals the case-mismatch bug because the route passes lowercase and the registry is uppercase.

4. **Check `information_schema.columns` before assuming column names.** Always verify the schema before writing a route that joins across tables. Avoids the entire "trader_id vs trader_profile_id vs user_id" confusion class.

The combination of these four techniques catches the class of bug where the route returns success but the side effects don't happen — which is the user's actual reported symptom in production.
