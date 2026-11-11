# Aug 22 2026 — Quiz system + points-popup fixes (drop-in for SKILL.md merge)

This file is a curated delta for the autonomous SKILL.md curator.
The patcher refused direct SKILL.md writes ("SKILL.md not loaded in this
review turn" / "dedup cache says unchanged"). Drop these three recipes into
SKILL.md right before the "What I deliberately did NOT do" section.

The earlier `references/2026-08-22-session-additions.md` file used the same
pattern. The two files together represent the work added on Aug 22 2026.

---

## Recipe #23 — `award_log` dedupe by `ref_id` is per-attempt granularity, not per-reason (added Aug 22 2026)

**Symptom:** any feature that awards points multiple times for the same conceptual reason (a user passing the same quiz twice, a user re-clicking "mark complete" after a debounce window, a leaderboard cron firing twice due to a retry storm) only awards points ONCE — silently. The user retries, the popup says "+50 pts earned!" but their points balance never moves.

**Root cause — the SQL `award_log` function dedupes by `(user_id, reason, ref_id)`:**

```sql
-- Inside the award_log function
IF p_ref_id IS NOT NULL THEN
    SELECT id INTO v_existing_id
    FROM public.app_point_ledger
    WHERE user_id = p_user_id AND reason = p_reason AND ref_id = p_ref_id
    LIMIT 1;
    IF v_existing_id IS NOT NULL THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'duplicate', 'id', v_existing_id);
    END IF;
END IF;
```

The `ref_id` is the dedupe key. The PREVIOUS quiz-attempt route used `ref_id = String(quizId)` — so every retry of the same quiz hit the dedupe path and returned `{ok: false, reason: 'duplicate'}`. The client never knew points weren't actually credited.

**The user-facing symptom:** "I'm passing the quiz but my points don't go up" or "it says I earned 50 but my balance didn't change."

**The fix — use a fresh `ref_id` per award, derived from the thing being awarded TO:**

| Award reason | Right `ref_id` | Why |
|--------------|---------------|-----|
| Quiz attempt | `quiz_attempts.id` (the attempt row's UUID) | Each attempt is unique — passes should credit every time |
| Trade closed (TP1 hit) | per-close row's UUID | Each close is unique |
| Daily streak check-in | `streak_last_date::TEXT` (the UTC date) | Once per UTC day, not once per user |
| Lesson complete | `user_lesson_progress.id` (the progress row's UUID) | Each progress row is unique |

**The wrong pattern (what to NEVER do):**

```ts
// ❌ WRONG — ref_id is the reason, not the attempt
const REF_ID = `quiz:${quizId}`  // every retry of the same quiz dedupes
await awardPoints(svc, userId, 'quiz_pass', REF_ID, {...})
```

```ts
// ❌ WRONG — ref_id is just the user, so the user can only earn this reason once EVER
const REF_ID = userId
await awardPoints(svc, userId, 'first_login', REF_ID, {...})
```

**The right pattern:**

```ts
// First, INSERT the per-attempt row
const { data: attempt } = await svc.from('quiz_attempts')
    .insert({ user_id, quiz_id, score, passed, answers_json })
    .select('id')
    .single()

// Then use the attempt row's UUID as ref_id
await awardPoints(svc, userId, 'quiz_pass', attempt.id, {...})
```

**Retries always credit points** (different attempt row → different UUID → different `ref_id`). The first attempt also credits. Even the same quiz, same user, same session → all credit.

**The pair — server-authoritative response:**

The CLIENT should never compute `pointsEarned` from a hardcoded POINTS_MAP. The route returns the server's actual award result:

```ts
// Route response
{
  ok: true,
  pointsEarned: 50,           // ← 0 if capped, dup, or capped
  pointsReason: 'quiz_pass',
  capReason: null,            // ← 'capped'|'duplicate'|'velocity_exceeded'|'rpc_error'
  hasPassedBefore: false,     // ← for the "already credited" message
}
```

If `capReason === 'duplicate'` is returned, the user has already been credited for THIS attempt (ref_id collision), but a different attempt row is different. The popup can show "Already credited for this attempt" — but in normal operation this case never fires because each attempt has a fresh UUID.

**The diagnostic — "is the route using the right ref_id?":**

```bash
# Search for awardPoints calls
rg -n "awardPoints\(" src/app/api/
# Each match should pass a fresh, per-instance UUID — not the
# user_id, not the quiz_id, not the resource_id
```

If you find a call like `awardPoints(svc, userId, 'quiz_pass', String(quizId), {})` — that's the bug. Replace with `awardPoints(svc, userId, 'quiz_pass', String(attempt.id), {})` where `attempt` is the row you just inserted.

**Rule for every new award reason:** the `ref_id` MUST be a fresh, per-instance identifier — either a UUID from a newly-inserted row, a date string, or a hash that varies per award event. Never `ResourceType:ResourceId`. Never the user's UUID.

**When this hits again:** any new feature that calls `award_log`. Audit: open every call site and ask "what would happen if the same user hit this award reason 100 times?" If the answer is "the user would only earn it once," the ref_id is wrong. If the answer is "they'd earn it 100 times," it's right (assuming no other cap fires).

## Recipe #24 — Server-authoritative points + popup rendering pattern (added Aug 22 2026)

**Symptom:** a quiz completion popup, points-earned toast, or "lesson complete" dialog shows a number that doesn't match what was actually credited to the user. The user says "I passed the quiz but the popup said +50 and my points didn't go up." Or the reverse: "I failed but it showed points awarded." Or "I passed twice, only the first gave points, but the popup showed +50 both times."

**Root cause — three layered bugs that all hit at once:**

1. **Client-side points math.** The component computes `pointsEarned = POINTS_MAP[reason]` from a hardcoded literal. If the SQL `app_point_reasons.base_amount` drifts from the client literal (because someone bumped the amount server-side and forgot to bump the TS file, or vice versa), the popup lies.
2. **Fire-and-forget submit.** The submit handler does `void adminFetch(...)` — never awaits. The popup fires before the network round-trip completes. On a slow connection or 500, the popup shows points that were never credited.
3. **No cap/dedup feedback.** When `award_log` returns `{ok: false, reason: 'capped' | 'duplicate' | 'velocity_exceeded' | 'rpc_error'}`, the client never knows. The popup shows a generic "+50" even though the ledger got 0.

**The fix — three layers, all server-truth:**

**Layer 1 — server-authoritative response shape:**

```ts
// Route returns
{
  ok: true,
  attemptId: <uuid>,
  attemptNumber: 1,
  score: 100,
  passed: true,
  pointsEarned: 100,          // ← server's actual award (0 if capped/dup/network)
  pointsReason: 'quiz_ace' | null,
  pointsLabel: 'Quiz Ace — 100%' | null,
  capReason: 'duplicate' | 'capped' | 'velocity_exceeded' | 'rpc_error' | null,
  hasPassedBefore: false,    // ← for the "already credited" message
  trackCompleted: false,
}
```

Build it from the result of `award_log`:

```ts
const award = await awardPoints(svc, userId, reason, refId, metadata)
return {
  ok: true,
  // ...
  pointsEarned: award.awarded,    // ← from award.awarded, NOT from a hardcoded POINTS_MAP
  capReason: award.capReason,     // ← surfaced so the UI can explain "Daily cap reached"
}
```

**Layer 2 — awaited submit, not fire-and-forget:**

```ts
// ❌ WRONG — popup fires before the network round-trip
try {
    void adminFetch(url, { method: 'POST', body: ... })
} finally {
    setSubmitting(false)
}
setResult(finalResult)
onComplete(finalResult)

// ✅ RIGHT — wait for the server, trust the response
let serverResult: QuizResult | null = null
try {
    const res = await adminFetch(url, { method: 'POST', body: ... })
    const data = await res.json().catch(() => ({}))
    if (!res.ok || !data?.ok) {
        serverError = data?.error || `Server responded ${res.status}`
    } else {
        serverResult = { score: data.score, ..., pointsEarned: data.pointsEarned, ... }
    }
} catch (err) {
    serverError = err?.message
} finally {
    setSubmitting(false)
}
// If the server responded, that wins. Otherwise fall back to local score + 0 points.
const finalResult = serverResult ?? { score: localScore, passed, pointsEarned: 0, capReason: 'network_error' }
setResult(finalResult)
onComplete(finalResult)
```

**Layer 3 — popup must show what actually happened, with explicit messaging for failure modes:**

```tsx
{passed && earned > 0 && (
    <div className="edu-quiz-points-band">
        +{earned} OS pts — {isAce ? 'Quiz Ace — 100%' : 'Quiz Passed'}
    </div>
)}
{passed && earned === 0 && (
    <div className="edu-quiz-points-band is-empty">
        {capReason === 'capped'
            ? 'Daily point cap reached — try again tomorrow.'
            : capReason === 'duplicate'
            ? 'Already credited for this quiz.'
            : capReason === 'network_error'
            ? "Couldn't reach the points server — refresh to check your balance."
            : capReason === 'velocity_exceeded'
            ? 'Points rate limit hit.'
            : alreadyPassed
            ? "Already credited in a previous attempt."
            : 'No points this time.'}
    </div>
)}
```

**The symptom-recognition table — match the bug to the recipe:**

| User reports | Likely cause | Fix |
|--------------|---------------|------|
| "Passed but no points added" | `ref_id` dedupe (Recipe #23) | Use per-attempt ref_id |
| "Popup says +50 but balance didn't change" | Client-side math + fire-and-forget | Use server-authoritative + await |
| "Retries sometimes give points, sometimes don't" | `ref_id` dedupe at the per-resource level | Use per-attempt ref_id |
| "Got 50 points for failing the quiz" | Wrong reason sent to award (`'quiz_pass'` instead of `null`) | Only pass reason if `passed === true` |
| "Passed twice, only first time awarded" | `ref_id = String(quizId)` | Use `attempt.id` |

**Companion rule — when you see `pointsEarned` in a popup that's NOT a real points amount, suspect the popup is wrong, not the ledger.** The ledger is always right (it's the database). The popup can lie easily. Audit every popup that shows a points number and ask: "where does this number come from? What if the server said 0?"

**When this hits again:** any new feature that has a popup / toast / banner showing the user a points value. Run through the three layers:
1. Does the server return the actual credited amount?
2. Does the client await the response and use the server's number?
3. Does the popup show a meaningful message when earned === 0 (with capReason disambiguation)?

## Recipe #25 — Every quiz mount-point must show a completion popup (added Aug 22 2026)

**Symptom:** the user passes a module quiz but no popup appears. The pass is recorded (track completion fires, points are credited in the ledger), the parent page navigates back to the curriculum, but the user gets zero visible feedback that they just completed something and earned points. Compare to lesson micro-quizzes where the popup DOES appear.

**Root cause — `ModuleQuizView` was missing the points popup entirely.** It only called `onPassed()` which navigated away. `LessonViewer` had the popup; `ModuleQuizView` did not.

The two endpoints were inconsistent because the same `QuizRunner` component was mounted in both views, but each parent handler did its own thing with the result. `LessonViewer.onQuizComplete` set `pointsAwarded` state → rendered the popup. `ModuleQuizView.onComplete` just called `onPassed()` → no popup, instant navigation.

**The fix — every quiz mount-point must render the same popup. Either:**

**Option A — move the popup to the `QuizRunner` itself (preferred for new views):**

```tsx
// QuizRunner.tsx — the result panel already shows the points band
{passed && earned > 0 && (
    <motion.div className="edu-quiz-points-band">
        +{earned} OS pts — {isAce ? 'Quiz Ace — 100%' : 'Quiz Passed'}
    </motion.div>
)}
{passed && earned === 0 && (
    <div className="edu-quiz-points-band is-empty">
        {/* explicit reason from capReason */}
    </div>
)}
```

The result panel is rendered BEFORE any navigation. The user sees the points inline. The parent can then either navigate (replacing the result panel) or wait for explicit "Continue" click. Either way the user always sees the result.

**Option B — add the popup to `ModuleQuizView` (matching `LessonViewer`'s pattern):**

```tsx
// ModuleQuizView.tsx — both popup + auto-navigate
const [recentResult, setRecentResult] = useState<QuizResult | null>(null)
const [showPopup, setShowPopup] = useState(false)

const handleQuizComplete = useCallback((result: QuizResult) => {
    setRecentResult(result)
    if (result.passed) setShowPopup(true)
}, [])

const handleContinue = useCallback(() => {
    setShowPopup(false)
    if (recentResult?.passed) onPassed()
}, [recentResult, onPassed])

useEffect(() => {
    if (!showPopup) return
    const t = setTimeout(() => setShowPopup(false), 5000)
    return () => clearTimeout(t)
}, [showPopup])

return (
    <div className="edu-module-quiz-view">
        <QuizRunner quiz={quiz} onComplete={handleQuizComplete} />
        <AnimatePresence>
            {showPopup && recentResult?.passed && (
                <div className="edu-points-popup-anchor">
                    <motion.div className="edu-points-popup" ...>
                        <div className="edu-points-popup-title">{isAce ? 'Perfect Run!' : 'Module Complete'}</div>
                        {earned > 0
                            ? <div className="edu-points-popup-amount">+{earned} OS Points</div>
                            : <div className="edu-points-popup-amount">No points credited</div>
                        }
                        <div className="edu-points-popup-reason">{...}</div>
                    </motion.div>
                </div>
            )}
        </AnimatePresence>
    </div>
)
```

**The rule for any new quiz/feature mount-point:** the popup is part of the completion UX, not the parent navigation. **All four pieces must work:**

1. The result panel (always visible inside `QuizRunner` — it's part of the result view)
2. The popup/celebration (visible above the result panel for 5s OR until user dismisses)
3. The user-initiated dismissal OR auto-dismiss timer
4. The continuation/navigation (only after the user has seen the popup, OR explicit "Continue" button)

If any of these is missing, the user gets a worse experience than they should. Audit checklist for any new view that mounts `QuizRunner`:

- [ ] The mount-point renders the result panel (QuizRunner does this automatically)
- [ ] The mount-point renders a popup on pass
- [ ] The popup has explicit messaging for `pointsEarned === 0` (cap / dup / network / velocity)
- [ ] The popup auto-dismisses or has a Close button
- [ ] Navigation only happens AFTER the popup is dismissed (so the user actually sees it)

**The companion rule — match the parent's intent with the popup's duration:** if the parent is going to navigate away on pass (e.g. click "Continue" → back to curriculum), the popup should be visible BEFORE navigation, with the navigation triggered by the user's click on Continue. If the parent is staying on the page (e.g. module quiz with retry), the popup should auto-dismiss after a few seconds.

**When this hits again:** any new view that mounts `QuizRunner` or any feature with a "completion + reward" pattern. The recipe: 1) audit what the parent does with the result, 2) check whether the user gets visible feedback, 3) if no — copy the popup pattern from this recipe.
