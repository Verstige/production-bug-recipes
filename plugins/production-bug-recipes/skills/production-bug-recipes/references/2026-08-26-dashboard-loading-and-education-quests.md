# Aug 26 2026 — Dashboard loading-state pivots, education page race, quiz flow stale closure

Session drop-in for `this skill's SKILL.md`.

This session shipped **four commits** (`5e70931e`, `05729fcc`, `70944f7f`, plus
the user-applied SQL `202608260011_backfill_wizard_points.sql`) that
fixed **five distinct bugs** the user hit during hands-on testing of
the platform:

1. Cross-account glitch after Round 8 already shipped Recipe #45 — but a
   SECOND bug in the same area (catch clears `user`) was uncovered.
2. Black "Loading…" trap that Round 8's safety net didn't fully fix because
   `setUser(null)` in the catch bounced the user to /login.
3. Education page stuck on "Loading curriculum…" because a useEffect that
   bails on `authLoading=true` doesn't re-fire reliably when authLoading
   flips.
4. Quiz submission → lesson marked complete → "Micro-quiz score: 100%" UI,
   but the lesson_progress row had `micro_quiz_score=0, micro_quiz_passed=false`
   because of a stale closure on `microQuizResult`.
5. Wizard credit backfill for users who completed steps BEFORE Round 9 wired
   `pointsReward` for `accent_theme` / `risk_disclaimer` / `walkthrough`.

Recipes #49–#52 cover bugs 1b, 2, 3, 4. Recipe for bug 5 is the backfill
pattern — covered under Recipe #45's adjacent section "Wizard total rewards
must be wired at the same commit as the SQL migration that mirrors them".

## Recipe #49 — `catch` blocks in auth refresh must NOT clear `user` (added Aug 26 2026)

**Symptom:** A user with a valid Supabase session hits a transient REST
error (network blip, Supabase 5xx, expired JWT being rejected with 401). The
UserContext `refreshProfile` catch fires, runs `setUser(null)`. The
`DashboardGuard` effect sees `user === null`, runs `router.push('/login')`.
The user is bounced to /login **even though their session is still valid**.
A hard refresh fixes it (re-fetch gets a fresh session), but the bounce
left them stranded.

**Root cause:** the catch block did the same thing as the "no session" path:

```ts
} catch (error) {
    console.error("Error loading user profile:", error);
    setIsPartner(false); setIsTrader(false); setProfile(null);
    setUser(null);  // ← clears the user, kicks DashboardGuard to /login
    setIsAdmin(false); setHasMembership(false); setLoading(false);
}
```

`setUser(null)` was meant for the case where `supabase.auth.getSession()`
returned null (genuine logged-out state). When a transient REST failure
hit during the supplemental `user_accounts` / `partners` / `traders`
queries, the catch fired even though `user` was already set from the
session check. Clearing it was the wrong default.

**The fix — only clear `user` in the genuine-logged-out path, not on
transient errors:**

```ts
} catch (error) {
    console.error("Error loading user profile:", error);
    // KEEP `user` set. The session came from supabase.auth.getSession()
    // which is independent of the user_accounts REST fetch that just
    // failed. Clearing `user` causes DashboardGuard to redirect to
    // /login even though the session is valid.
    setIsPartner(false);
    setIsTrader(false);
    setProfile(null);
    // ← removed setUser(null)
    setIsAdmin(false);
    setHasMembership(false);
    setLoading(false);
}
```

The genuine-logged-out path (`!currentUser`) already returns early
**before** the catch. So removing `setUser(null)` from the catch only
affects the transient-error path. The user's `user` object stays
populated from the session; downstream UI can render whatever it can
with the partial profile (most consumers fall back to defaults).

**Companion:** Recipe #46 (loading safety net) handles the OTHER half —
loading state stuck on true. Recipe #49 handles the user-object-cleared
half. Both can hit on the same transient error; you need both fixes for
the dashboard to never break.

**Pitfall — `router.push('/login')` in DashboardGuard:** if you keep
`user` set on transient error (Recipe #49), make sure DashboardGuard's
`if (!user) router.push('/login')` only fires for `null`, not for
`undefined` / `false`. With `user === null` strict equality, an
unset user (first render) won't trigger the redirect prematurely. With
`!user`, an undefined user fires the redirect on first render before
session check has resolved — which is a separate bug Recipe #12's
loading-state pattern already handles.

## Recipe #50 — Page-level auth-loading gates use `authLoading && !user`, not `authLoading` alone (added Aug 26 2026)

**Symptom:** a page that gates its render on `authLoading=true` to show
"Loading…" before showing content traps the user on the loading screen
when UserContext's `user` object is set but `loading=true` (e.g. during
supplemental user_accounts fetch). The page never renders until `loading`
flips false, but a slow/hung REST call inside `refreshProfile` keeps
`loading=true` for several seconds. User sees "Loading…" instead of
the actual page content with a partial profile.

**Root cause — the gate condition is too strict:**

```ts
// WRONG — gates on authLoading alone, regardless of whether user is set
if (authLoading) {
    return <Loading… />;
}
```

When `authLoading=true` AND `user={…}` (set from `supabase.auth.getSession()`
already resolved), the page is blocked from rendering. The dashboard
then has to wait for `user_accounts` enrichment to finish — a slow path
that may take seconds or never complete (if it hangs).

**The fix — only gate when user is NOT yet known:**

```ts
// RIGHT — gate only when we don't yet know who's logged in
if (authLoading && !user) {
    return <Loading… />;
}
return user ? <>{children}</> : null;
```

Now the gate is: "I'm waiting to find out who you are." Once the user
object is set (which happens very fast — sub-100ms from
`supabase.auth.getSession()`), the page renders with whatever profile
data is loaded so far. Subsequent profile enrichment updates flow in.

**When `!user` is still the right gate:** in cases where the page
absolutely needs a populated `user` to do anything (e.g. an API call
that requires an auth header), gate on `!user` and let it show the
loading screen until the session check resolves.

**Companion to:** Recipe #46 (loading safety net) and Recipe #49 (don't
clear user on transient errors). The three together give a robust
dashboard-mount: loading safety net guarantees `loading=false` within 8
seconds, catch doesn't clear the user, and the page renders as soon as
the user object is known.

**Where this applies in the platform:**
- `src/app/dashboard/(main)/education/page.tsx`
- `src/app/dashboard/(main)/partners/page.tsx`
- `src/components/onboarding/OnboardingHero.tsx`
- `src/components/onboarding/OnboardingChecklist.tsx`
- Any other client page that imports `useUser()` and gates on `authLoading`

## Recipe #51 — Auth-gated pages need a `setTimeout` fallback when `authLoading` races with effect deps (added Aug 26 2026)

**Symptom:** a page-level effect like:

```ts
useEffect(() => {
    if (authLoading) return;
    if (!user) return;
    void fetchCurriculum();
}, [authLoading, user, fetchCurriculum]);
```

…appears to never fire for a fresh user even after `authLoading` flips
false. The page stays stuck on "Loading curriculum…" indefinitely. The
underlying API never gets called — the user has to hard-refresh.

**Root cause — the effect bails on `authLoading=true`, then doesn't
re-fire when `authLoading` flips false:**

There are three possible failure modes here:
1. **`fetchCurriculum` reference is stable** — `useCallback([])` makes it
   never change, but `authLoading` and `user` are still in the dep array,
   so it should re-fire. **This works in normal React 18+ behavior**, but…
2. **The effect re-fires, but the user state from a CLOSURE is stale.**
   This is the Aug 26 micro-quiz fix (Recipe #52) — the new closure
   captures the right values, but if the closure is built once on mount
   and never re-runs, it sees the first mount's values.
3. **The component remounts mid-fetch** (e.g. user navigates between
   dashboard tabs) — `useUser()` returns fresh values, but the effect
   setup runs before the new `authLoading=false` value propagates.

**The fix — defense-in-depth, two paths:**

```ts
// Path 1: primary — fires when authLoading flips false / user arrives
useEffect(() => {
    if (authLoading) return;
    if (!user) return;
    void fetchCurriculum();
}, [authLoading, user, fetchCurriculum]);

// Path 2: fallback — fires unconditionally 1.5s after mount. By then
// the gate has settled. Even if Path 1 doesn't fire for whatever
// reason, this catches it.
useEffect(() => {
    const t = setTimeout(() => { void fetchCurriculum(); }, 1500);
    return () => clearTimeout(t);
}, [fetchCurriculum]);
```

`fetchCurriculum` is idempotent (or guarded on the server side) so
double-firing is safe — the second call returns the same data. The
1.5s window is generous enough that the primary path has time to win
the race, but tight enough that a stuck UI doesn't sit for long.

**When this hits again:** any page that:
1. Reads from `useUser()` AND
2. Has a `useEffect` with `[authLoading, user, fetchX]` deps AND
3. Has ever been observed stuck on its loading state in production

Add the 1.5s setTimeout fallback. It's two lines.

**Why not just always gate on a setTimeout?** Because the primary
effect path is the one that fires correctly under normal conditions —
the setTimeout is purely a fallback for the rare race. The primary
path is what users see 99.9% of the time.

## Recipe #52 — Stale closure on `useState` + `setTimeout` + `await` (added Aug 26 2026)

**Symptom:** user passes a micro-quiz, expects "Quiz Passed: 100%, +100 OS
Points" popup + lesson marked complete + "Next Lesson" button. What
actually happens: the points popup fires (correct), the "Lesson
complete!" card shows "Micro-quiz score: 100%" (correct), **but the
`user_lesson_progress` row stays at `micro_quiz_score=null,
micro_quiz_passed=false, status=in_progress`**. The lesson is not
marked complete in the DB, so the next module doesn't unlock.

**Root cause — React stale closure in `useCallback`:**

```ts
const completeLesson = useCallback(async () => {
    const totalSections = data?.lesson?.sections?.length ?? 0;
    const r = await adminFetch(`/api/education/lesson/${lessonId}/progress`, {
        method: 'POST',
        body: JSON.stringify({
            markComplete: true,
            sectionsSeen: totalSections,
            microQuizScore: microQuizResult?.score ?? null,  // ← stale!
        }),
    });
    // ...
}, [completing, completed, lessonId, microQuizResult, awardLessonPoints, data]);

const onQuizComplete = useCallback(async (result) => {
    setMicroQuizResult({ score: result.score, passed: result.passed });
    // ↑ schedules async state update — `microQuizResult` in the closure above
    //   is still null until React re-renders and rebuilds the closure
    // ...
    if (result.passed) {
        await completeLesson();  // ← calls completeLesson with stale microQuizResult
    }
}, [completeLesson]);
```

React's `setMicroQuizResult({...})` schedules the update, but the
state value isn't visible in any closure until the next render. The
`completeLesson` function is the closure from the previous render
where `microQuizResult` was still `null`. Reading
`microQuizResult?.score ?? null` evaluates to `null`. The server
receives `microQuizScore: null` and bails on the gate that requires
score >= pass_pct.

**The fix — pass the just-computed values as parameters, not via
state:**

```ts
const completeLesson = useCallback(async (passedScore?: number | null) => {
    const totalSections = data?.lesson?.sections?.length ?? 0;
    const scoreToSend = passedScore !== undefined
        ? passedScore                                    // ← explicit, no closure
        : (microQuizResult?.score ?? null);              // ← fallback for other call sites
    const r = await adminFetch(`/api/education/lesson/${lessonId}/progress`, {
        method: 'POST',
        body: JSON.stringify({
            markComplete: true,
            sectionsSeen: totalSections,
            microQuizScore: scoreToSend,
        }),
    });
    // ...
}, [completing, completed, lessonId, microQuizResult, awardLessonPoints, data]);

const onQuizComplete = useCallback(async (result) => {
    setMicroQuizResult({ score: result.score, passed: result.passed });
    setShowMicroQuiz(false);
    if (result.pointsEarned && result.pointsEarned > 0) {
        setPointsAwarded({ amount: result.pointsEarned, reason });
    }
    if (result.passed) {
        await completeLesson(result.score);  // ← pass result.score directly
    }
}, [completeLesson]);
```

The `completeLesson` call now receives `result.score` synchronously from
the just-completed quiz attempt. The state update via
`setMicroQuizResult` still happens for downstream UI consumers (the
"Micro-quiz score: 100%" line in the LessonViewer reads it), but the
critical write to the server uses the synchronous value.

**When this hits again:** any handler that:
1. Does `setState(X)` then synchronously calls another function (often
   through `await`) that reads `X` from closure
2. Uses `useCallback` (where stale closures are particularly sticky
   because the function ref doesn't change)
3. Has a state value that's used inside an `await adminFetch` /
   similar async block

**The fix is always the same shape:** parameterize the dependent
function, pass the value explicitly. Don't reach for state inside an
async closure if you just set it on the same render.

**Companion to:** Recipe #23 (TS narrows don't survive React effect
closures + destructuring). Same family of bugs: TypeScript thinks
the value is defined, the runtime thinks the value is the old
one, neither side is wrong in isolation.

## Recipe #53 — QuizRunner is one-question-at-a-time, not all-on-one-page (added Aug 26 2026)

**Symptom:** Playwright repro of the wizard clicks all three answers in
sequence, then tries to click "Submit" — Submit doesn't exist because the
runner shows one question at a time and requires clicking "Next" between
each. The repro "passes" the test but the user_lesson_progress row
never updates because Submit was never clicked. Hours of "the test
succeeded but the bug is still there" follow.

**The actual QuizRunner UI shape:**

```
┌──────────────────────────────────────┐
│  Forex & Currency Pairs micro-quiz  │
│  Pass with 80% or higher to complete │
│                                      │
│  Question 1 of 3                     │
│  MCQ                                 │
│  What does Forex stand for?          │
│  A Foreign exchange                  │
│  B Foreign exports                   │
│  C Forward exchange                  │
│  D Federal export                    │
│  Why: FX = Foreign exchange.         │
│                                      │
│  Previous | Cancel | Next            │  ← Next advances to Q2
└──────────────────────────────────────┘

[After clicking Next on Q1:]

┌──────────────────────────────────────┐
│  Question 2 of 3                     │
│  ...                                 │
│  Previous | Cancel | Next            │  ← Next advances to Q3
└──────────────────────────────────────┘

[After clicking Next on Q2:]

┌──────────────────────────────────────┐
│  Question 3 of 3                     │
│  ...                                 │
│  Previous | Cancel | Submit          │  ← Submit only on last question
└──────────────────────────────────────┘
```

**The LessonViewer wraps QuizRunner inside a "Take Micro-Quiz" gate:**

- User clicks "Next Section" through all sections
- The button text on the LAST section changes from "Next Section" to
  **"Take Micro-Quiz"**
- Clicking it fires `setShowMicroQuiz(true)`, which mounts `<QuizRunner>`

**The QuizRunner nav buttons:**
- `<button onClick={() => setActiveIdx(i - 1)}>` "Previous" (disabled on Q1)
- `<button className="edu-quiz-nav-cancel">` "Cancel" (if `onCancel` provided)
- `<button onClick={() => setActiveIdx(i + 1)}>` "Next" (only when `activeIdx < total - 1`)
- `<button onClick={handleSubmit}>Submit</button>` (only on last question)

**Repro script — the correct sequence:**

```js
// 1. Get correct answers
const questions = await fetch('/api/education/lesson/9', {
    headers: { Authorization: `Bearer ${token}` }
}).then(r => r.json()).then(j => j.lesson.micro_quiz.questions);

// 2. For each question: click option, click Next (or Submit on last)
for (let q = 0; q < questions.length; q++) {
    const qData = questions[q];
    const opt = page.locator(`button:has-text("${qData.options[qData.correct.answer]}")`).first();
    await opt.click();
    await page.waitForTimeout(500);
    if (q < questions.length - 1) {
        await page.locator('button:has-text("Next"):not(:has-text("Next Section"))').first().click();
    } else {
        await page.locator('button:has-text("Submit"):not(:has-text("Submitting"))').first().click();
    }
    await page.waitForTimeout(800);
}
```

**Selector caveats learned the hard way:**
- `button:has-text("Next")` matches BOTH "Next Section" (lesson nav) AND "Next" (quiz nav). Filter with `:not(:has-text("Next Section"))` to isolate quiz-nav.
- `button:has-text("Submit")` matches BOTH "Submit Quiz" (header button) AND "Submit" (final nav button). The header button is a hidden form submit. Filter with `:not(:has-text("Quiz"))` to get the nav button. Or just look for `:not(:has-text("Submitting"))` since "Submitting" only appears on the nav button while pending.
- `button.edu-quiz-nav-primary` is the most reliable class selector for the primary nav button (Next or Submit depending on `activeIdx`). Use this class instead of text matching when the structure is stable.

**Verified end-to-end on the platform for the the client org account:**
- Lesson 9 "What is Forex" — clicked all 5 sections, quiz 3/3, +25
  lesson_complete popup, +100 quiz_ace, status=completed
- Next lesson auto-loads
- micro_quiz_score=100, micro_quiz_passed=true persisted correctly

The "the client org account had 52 points before" → after the verified flow
it had 177 points (52 baseline + 25 lesson_complete + 100 quiz_ace).

## Files changed this session (Aug 26 — Rounds 11–14)

- `src/components/DashboardGuard.tsx` — gate `authLoading && !user` (Round 11)
- `src/context/UserContext.tsx` — preserve `user` in catch; 8s loading safety net (Round 11)
- `src/app/dashboard/(main)/education/page.tsx` — `authLoading && !user` gate; 1.5s setTimeout fallback (Round 12)
- `src/components/education/LessonViewer.tsx` — pass `result.score` through `completeLesson(result.score)` (Round 14)
- `supabase/migrations/202608260011_backfill_wizard_points.sql` — user applied manually; credits accent_theme + risk_disclaimer + walkthrough for users who completed those steps before Round 9 wired the rewards
- `public/sw.js` — bumped v47 → v49

## Cross-cutting pattern

The four recipes (#49–#52) are all about **React state + async + the
gaps in between**. Recipe #45 (per-user channel) and #46 (loading
safety net) from the earlier Aug 26 session covered the same general
theme at the context layer. Recipe #49–#52 cover the same theme at
the handler/effect layer.

Whenever you see:
- `setState(X)` followed immediately by an async function that reads `X`
- a `useCallback` that closes over state used inside an `await` block
- a `useEffect` that bails on a state value and never re-fires
- a `catch` block that clears state that other components depend on

…that's the family Recipe #49–#52 covers. Reach for it.

## How I found them all

For bugs 1–2 (DashboardGuard black screen + cross-account glitch
remainder): ran a login repro script (Playwright + headless
Chromium) with the actual the client org account credentials, watched the
API trace, found the catch block calling `setUser(null)`.

For bug 3 (education page): ran an education-page repro script,
saw the API trace didn't include `/api/education/curriculum`, traced
through `useEffect([authLoading, user, fetchCurriculum])`, found the
race condition.

For bug 4 (quiz flow): ran a quiz-flow repro script, watched
the API trace included `/quiz/24/attempt` followed by
`/lesson/9/progress`, queried the DB directly after the run and saw
`micro_quiz_score=0`, traced back to the stale-closure in
`completeLesson` reading `microQuizResult?.score` before the
state update from `setMicroQuizResult` had propagated.

For all four: **the API trace was the smoking gun every time.** `grep
the production DB after each Playwright run, then trace the route
that fired. Three of four bugs would not have been visible from
the browser DOM alone — the page UI looked fine (popup fired,
lesson-complete card showed 100%, "Next Lesson" button visible),
but the DB was the source of truth and showed the discrepancy.**

The pattern: **API trace + DB query after each step = ground truth.
Always log the API call sequence + read the relevant DB row in any
production bug repro.**
