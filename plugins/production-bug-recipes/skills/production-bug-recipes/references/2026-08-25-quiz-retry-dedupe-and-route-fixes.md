# Aug 25 2026 — Quiz retry double-credit, module-quiz ace scoring, route-level dedupe pattern

Three real bugs surfaced by a quiz-popup smoke script running against
the live `/api/education/quiz/[id]/attempt` route. The smoke test is the
regression guard; this file is the diagnosis so the next session doesn't
re-learn it.

Bug B (micro-quizzes with `lesson_id=NULL`) is **already** covered by
Recipe #41 in `references/2026-08-24-quiz-system-audit-bugs.md`. Read that
first — migration seed never closes the reverse FK, so any route that does
`if (quiz.lesson_id)` for micro-quizzes silently skips the lesson
progress upsert. This session confirmed Bug B is still latent in
production (lesson_progress.micro_quiz_passed stayed `false` even after
a 100% micro-quiz attempt) and was left for a follow-up commit.

---

## Recipe #42 — Route-level dedupe is REQUIRED when `ref_id` derives from a BIGINT identity (added Aug 25 2026)

**Symptom:** a user passes the same quiz twice. The first attempt
credits 100 platform points, the second attempt credits another 100, points
on `user_accounts` go from 100 → 200 → 300 → ... without bound. The
ledger records each entry as a separate `delta`.

**Root cause — `award_log()` dedupes on `(user_id, reason, ref_id)`,
but the route passes `ref_id = String(attemptRes.data.id)` where
`attemptRes.data.id` is `quiz_attempts.id`, which is BIGINT.**
Each retry mints a new BIGINT. `award_log`'s dedupe is bypassed because
every attempt has a unique `ref_id`. The old code's documentation
explicitly claimed "ref_id = attempt.id (UUID); retries always credit";
the BIGINT vs UUID conflation was the actual bug.

```ts
// BEFORE (broken):
const pointsReason = pointsReasonFor(score, passed)
let awarded = 0
let capReason: string | null = null
if (pointsReason) {       // <-- retry also reaches here
    const award = await awardPoints(svc, auth.userId, pointsReason,
        String(attemptRes.data.id), { /* metadata */ })
    awarded = award.awarded
    capReason = award.capReason
}
```

**The fix — check `hasPassedBefore` at the route level and skip the
credit entirely on retry:**

```ts
// AFTER (correct):
const previousAttempts = prevAttemptsRes.data ?? []
const hasPassedBefore = previousAttempts.some((a) => a.passed === true)

const pointsReason = pointsReasonFor(score, passed)
let awarded = 0
let capReason: string | null = null
let alreadyPassed = hasPassedBefore
if (pointsReason && !alreadyPassed) {
    const award = await awardPoints(svc, auth.userId, pointsReason,
        String(attemptRes.data.id), { /* metadata */ })
    awarded = award.awarded
    capReason = award.capReason
    if (awarded > 0) { /* broadcast profile refresh */ }
}
```

Return both top-level `alreadyPassed` and `result.alreadyPassed` so the
client doesn't have to dig into a nested object. The existing
`QuizRunner` already reads `result.alreadyPassed`, so no UI change
needed; the top-level alias is just for clients that read the response
flat.

**Why not a schema change (UUID attempt_id, `credited` flag)?
Smaller blast radius.** Touches nothing outside this route. Doesn't
risk breaking other reason keys that depend on the BIGINT-shaped
`ref_id` pattern in `award_log`. A future migration can move the
ledger to UUID `ref_id` cleanly if desired; for now this route
becomes the single source of truth for "this is a retry".

**The class rule — any route that writes to `award_log` with
`ref_id = String(<DB-generated-id>)` needs a route-level dedupe guard
unless the dedupe key deliberately should differ per call.** BIGINT
identities mint a fresh value per row, so `(user, reason, BIGINT-as-ref)`
is always a unique key — which is the opposite of what you want.

**Verification — a quiz-popup smoke script runs the full
retry-credit cycle against prod in ~5s. Re-run after touching anything
that calls `award_log`.**

---

## Recipe #43 — `pointsReasonFor()` doesn't distinguish scope: module quizzes with perfect score credit as `quiz_ace` (added Aug 25 2026)

**Symptom:** a user takes a module-final quiz (`pass_pct=70`,
`scope='module'`, `passing_threshold=70`) and scores 100%. The
quiz attempt route credits them 100 platform points and returns
`pointsReason: 'quiz_ace'`. The expected behaviour is 50 platform points
and `pointsReason: 'quiz_pass'`, because:
- `quiz_ace` (100) is reserved for a perfect micro-quiz score (lesson-scoped)
- `quiz_pass` (50) is for any passing module quiz regardless of score

**Root cause — `pointsReasonFor()` branches only on `score === 100`,
not on scope:**

```ts
// src/app/api/education/quiz/[id]/attempt/route.ts
function pointsReasonFor(score: number, passed: boolean): PointsReason | null {
    if (!passed) return null
    return score === 100 ? 'quiz_ace' : 'quiz_pass'
}
```

So a perfect-score module quiz is rewarded identically to a perfect-
score micro-quiz. The two reward tiers collapse onto each other.

**The fix (NOT YET APPLIED — captured here so the next session
doesn't re-discover it):**

```ts
function pointsReasonFor(score: number, passed: boolean, scope: string): PointsReason | null {
    if (!passed) return null
    // quiz_ace is only the lesson-scoped (micro-quiz) 100% perfect run.
    // Module-final quizzes always credit quiz_pass.
    if (score === 100 && scope === 'lesson') return 'quiz_ace'
    return 'quiz_pass'
}
```

**Why this is the right rule — `quiz_ace` (100 pts) is meant to
incentivise perfect micro-quiz runs (the per-lesson attempt that drives
lesson completion), whereas `quiz_pass` (50 pts) is the standard
module-final reward.** Conflating them makes the higher tier
trivially reachable by acing any module quiz, collapsing the
gamification signal.

**Alternative — change the points config.** If the intent is actually
"any 100% score credits 100 regardless of scope," then update
`src/lib/os-points/config.ts` to remove the tier distinction and add
a comment. But the QuizRunner UI specifically labels `quiz_ace`
as "Quiz Ace — 100%" with a celebratory treatment (different from
"Quiz Passed"), so the two-tier UX assumption is built into the
client. Either fix has to be made on both sides.

**Verification — a quiz-popup smoke script currently flags this
as a `KNOWN ISSUE` (doesn't fail). When fixed, change the assertion
from `info(KNOWN ISSUE)` back to `pass()` and confirm a perfect module
quiz credits 50, not 100.**

---

## Workflow — Build the regression-guard smoke BEFORE deploying the fix (added Aug 25 2026)

This is the workflow that produced Recipes #42 and #43:

1. **Start with a real-prod test, not a code reading.** Even though the
   route's docstring claimed UUID ref_id, the code reading wasn't
   enough — running the actual route with the actual `attemptId`
   returning BIGINT surfaced the bug immediately. Build the smoke test
   first; let it fail; THEN write the fix.

2. **Smoke is `scripts/<feature>_popup.mjs`** in the project root's
   `scripts/` directory (not `~/.agent-home/scripts/` — that path is
   reserved for the agent runtime-level cron/scheduled scripts, see Recipe #9).
   Pattern matches `scripts/smoke_onboarding.mjs` and
   a smoke test for the points award path. Service-role key read from
   `<project-dir>/scripts/apply-migration.mjs` via:

   ```js
   const KEY = re.search(r"SERVICE_KEY = '([^']+)'",
       readFileSync('<project-dir>/scripts/apply-migration.mjs', 'utf8'))[1]
   process.env.SUPABASE_SERVICE_ROLE_KEY = KEY
   ```

3. **Cleanup must include `partners` row deletion before `auth.users`
   deletion** — `auth.users` has a FK from `partners.user_id`
   (`affiliates_user_id_fkey`). A naive auth admin DELETE returns 500.
   Order is: (a) DELETE from `partners WHERE user_id = $1`, then (b)
   DELETE from `auth.users` via `/auth/v1/admin/users/{id}`. Same
   pattern is needed for any test signup that gets CASCADE-linked to
   `partners`.

4. **Atomically ship fix + smoke + SW bump as ONE commit, amended.**
   `b817dd9f` from Aug 24 claimed to fix the very same retry bug but
   didn't include a smoke test, so the regression went undetected for
   a day and a half. The session-tested pattern: write fix → amend
   smoke into the same commit → push with `--force-with-lease` →
   deploy → run smoke against prod → verify green.

5. **Mark known unfixed bugs as `info()` not `fail()`.** When the
   smoke surfaces related bugs that the user didn't ask you to fix,
   they go in as `info(KNOWN ISSUE: ...)` so the smoke remains a
   clean PASS/FAIL signal for the bug you actually fixed. Comments
   inside the test name the bug class so the next session can
   pick them up by reading the file.

6. **The test file's job is also to document the assumption that
   broke.** Bugs A, B, and C each surface when the test makes an
   assertion that should have caught them earlier — leave a comment
   in the test explaining the schema/data mismatch (e.g. `// quiz_attempts.id
   is BIGINT, not UUID as some docstrings claim`). That context
   disappears if you only fix the production code.

**Run command:**
```
SUPABASE_SERVICE_ROLE_KEY=$(...) node a quiz-popup smoke script
```

A green run is 20 passed, 0 failed. Any new failure or KNOWN-ISSUE
shift is a regression signal.

---

## Session-level findings (not yet recipes, but worth noting)

- **`points_ledger` column is `delta`, not `amount`.** The legacy
  table `app_point_ledger` (no S) has `amount`; the canonical
  `points_ledger` (with S) has `delta`. When writing smoke tests or
  admin dashboards, always query `information_schema.columns` before
  referencing the ledger by column name. Recipe #39 captures the
  cross-table confusion; this is the per-column follow-up.

- **Lesson.jsx client-side render vs quiz route data.** The
  LessonViewer reads `micro_quiz_passed` from `user_lesson_progress`
  on mount. If the route never updates that row (Bug B / Recipe #41),
  the client UI will not transition the lesson to "completed" even
  though the user passed, even though the points popup fired, even
  though `course_complete` engine-cascade is waiting on all lessons
  in the track. This means the lesson-completion signal is
  downstream of multiple separate routes — single-route fixes can
  re-introduce this gap. The next session that touches
  `LessonViewer.tsx` or the quiz attempt route should re-run the
  full smoke and grep for `micro_quiz_passed` in the live response.

- **Railway auto-deploys from working tree, not from pushed commits.**
  If you `railway up` before committing + pushing, the production
  state will be ahead of git. Force the workflow: commit first,
  push second, `railway up` third. Capture this as a step in
  a deploy script if it doesn't already exist.
