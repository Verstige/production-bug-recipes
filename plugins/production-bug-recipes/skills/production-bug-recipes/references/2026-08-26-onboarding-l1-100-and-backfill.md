# Aug 26 2026 — Onboarding L1 ladder: 50 → 100 pts + getLevelInfo L0 ring bug + wizard-points backfill

Session drop-in for `this skill's SKILL.md`.

This session shipped the **second half of today's onboarding work**:
after Round 9 set L1=50 pts (so finishing the wizard unlocked
ENGINE_A), the user said L1=50 was too easy — they wanted a real
milestone. L1 was raised to 100 pts. Then a separate bug was
caught on a real walkthrough: a user with 12 pts saw "100% to
L1" on the level ring, and they reported they hadn't been credited
for the wizard steps they completed before Round 9 wired them
up. Both got fixed.

| Commit | Deployed as | What it does |
|---|---|---|
| `dfef1fa9` | `ab4fc19a` | L1: 50 → 100 pts; ladder shifted up to keep the same exponential curve; revoke ENGINE_A from users who got it under Round 9's brief L1=50 window |
| `e1418fca` | `b616863f` | `getLevelInfo(0)` returns 100% (was 0%) — explicit L0 case in the loop; SQL migration to backfill wizard points for users whose completed steps predate Round 9 |

The user ran both SQL migrations (`202608260010_l1_at_100_pts.sql`
and `202608260011_backfill_wizard_points.sql`) by hand in the
Supabase SQL Editor.

## The new recipes this session

- **Recipe #50** — `getLevelInfo` returns 100% at any L0 points
  count because `LEVEL_ANCHORS` starts at L=1 and the loop never
  matches `cappedLevel === 0`. `floor` and `nextFloor` both stay
  at 0; `span = max(1, 0)` = 1; `pct = ((safe - 0) / 1) * 100` = 100.
  Always handle the "no anchor for this level" edge case
  explicitly when the anchor table starts above level 0.
- **Recipe #51** — Adding new `pointsReward` to wizard steps in a
  config file does NOT retroactively credit users who already
  completed those steps before the change. The `complete-step`
  server route awards `award_log` only on its own successful call;
  it has no memory of "this step was finished last week without a
  reward." Users see "I only got X pts for completing everything"
  and the recent-activity feed underreports. Always ship a
  matching backfill migration in the same release.
- **Recipe #52** — The TS ladder (`LEVEL_ANCHORS`) and the SQL
  function `app_level_for()` must be migrated in pairs. Aug 26
  Round 9b shows the cost of skipping: a TS-only change made the
  UI ring read the new ladder, but `app_auto_unlock_engines` SQL
  still used the old ladder, so ENGINE_A didn't unlock at 100 pts
  even though the cache said L1. The SQL function fires
  automatically inside `award_log` (called by every reward path),
  so any ladder change without a paired migration leaves engine
  unlock out of sync. Companion to Recipe #47 from the earlier
  session drop-in.
- **Recipe #53** — When changing a ladder threshold that gates
  engine auto-unlocks, **revoke the unlocks for users who got
  them under the old threshold**. In Round 9 → 9b, ENGINE_A unlocked
  the moment a user crossed 50 pts. After raising L1 to 100, any
  user under 100 pts who got ENGINE_A had it for the wrong reason —
  they hadn't actually earned it. `DELETE FROM engine_unlocks
  WHERE engine_id = 'X' AND user_id IN (SELECT id FROM
  user_accounts WHERE points < new_threshold)` plus matching
  `engine_unlock_log` deletes so the trigger can re-fire
  cleanly when the user crosses the new threshold legitimately.
  `ON CONFLICT DO NOTHING` on the unlock table otherwise blocks
  the legitimate re-unlock.

## Recipe #50 — `getLevelInfo` returns 100% at any L0 count (added Aug 26 2026)

**Symptom:** a user with 12 pts, sitting at L0, sees the level ring
read "100% to L1". Same user at 99 pts: also "100% to L1". Same
user at 0 pts: also "100% to L1". The ring is essentially decorative
at L0.

**Root cause:** `LEVEL_ANCHORS` is an array of `{ L: number; pts: number }`
starting at L=1 (and going up). When `cappedLevel === 0`, the
anchor-finding loop in `getLevelInfo`:

```ts
for (let i = 0; i < LEVEL_ANCHORS.length; i++) {
    if (LEVEL_ANCHORS[i].L === cappedLevel) {
        floor = LEVEL_ANCHORS[i].pts;
        nextFloor = ...;
        break;
    }
}
```

never matches. `floor` and `nextFloor` both stay at 0 (their
declared initial values). Then `span = max(1, 0)` = 1, and
`pct = ((safe - 0) / 1) * 100` = 100, regardless of how big
`safe` actually is.

The same trap catches any level table that doesn't include an
entry for the user's current level. The most common form is
"the ladder starts above level 0" — and you only realize it on
the first L0 user.

**The fix — handle the no-anchor case explicitly:**

```ts
if (cappedLevel === 0) {
    floor = 0;
    nextFloor = LEVEL_ANCHORS[0]?.pts ?? 100;
} else {
    // original loop unchanged
}

const span = Math.max(1, nextFloor - floor);
const pct = cappedLevel >= MAX_LEVEL
    ? 100
    : Math.min(100, ((safe - floor) / span) * 100);
```

**Companion rule (always test):** when the anchor table has a
gap at the bottom (starts at L=1, L=5, etc.), test the function
at every gap level — `getLevelInfo(0)`, `getLevelInfo(99)`,
`getLevelInfo(L_min - 1)`. The bug only shows up at those exact
inputs.

## Recipe #51 — Adding `pointsReward` does not backfill prior completions (added Aug 26 2026)

**Symptom:** a user reports "I only got X pts for completing
onboarding" but their `user_progress` table has all
four required steps marked `completed`. The recent-activity feed
shows 1-2 rows instead of 4. The `points_ledger` has only the
pointsReward rows that were active when each step was saved.

**Root cause:** server-side `complete-step` route only awards
points in the moment of the click:

```ts
if (step.pointsReward) {
    const amt = pointsFor(step.pointsReward)
    if (amt > 0) {
        await svc.rpc('award_log', { ... })
    }
}
```

If `step.pointsReward` was `undefined` when the user clicked,
the route returns 200 OK without awarding. Later, when you wire
up `pointsReward: 'walkthrough'`, **the server has no idea which
users already finished the step before the wiring**. There's no
notification to "complete missing rewards." Users are silently
under-credited.

**The fix — ship a matching backfill migration whenever you add
new `pointsReward` mappings.** Pattern from migration
`202608260011_backfill_wizard_points.sql`:

```sql
DO $$
DECLARE v_user_id UUID;
BEGIN
    FOR v_user_id IN
        SELECT user_id
        FROM public.user_progress
        WHERE step_key = 'accent_theme'
          AND status = 'completed'
          AND NOT EXISTS (
              SELECT 1 FROM public.points_ledger
              WHERE user_id = public.user_progress.user_id
                AND reason = 'accent_theme'
                AND ref_id = 'onboarding::accent_theme::' || public.user_progress.user_id::text
          )
    LOOP
        PERFORM public.award_log(
            v_user_id, 10, 'accent_theme',
            'onboarding::accent_theme::' || v_user_id::text,
            jsonb_build_object('kind', 'onboarding_backfill', 'migration', '202608260011')
        );
    END LOOP;
END $$;
```

Key details:

1. **`NOT EXISTS` guard against the ref_id** — `award_log()` has its
   own dedupe on `(user_id, reason, ref_id)`, but the guard
   here makes the intent explicit at the SQL layer.
2. **Match ref_id format the route uses** — `onboarding::<step_key>::<user_id>`.
   If you change one without the other, the dedupe path is
   silently broken.
3. **Always re-run `app_auto_unlock_engines` for users who just
   crossed an L-threshold** so engine unlocks fire correctly.
4. **Recompute cached `user_accounts.points` and `app_level`** at
   the end.

**Companion rule:** any time you change a `pointsReward` mapping,
check `git log` for the last time that mapping was `undefined`.
If any user completed the step in the gap, ship a backfill
migration in the same commit.

## Recipe #52 — TS ladder + SQL `app_level_for` must migrate in pairs (added Aug 26 2026)

**Symptom:** change L1 from 500 to 50 in TS `LEVEL_ANCHORS`, ship
the change, deploy. The UI ring shows the new ladder. But
`app_auto_unlock_engines` SQL still uses the old ladder. A user
hits 50 pts and the UI says L1 — but ENGINE_A doesn't unlock
because the SQL engine thinks they're at L0 still.

**Root cause:** the engine auto-unlock check is in SQL:
`app_auto_unlock_engines(p_user_id, p_total_points)` calls
`app_level_for(p_total_points)`. If `app_level_for` still returns
0 for `p_total_points=50`, the SQL function won't see the user
as L1 and won't insert ENGINE_A into `engine_unlocks`. TS
and SQL are two parallel implementations of the same ladder;
neither knows the other changed.

**The fix — pair ladder changes with a SQL migration.** Pattern
from `202608260009_onboarding_points_and_l1.sql` and
`202608260010_l1_at_100_pts.sql`:

```sql
DROP FUNCTION IF EXISTS public.app_level_for(BIGINT);
CREATE OR REPLACE FUNCTION public.app_level_for(p_total BIGINT)
RETURNS INTEGER
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
    v_total BIGINT := GREATEST(0, p_total);
BEGIN
    IF v_total >= 1000000 THEN RETURN 20;
    ELSIF v_total >= 800000 THEN RETURN 19;
    -- ... full ladder
    ELSIF v_total >= 100 THEN RETURN 1;  -- <-- new threshold
    ELSE RETURN 0;
    END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.app_level_for(BIGINT) TO service_role, anon, authenticated;

UPDATE public.user_accounts
SET app_level = public.app_level_for(COALESCE(points, 0)),
    updated_at = now()
WHERE app_level IS DISTINCT FROM public.app_level_for(COALESCE(points, 0));
```

Then end the migration with `NOTIFY pgrst, 'reload schema';` so
PostgREST re-evaluates the function catalog.

**Companion rule:** any time TS `LEVEL_ANCHORS` changes, the
matching SQL migration must include `DROP/RECREATE
public.app_level_for()`. The migration is short — copy/paste the
ladder from TS into a `CASE` or `IF/ELSIF` block and the SQL
function stays in sync.

## Recipe #53 — Engine unlock revocation on threshold change (added Aug 26 2026)

**Symptom:** Round 9 set L1=50, so users who completed onboarding
(50 pts) got ENGINE_A auto-unlocked. Round 9b raised L1 to 100
because the user wanted a real milestone. Now those same users
have ENGINE_A unlocked at 50 pts, but they shouldn't — the new
threshold is 100. They got the reward for the wrong reason.

**Root cause:** `engine_unlocks` is an append-only-ish table
with `ON CONFLICT (user_id, engine_id) DO NOTHING`. Once a row
is inserted, the legitimate re-unlock on the new threshold won't
fire. Same with `engine_unlock_log`.

**The fix — revoke the unlocks for users under the new threshold:**

```sql
DELETE FROM public.engine_unlocks
WHERE engine_id = 'ENGINE_A'
  AND user_id IN (
      SELECT id FROM public.user_accounts
      WHERE COALESCE(points, 0) < 100
  );

DELETE FROM public.engine_unlock_log
WHERE engine_id = 'ENGINE_A'
  AND user_id IN (
      SELECT id FROM public.user_accounts
      WHERE COALESCE(points, 0) < 100
  );
```

The user's points are preserved (50 pts still in `points_ledger`).
They just need another 50 pts before ENGINE_A unlocks again.

**Then re-fire the engine auto-unlock for anyone who legitimately
crossed the new threshold:**

```sql
DO $$
DECLARE
    v_user_id  UUID;
    v_points   BIGINT;
BEGIN
    FOR v_user_id, v_points IN
        SELECT id, COALESCE(points, 0)
        FROM public.user_accounts
        WHERE COALESCE(points, 0) > 0
    LOOP
        PERFORM public.app_auto_unlock_engines(v_user_id, v_points);
    END LOOP;
END $$;
```

`app_auto_unlock_engines` is idempotent (the INSERT has
`ON CONFLICT DO NOTHING`), so this is safe to re-run.

**Companion rule:** any time you change a ladder threshold that
gates engine auto-unlocks, audit who got the unlock under the
old threshold and revoke it for users who fall under the new
threshold. The user's points are still their reward history;
the engine unlock is the consequence.

## Session summary

| Round | Commit | What |
|---|---|---|
| 9b | `dfef1fa9` | L1: 50 → 100, revoke ENGINE_A for under-threshold users |
| 10 | `e1418fca` | `getLevelInfo` L0 ring fix + wizard-points backfill |

The user's exact sequence of requests this session, in order:

1. "Make L1 = 100 pts so the user has to earn 50 more" → Round 9b
2. "I'm at level 0 with 100% to L1, not accurate, I don't see
   the points added for completing onboarding" → Round 10

The second one was two bugs in one report:
- The ring at 100% was Recipe #50 (L0 edge case).
- The missing wizard points was Recipe #51 (pre-Round-9
  completions weren't retroactively credited).

Both fixes shipped in a single commit because they were caught
together on a real walkthrough. Round 9b's revoke-ENGINE_A
(SQL migration) preserved the user's points while changing
the unlock criteria, which was the right outcome — they kept
the 50 pts they earned, just don't get ENGINE_A for it.
