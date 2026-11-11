# Recipe — RPC must return a "side-effect fired" signal so the API can fire emails at the right moment (added Aug 24 2026)

## The class of problem

When a SQL RPC triggers a side effect (flip a boolean, send a notification,
insert a row elsewhere), the API that called the RPC often wants to
chain another side effect of its own (send an email, broadcast a
push, write an audit log). The naive approach — "always run the
side effect after every step" — fires duplicates. The correct approach
is for the RPC to surface **what changed during this call** so the
API can branch on it.

## Concrete instance — `app_complete_onboarding_step` and the welcome email

The user completes their 7th onboarding step. The trigger
`app_onboarding_step_changed` fires and flips `onboarding_complete=true`.
We want to send the user a "Welcome to the trading floor" email —
**but only the first time** (idempotent), and only when the flip
happened in THIS call, not on a re-attempt of a step that doesn't
flip the master flag.

Pre-fix the RPC returned:
```json
{ "ok": true, "completed": true }
```

The API couldn't tell whether the 7th step had just flipped
onboarding_complete, or the user was re-flipping step #5. So either:
- (A) Always send the email → duplicate emails on retries
- (B) Re-query the lifecycle after every step to check if
      onboarding_complete just flipped → N+1 round trips

The fix is for the RPC to surface the flip status:

```sql
-- supabase/migrations/202608240002_complete_step_returns_flip.sql
CREATE OR REPLACE FUNCTION public.app_complete_onboarding_step(
    p_user_id UUID,
    p_step_key TEXT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_status TEXT;
    v_completed_at TIMESTAMPTZ;
    v_master_before BOOLEAN;
    v_master_after BOOLEAN;
    v_flip TEXT := 'not_yet';
    v_required_count INTEGER := 7;
    v_completed_count INTEGER;
BEGIN
    -- ... existing idempotent step check ...
    IF v_status = 'completed' THEN
        RETURN jsonb_build_object('ok', true, 'already_completed', true);
    END IF;

    -- Snapshot the master flag BEFORE the upsert
    SELECT onboarding_complete INTO v_master_before
    FROM public.user_accounts WHERE id = p_user_id;

    -- The trigger fires here (it may flip the master flag)
    INSERT INTO public.user_progress (...)
    ON CONFLICT (user_id, step_key) DO UPDATE ...;

    -- Read the master flag AFTER the trigger
    SELECT onboarding_complete INTO v_master_after
    FROM public.user_accounts WHERE id = p_user_id;

    -- Compute the flip status:
    -- 'just_now' = the trigger flipped during THIS call
    -- 'already'  = onboarding was already complete before
    -- 'not_yet'  = the master flag is still false (intermediate step)
    IF v_master_after IS TRUE AND COALESCE(v_master_before, FALSE) = FALSE THEN
        v_flip := 'just_now';
    ELSIF v_master_after IS TRUE THEN
        v_flip := 'already';
    ELSE
        v_flip := 'not_yet';
    END IF;

    -- Also surface completed_count for the welcome email to know
    -- "you finished step 7 of 7"
    SELECT COUNT(*) INTO v_completed_count
    FROM public.user_progress
    WHERE user_id = p_user_id
      AND step_key IN ('profile_basics', 'accent_theme', 'risk_disclaimer',
                       'connect_broker', 'link_broker', 'enable_push', 'walkthrough')
      AND status = 'completed';

    RETURN jsonb_build_object(
        'ok', true,
        'completed', true,
        'onboarding_complete_flip', v_flip,
        'completed_count', v_completed_count,
        'required_count', v_required_count
    );
END;
$$;
```

API side:
```ts
const { data, error } = await svc.rpc('app_complete_onboarding_step', {
    p_user_id: auth.userId,
    p_step_key: stepKey,
})
if (error) { /* handle */ }

if ((data as any)?.onboarding_complete_flip === 'just_now') {
    // Fire the welcome email — this call JUST flipped the master flag
    await sendOnboardingCompleteEmail({...})
}
```

## The general pattern

When designing a SQL function that triggers a side effect, ask:
"does the API caller need to know **what just changed in this
specific call** to decide whether to do something else?"

If yes:
1. Add an explicit field to the RPC's return shape that encodes the
   side-effect state.
2. Pick a canonical name (e.g. `onboarding_complete_flip`,
   `leveled_up`, `notification_sent`, `email_dispatched`).
3. Document the field's possible values in a comment in the function
   body.
4. Mirror the same field in any client-side reducer that the API
   feeds.

Common fields to add (and what they encode):
- `onboarding_complete_flip` (just_now | already | not_yet) — was
  the master boolean flipped during this call
- `leveled_up` (true | false) — did this award push the user over a
  level threshold
- `milestone_crossed` (number | null) — which milestone was crossed
  by this award
- `notification_dispatched` (true | false) — was the email/SMS
  actually sent (vs. opted out)
- `points_balance_after` (number) — new total after the award

## The test that catches a missing field

```js
// After each step POST, the response must contain the side-effect field
const r = await post('/api/onboarding/complete-step', { step_key: 'walkthrough' })
assert(r.data.onboarding_complete_flip === 'just_now', 'expected just_now on 7th step')
assert(r.data.completed_count === 7, 'expected 7 completed')
assert(r.data.points_awarded?.amount > 0, 'expected welcome-email points awarded')
```

## When this hits again

Any time you write a SQL function whose side effect (insert into
another table, flip a flag, send a notification) could reasonably
trigger a follow-on action in the API layer. The pattern:

1. Define the side effect's possible states as an enum string
   (`'just_now' | 'already' | 'not_yet'` or similar)
2. Have the function set the enum based on a before/after snapshot
3. Return the enum in the response
4. The API branches on the enum — `if (flip === 'just_now') fireEmail()`

This is cleaner than a "re-query after the call" pattern (1 extra
round trip) and safer than "always fire the side effect" (duplicate
emails / duplicate notifications).

## Companion: don't `SET NEW.<x> = TRUE` in a trigger when the SQL state is the source of truth

The natural place to encode the "side effect fired" state is the
trigger body. But triggers run inside SQL, not the API. The trigger
can:

- Set a column on the affected row (e.g. `onboarding_complete=true`)
- Insert into a log table (e.g. `app_milestone_log`)
- Both

The API cannot observe trigger-internal state. So **the RPC must
do the before/after snapshot itself** to detect what the trigger did
to the row. Don't try to encode "side effect fired" inside the
trigger and have the API read it — there's no inter-call state.

## Real result on prod

After the migration + API update:
- Welcome email fires **exactly once** when the 7th step is
  completed by a fresh user
- Re-completion of step 5 (e.g. user re-uploads avatar) does NOT
  fire a duplicate welcome email (`flip === 'not_yet'`)
- /api/onboarding/complete-step stays idempotent — calling it on
  a fully-onboarded user returns `already_completed: true` and does
  not refire the email
