# Aug 22 2026 — Server-authoritative points, enum status, orphan-email class (drop-in for SKILL.md merge)

This file is a curated delta for the autonomous SKILL.md curator.
The patcher refused direct SKILL.md writes ("SKILL.md not loaded in this
review turn" / "dedup cache says unchanged"). Drop these three recipes into
SKILL.md right before the "What I deliberately did NOT do" section,
just after `references/2026-08-22-quiz-and-points-popup.md`'s Recipe #25
which lives in the same skill.

## Recipe #20 — Server-authoritative points for `award_log` and quiz-attempt routes (added Aug 22 2026)

**Symptom:** the user passes a quiz and sees "+50 OS Points" in the popup, but their dashboard balance didn't change. Or: they pass a quiz for the FIRST time, get the popup, then later fail and retake, get the popup again with "+50" — but they were never credited a second time. Or: the level-up animation triggers but no email arrives (the level-up route never even runs the email side-effect).

**Root cause (multiple variants of the same bug class):**

1. **Client-side math, server is the source of truth** — the original `award_log` route didn't return `pointsEarned` or `capReason`, so the QuizRunner computed `pointsEarned = 50` from a hardcoded `POINTS_MAP` literal. If a daily cap fired server-side, the user got a "+50" popup but the actual ledger was 0.
2. **Idempotent ref_id kills retries** — `ref_id = String(quizId)` meant `award_log` deduped by `(user_id, reason, ref_id)`. Retrying the same quiz returned `{ok: false, reason: 'duplicate'}` silently.
3. **Email side-effects missing entirely** — `award_log` returned `leveled_up: true` when points crossed a level boundary, but `/api/app/award` discarded that info — no email was ever sent. Three email templates (`osLevelUp.ts`, `osPointsMilestone.ts`, `engineUnlock.ts`) were defined but never called from any code path.

**The fix — server returns the canonical response shape, route fires the side-effects:**

```ts
// src/app/api/app/award/route.ts — POST handler
const result = (data ?? {}) as {
  ok?: boolean
  amount?: number
  new_total?: number
  old_level?: number
  new_level?: number
  leveled_up?: boolean
}
if (result.ok && result.leveled_up) {
  // 1. Fetch user record via /auth/v1/admin/users/{id} (NOT PostgREST
  //    on auth.users — anon can't read it)
  const adminRes = await fetch(`${SUPABASE_URL}/auth/v1/admin/users/${userId}`, {
    headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}` },
    cache: 'no-store',
  })
  const adminData = await adminRes.json()
  const meta = adminData.user_metadata ?? {}
  const email = adminData.email

  // 2. Send the level-up email — sending module checks opt-out flags
  //    from user_metadata:
  //      notifications_email === false → suppress all
  //      notifications_milestones === false → suppress milestones
  //    If the email side-effect fails (Resend API error, network,
  //    invalid template), the points are still awarded — log and
  //    continue. The email is best-effort.
  if (email) {
    const { sendOSLevelUpEmail } = await import('@/lib/emails/osLevelUp')
    await sendOSLevelUpEmail({
      email, userId,
      oldLevel: result.old_level ?? 0,
      newLevel: result.new_level ?? 0,
      newTotal: result.new_total ?? 0,
    }, meta).catch(err => {
      console.error('[os/award] level-up email failed:', err)
    })
  }
}
```

```ts
// src/app/api/education/quiz/[id]/attempt/route.ts — POST handler
const attemptRes = await svc.from('quiz_attempts').insert({
  user_id: auth.userId,
  quiz_id: quizId,
  score,
  passed,
  // NO attempt_no column — that migration never landed. Just insert
  // and let the row id be the unique dedupe key for points.
  answers_json: { answers: body.answers, perQuestion },
}).select('*').single()

// Award with the ATTEMPT'S UUID, not the quiz id — so retries
// always credit points, never silently dedupe.
const awardResult = await svc.rpc('award_log', {
  p_user_id: auth.userId,
  p_amount: pointsReason === 'quiz_ace' ? 100 : 50,
  p_reason: pointsReason,
  p_ref_id: String(attemptRes.data.id),  // ← per-attempt UUID
  p_metadata: { ... },
})

// Read back the actual award result (NOT client-computed)
return NextResponse.json({
  ok: true,
  attemptId: attemptRes.data.id,
  attemptNumber: previousAttempts.length + 1,
  score, passed,
  correct_count, total,
  per_question: perQuestion,
  pointsEarned: awardResult?.ok ? awardResult.amount : 0,
  pointsReason: pointsReason ?? null,
  pointsLabel: pointsReason ? (pointsReason === 'quiz_ace' ? 'Quiz Ace — 100%' : 'Quiz Passed') : null,
  capReason: awardResult?.reason ?? null,
  hasPassedBefore,
  trackCompleted,
})
```

**Client uses the server response verbatim — never recomputes points:**

```tsx
// src/components/education/QuizRunner.tsx
const [res] = await adminFetch(`/api/education/quiz/${quiz.id}/attempt`, {
  method: 'POST',
  body: JSON.stringify({ answers: ... }),
})
const data = await res.json()
// data.pointsEarned is server-truth (0 if capped/dup/network failure)
// data.capReason tells the user WHY they got 0 if they did
// data.hasPassedBefore tells the UI whether to say "first time"
//   or "Already credited in a previous attempt"
```

**The diagnostic for "client computed, server disagreed":**

```bash
# Compare the popup popup amount to the actual ledger
grep -E "POINTS_MAP|pointsEarned" src/components/education/QuizRunner.tsx
# If the client has a hardcoded POINTS_MAP literal, it's wrong.
# Replace with a `pointsEarned` field from the server response.
```

```bash
# Check if the email side-effect is wired
rg "sendOSLevelUpEmail\|sendEngineUnlockEmail\|sendOSPointsMilestoneEmail" src/
# Should find call sites in /api/app/award, /api/education/lesson/..., etc.
# If only the email templates are listed with no callers, the
# side-effects are orphaned (the Aug 22 2026 bug).
```

**Rule for any new award route:**

1. The route reads `result = data` from the `award_log` RPC and surfaces ALL fields — `old_level`, `new_level`, `leveled_up`, `amount`, `balance_after` — to the client. Never compute locally.
2. Every distinct award unit (per-attempt, per-bonus, per-event) uses its own UUID as `ref_id`. Never use the parent entity's id (the quiz id, the lesson id, the user id) — those dedupe across retries.
3. If the award has a side-effect (level-up email, badge notification, leaderboard update), the side-effect lives in the same route that triggers the award. Cron jobs and webhook listeners are fallback paths, not primary ones.
4. The side-effect's failure doesn't fail the award. Log + continue.

**When this hits again:** any new feature that awards points via `award_log`. Default to: route returns server-authoritative `pointsEarned` + `capReason` + `hasPassedBefore`; client uses those verbatim; side-effect (email, push, badge) fires from the route, not from a cron.

## Recipe #21 — `telegram_trader_signals.status` enum: `completed` not `closed` (added Aug 22 2026)

**Symptom:** the trader clicks "Close" on a signal to mark it as closed. The popup disappears, points + badge update, all looks good — but `quiz_attempts` shows the new attempt was recorded with `status = 'closed'`, and the very next step fails with:

```
new row for relation "telegram_trader_signals" violates check constraint "telegram_trader_signals_status_check"
```

OR (more silently) the close is recorded but the user's profile doesn't reflect it because the `UPDATE` failed.

**Root cause:** the CHECK constraint on `public.telegram_trader_signals.status` allows only:

```sql
CHECK (status IN ('live', 'tp1_hit', 'tp2_hit', 'tp3_hit', 'tp4_hit', 'sl_hit',
                'completed', 'expired', 'cancelled'))
```

`'closed'` is NOT in the enum. The original "close signal" route did `.update({ status: 'closed' })` which throws on every call. The user thinks they're saving, the server rejects the write.

**The fix — use `'completed'` for manual closes (per the canonical CHECK enum):**

```ts
// CORRECT — 'completed' is in the enum, status flips, downstream views see it
.update({
  status: 'completed',
  closed_at: new Date().toISOString(),
  close_price: closePrice,
  // (close_price + closed_at columns added via migration 202608220001)
})
.eq('id', signalId)

// Surface 'closed' semantics to clients in the response shape, separate
// from the DB column. The frontend can call it "closed" while the DB
// stores "completed" — that's fine; the column is the source of truth
// for status strings, the API response is the source of truth for
// client-facing copy.
return NextResponse.json({
  ok: true,
  signal: { ...updated },
  status_label: 'closed',  // ← client-facing
})
```

**Why not migrate the enum to add `'closed'`?** Adding a new enum value is a forward-compatible migration, BUT every view, every materialized aggregate, every status filter in the codebase that does `WHERE status = 'completed'` would silently exclude `status = 'closed'` rows. The blast radius is too large for a one-line UX fix. Better to keep the canonical CHECK enum unchanged and surface the semantic mapping at the API boundary.

**The diagnostic:**

```sql
-- Always check the CHECK constraint before writing status updates
SELECT conname, pg_get_constraintdef(oid)
FROM pg_constraint
WHERE conrelid = 'public.telegram_trader_signals'::regclass
  AND contype = 'c';
```

The constraint definition is the ground truth. Match your `.update({ status: ... })` values against it.

**When this hits again:** any new signal-status transition. Map your semantic transition name to the closest enum value: `'closed' → 'completed'`, `'paused' → 'cancelled'` (if you want to pause), `'live' → 'live'` (re-arm after close). Don't migrate the enum to add semantic aliases; map at the API boundary.

## Recipe #22 — Orphan email-module class: defined-but-never-called (added Aug 22 2026)

**Symptom:** the user says "I leveled up to OS 2 but I didn't get an email confirmation." The level-up animation fires correctly in-app. The `award_log` SQL function returns `leveled_up: true`. But no email goes out.

**Root cause — the email template exists in `src/lib/emails/<thing>.ts` but no production code calls it.** Specifically, in this session we found four orphan email modules:

- `src/lib/emails/osLevelUp.ts` — `sendOSLevelUpEmail()` (0 callers — fixed in this commit)
- `src/lib/emails/osPointsMilestone.ts` — `sendOSPointsMilestoneEmail()` (0 callers — the docstring claims to do opt-out check, the code doesn't)
- `src/lib/emails/engineUnlock.ts` — `sendEngineUnlockEmail()` (0 callers)
- `src/lib/emails/rankUpgrade.ts` — `sendRankUpgradeEmail()` (0 callers)

Each template was built speculatively by a previous session. The author never wired up the call site. The route that triggers the event (`/api/app/award`, `/api/education/quiz/.../attempt`, etc.) silently omits the email side-effect.

**The diagnostic — find orphan email modules:**

```bash
# Find every email-sending function in src/lib/emails/
rg "export (async )?function send" src/lib/emails/ | head -20

# For each, find call sites
for fn in $(rg -o "send[A-Z][A-Za-z]+Email" src/lib/emails/ | sort -u); do
  echo "=== $fn ==="
  rg "\b$fn\b" src/ --files-with-matches | grep -v 'src/lib/emails/' | head -5
done

# If the output for a function is EMPTY, the email is orphan
```

**The audit recipe — every email module should be wired up:**

```bash
# Get the list of send-functions
rg -o "export (async )?function send[A-Z][A-Za-z]+Email" src/lib/emails/ -r \
  | awk '{print $NF}' | sed 's/[(:].*//' | sort -u > /tmp/email-senders.txt

# Get the list of caller files (outside src/lib/emails/)
rg -l "import.*emails/" src/ | grep -v 'src/lib/emails/' > /tmp/email-callers.txt

# Cross-check: every email sender should have at least one caller
for fn in $(cat /tmp/email-senders.txt); do
  callers=$(rg "\b${fn}\b" src/ -l | grep -v 'src/lib/emails/' | wc -l)
  if [ "$callers" -eq 0 ]; then
    echo "ORPHAN: $fn has no callers outside src/lib/emails/"
  fi
done
```

**The fix — wire up the email side-effect in the route that triggers the event:**

```ts
// src/app/api/app/award/route.ts — POST handler
if (awardResult.ok && awardResult.leveled_up) {
  // Fetch the user record via /auth/v1/admin/users/{id} to get
  // email + opt-out metadata.
  const adminData = await fetch(`${SUPABASE_URL}/auth/v1/admin/users/${userId}`, {
    headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}` },
    cache: 'no-store',
  }).then(r => r.json())

  const meta = adminData.user_metadata ?? {}
  const email = adminData.email

  // Honor opt-out flags from user_metadata
  if (email && meta.notifications_email !== false
            && meta.notifications_milestones !== false) {
    const { sendOSLevelUpEmail } = await import('@/lib/emails/osLevelUp')
    await sendOSLevelUpEmail({ ... }, meta).catch(err => {
      // Log and continue — the points are already awarded
      console.error('[os/award] level-up email failed:', err)
    })
  }
}
```

**When this hits again:** every new email module needs an audit pass for orphans. Run the audit recipe above once per quarter and wire up anything flagged ORPHAN. A defined-but-never-called email is the most expensive kind of bug — it shipped silently broken for weeks/months.

**Companion rule — every email sender has at least one e2e test.** If a sender is wired up, its e2e covers the trigger. If it's orphan, it should be flagged in the audit. Either way, the test suite catches regressions.
