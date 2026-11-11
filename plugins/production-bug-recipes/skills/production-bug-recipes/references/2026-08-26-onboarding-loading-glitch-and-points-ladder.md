# Aug 26 2026 — Onboarding dashboard: cross-account broadcast glitch, loading-state race, OnboardingHero removal, 50-pt wizard + L1 = 50 pts

Session drop-in for `this skill's SKILL.md`.

This session shipped **four commits** that converted the wizard end of
the onboarding flow from "two bugs deep in the React tree" to "server-
authoritative everywhere, real user-visible points ladder, L1 reachable
without grinding". Closes **Bug A's cousin** (cross-account glitch
during onboarding) and **Bug E** (black "Loading…" trap).

| Commit | Deployed as | What it does |
|---|---|---|
| `dfca8d4b` | `e2b11ef7` | per-user realtime channel + 8s loading safety net + remove OnboardingHero from dashboard top |
| `251677a2` | `b6f59d02` | L1 = 50 pts, accent_theme + risk_disclaimer + walkthrough each award points, totaling 50 pts for the wizard |

Plus one new SQL migration (`202608260009_onboarding_points_and_l1.sql`)
that mirrors the TS ladder into the SQL `app_level_for()` and upserts the
three new reasons into `app_point_reasons`. The user ran it by hand in
the Supabase SQL Editor.

## The new recipes this session

- **Recipe #45** — Supabase Realtime broadcast on a shared channel
  reaches every subscriber, even across users. When User A's
  onboarding write fires `app-refresh-profile`, User B's
  dashboard sees a re-render storm. Fix: scope the channel name
  per-user (`profile-refresh-${userId}` on both server and client).
- **Recipe #46** — `setLoading(true)` on mount with no global timeout
  leaves the dashboard stuck on a "Loading…" black screen if any
  downstream Supabase REST call hangs (IndexedDB lock contended,
  Supabase REST slow, JWT just rotated). Fix: a `finally { setTimeout(
  () => setLoading(false), 8000) }` belt-and-braces safety net.
  Companion to Recipe #18 (hard-reset loading state via setTimeout)
  but applied at the `refreshProfile` level rather than per-fetch.
- **Recipe #47** — When the TS ladder (`LEVEL_ANCHORS`) is the source
  of truth for the frontend AND SQL `app_level_for()` is the source of
  truth for engine auto-unlock, any change to the ladder requires a
  paired SQL migration. A TS-only change leaves the SQL function stale
  and engine unlock breaks. Always migrate in pairs.
- **Recipe #48** — The 4-step wizard has a "total reward" that's the
  user-visible promise of the experience. If the steps don't
  individually award points summing to the promise, the user
  reports "I only got X pts for completing everything" and
  abandons. Plan the rewards matrix at the same time you plan the
  step list, not as a follow-up. Aug 26 spec: 10+10+10+20 = 50 pts
  and L1 = 50 pts so finishing the wizard = L1 = ENGINE_A unlocked.

## Recipe #45 — Supabase Realtime broadcast on a shared channel reaches every subscriber (added Aug 26 2026)

**Symptom:** a real-user walkthrough on a fresh test account. The user
opened two browsers side by side: Account A's wizard on browser 1,
Account B's already-onboarded dashboard on browser 2. Every time
Account A completed an onboarding step, Account B's dashboard
glitched — re-rendered, refreshed state, "Loading…" flash. Account
B was on a different browser, different session, different
user_id. The two accounts had no shared state in the app. But
Account B's dashboard still reacted to Account A's writes.

**Root cause:** the Supabase Realtime broadcast on channel
`profile-refresh` was a **shared global channel**, not scoped per
user. Every browser session subscribed to it. Every server-side
`channel.send({ event: 'app-refresh-profile', ... })` reached
every connected client. The user's `UserContext.refreshProfile()`
ran for the LOCAL user, which doesn't change local state — but the
React re-render still happens, which is what the user perceives
as "glitching".

```ts
// 9 places in the server-side routes fired this:
//   src/app/api/education/terminology/seen/route.ts
//   src/app/api/education/quiz/[id]/attempt/route.ts (2x)
//   src/app/api/education/lesson/[id]/progress/route.ts (2x)
//   src/app/api/app/award/route.ts
//   src/app/api/app/streak/route.ts
//   src/app/api/onboarding/complete-step/route.ts
//   src/app/api/onboarding/risk-ack/route.ts
//   src/app/api/onboarding/profile/route.ts
await svc.channel('profile-refresh')
    .send({ type: 'broadcast', event: 'app-refresh-profile', payload: {} })
```

```ts
// src/context/UserContext.tsx subscribed:
const channel = supabase.channel('profile-refresh')
channel.on('broadcast', { event: 'app-refresh-profile' }, () => {
    void refreshProfile()
})
channel.subscribe()
```

Supabase Realtime channels are name-scoped, but the names are NOT
user-scoped by default. Two different users on two different
browsers will both subscribe to `profile-refresh` and both receive
every broadcast on it.

**Diagnostic recipe:**

1. Open the failing flow side-by-side on two browsers with two
   different users signed in.
2. On User A, perform any write that fires a refresh broadcast
   (onboarding step save, lesson progress, points award).
3. On User B, watch for the re-render. If User B's dashboard
   visibly re-renders, this recipe.
4. To confirm, `grep` the codebase for
   `\.channel\(['"]` (literal channel-name broadcast sites) and
   `channel\.on\(['"]broadcast['"]` (subscriber side). Compare the
   channel names on both sides — if they match across users,
   that's the bug.

**The fix — scope the channel name per user:**

```ts
// server-side: 9 routes — broadcast on the user's own channel
await svc.channel(`profile-refresh-${auth.userId}`)
    .send({ type: 'broadcast', event: 'app-refresh-profile', payload: {} })

// client-side: UserContext.tsx — subscribe to the LOCAL user's channel
const channel = supabase.channel(`profile-refresh-${user?.id ?? 'anon'}`)
```

Plus the SSE relay at `src/app/api/realtime/stream/route.ts` which
forwards channel broadcasts to the user's EventSource — that one
also needs to subscribe to the per-user channel, not the global one:

```ts
// BEFORE (broken):
const channel = svc.channel(`realtime-user-${userId}`)
channel.on('broadcast', { event: 'profile-refresh' }, () => { ... })

// AFTER:
const channel = svc.channel(`profile-refresh-${userId}`)
channel.on('broadcast', { event: 'app-refresh-profile' }, () => { ... })
```

**Defense-in-depth option (not used here, but worth knowing):**
keep the channel name global but include `payload: { user_id }` and
have the client check the payload before refreshing:

```ts
channel.on('broadcast', { event: 'app-refresh-profile' }, (msg) => {
    if (msg.payload?.user_id !== user?.id) return
    void refreshProfile()
})
```

This works but is uglier and still costs the network round-trip
across all subscribers. Per-user channels are cheaper.

**When this hits again:** any time the codebase adds a new
supabase.channel().send() that's intended to refresh a single
user's session state. Audit recipe: `grep -rn "channel(['\"]" src/`
should show the SAME per-user name pattern across server and
client. If any pair disagrees, the channel is over-shared.

## Recipe #46 — `setLoading(true)` on mount with no global timeout leaves the dashboard stuck (added Aug 26 2026)

**Symptom:** after a hard navigation to `/dashboard`, the page
mounts and `UserContext.refreshProfile()` starts. The page renders
the DashboardGuard's black "Loading…" screen (centered). The
screen never goes away. A manual page reload fixes it.

**Root cause:** `UserContext.refreshProfile()` calls `getSession`
(which has a 5s timeout) then `Promise.allSettled([...4 queries...])`
with NO timeout. If any of those four queries hangs — typically
because the JWT just rotated in localStorage and Supabase REST
takes longer than expected to validate, or the IndexedDB lock
contends with another tab — `setLoading(false)` never fires.
The dashboard stays on its loading state forever.

The `getSessionWithTimeout` (Recipe #18) only covers the initial
session lookup. The downstream Supabase REST fetches (partners,
user_accounts, etc.) are NOT wrapped, so the loading safety net
from that recipe doesn't apply here.

**The fix — global safety net at the catch level:**

```ts
} catch (error) {
    console.error("Error loading user profile:", error);
    setIsPartner(false);
    setIsTrader(false);
    setProfile(null);
    setUser(null);
    setIsAdmin(false);
    setHasMembership(false);
    setLoading(false);
}
// Aug 26 2026 — Round 2 onboarding fix. Safety net: even if
// a downstream Promise never resolves (Supabase REST hang,
// IndexedDB lock, slow PWA cold-start), flip loading=false
// after 8 seconds so the dashboard guard doesn't trap the
// user on a black "Loading…" screen. The data may be
// partial; downstream consumers handle defaults for
// missing fields.
finally {
    setTimeout(() => setLoading(false), 8000);
}
```

The `finally` runs whether the function returns normally or
throws. After 8s, `setLoading(false)` fires regardless of promise
state. If the actual profile fetch completed in 2s, `setLoading
(false)` was already called by then — React deduplicates so the
delayed call is a no-op.

**The companion to Recipe #18.** Recipe #18 wraps individual
fetches with setTimeout. Recipe #46 wraps the entire
`refreshProfile` flow. Apply Recipe #46 at the **context/
provider** level, Recipe #18 at the **hook/consumer** level.

**When this hits again:** any client-side provider that exposes a
`loading: boolean` to consumers and whose `useEffect` calls async
fetch functions that don't individually wrap their fetches with
timeouts. Audit: `grep -rn "setLoading(false)" src/context/
src/components/` and check the function containing each
occurrence — is there a `finally { setTimeout(...) }` block
guarding the whole flow? If not, add one.

## Recipe #47 — TS `LEVEL_ANCHORS` and SQL `app_level_for` ladder must migrate in pairs (added Aug 26 2026)

**Symptom:** TS-level change to the level ladder (e.g. L1 from 500
to 50) compiles and ships fine. Production TS reads the new
ladder, computes the right level for any points value, displays
the right level on the profile page. Engine auto-unlock
(`app_auto_unlock_engines`) silently uses the OLD ladder because
the SQL function `app_level_for()` is still pointing at the old
thresholds. Users don't reach L1 even when their points qualify.

**Root cause:** the level ladder has TWO implementations:

```ts
// src/lib/os-points/config.ts — frontend ladder
export const LEVEL_ANCHORS: Array<{ L: number; pts: number }> = [
    { L: 1, pts: 50 }, { L: 2, pts: 150 }, ...
]
```

```sql
-- public.app_level_for() — backend ladder, called by award_log()
-- to compute the new level after each award and by app_auto_unlock_engines
-- to decide which engines to unlock
CREATE OR REPLACE FUNCTION public.app_level_for(p_total BIGINT)
RETURNS INTEGER LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE ...
BEGIN
    IF v_total >= 1000000 THEN RETURN 20;
    ELSIF v_total >=  800000 THEN RETURN 19;
    -- ...
    ELSIF v_total >=     50 THEN RETURN 1;
    ...
END;
$$
```

They're independent. The TS ladder drives display and onboarding
flow. The SQL ladder drives engine auto-unlock and ledger
consistency. A change to one without the other leaves the
system inconsistent: TS says "you're L1" but the engine gate
doesn't unlock because SQL still requires 500 pts.

**The fix — always migrate the ladder in pairs:**

1. Update `LEVEL_ANCHORS` in `src/lib/os-points/config.ts`.
2. Write a SQL migration that `DROP FUNCTION IF EXISTS public.
   app_level_for(BIGINT); CREATE OR REPLACE FUNCTION public.app_level
   _for(p_total BIGINT) ...` with the same ladder.
3. The migration must end with `NOTIFY pgrst, 'reload schema';`
   so PostgREST picks up the new function body.
4. Add a comment to the migration linking it to the TS commit
   so a future audit can find both sides of the change.

```sql
-- ~/Projects/the platform/supabase/migrations/202608260009_onboarding_points_and_l1.sql
-- (Round 9 of the onboarding fixes, paired with commit 251677a2)
DROP FUNCTION IF EXISTS public.app_level_for(BIGINT);
CREATE OR REPLACE FUNCTION public.app_level_for(p_total BIGINT)
RETURNS INTEGER LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_total BIGINT := GREATEST(0, p_total);
BEGIN
    IF v_total >= 1000000 THEN RETURN 20;
    ELSIF v_total >=  800000 THEN RETURN 19;
    ...
    ELSIF v_total >=     50 THEN RETURN 1;  -- new L1 threshold
    ELSE RETURN 0;
    END IF;
END;
$$;
GRANT EXECUTE ON FUNCTION public.app_level_for(BIGINT) TO service_role, anon, authenticated;
NOTIFY pgrst, 'reload schema';
```

**Audit before shipping any ladder change:**

```bash
grep -A 30 "LEVEL_ANCHORS:" src/lib/os-points/config.ts | head -32
grep -A 30 "FUNCTION public.app_level_for" supabase/migrations/*.sql | head -40
```

The two ladders should match. If they don't, write a migration
before shipping the TS change.

## Recipe #48 — Plan the rewards matrix at the same time as the step list (added Aug 26 2026)

**Symptom:** a 4-step wizard ships. Only step 2 (avatar) awards
points (10 pts). Steps 1, 3, 4 award zero. The wizard total is
"50 pts" in the marketing copy, but the actual ledger only
credits 10 pts for completing the wizard. The user reports:
"the recent activity show 10 points for setting a profile avatar
but I think we should also include a total of 50 points for
completing onboarding including the 10 points from the avatar so
each step gives you your points totaling to 50."

**Root cause:** the steps.ts file declares a `pointsReward` per
step, but the rewards weren't planned in tandem with the step
list. The default behavior of the wizard was "one step awards,
three are silent." The user's mental model was "every step
awards." Mismatch.

```ts
// src/lib/onboarding/steps.ts — what the user expected
{
    key: 'profile_basics',
    pointsReward: 'profile_avatar',  // 10 pts
    ...
},
{
    key: 'accent_theme',
    pointsReward: 'accent_theme',    // 10 pts (new)
    ...
},
{
    key: 'risk_disclaimer',
    pointsReward: 'risk_disclaimer', // 10 pts (new)
    ...
},
{
    key: 'walkthrough',
    pointsReward: 'walkthrough',     // 20 pts (new — final step gets the bonus)
    ...
}
// total = 10 + 10 + 10 + 20 = 50 pts
```

**The fix — when designing the step list, also design the
rewards matrix:**

| Step | Reward | Reason | Cumulative |
|---|---|---|---|
| avatar | 10 | small initial dopamine | 10 |
| theme | 10 | "you're customizing" | 20 |
| risk | 10 | "this is a real exchange" | 30 |
| walkthrough | 20 | "you're done, this is the celebration" | 50 |

Three rules:
1. **Total visible** = sum of step rewards. The user's mental
   model is "I earned X pts for finishing onboarding." Match
   that.
2. **Each step rewards SOMETHING.** Even if a step is "boring"
   (e.g. theme picker), award a small number. The user feels
   progression, not silence.
3. **The final step can bonus.** A 20-pt final walkthrough vs
   10 for the others says "this is the milestone." The 50-pt
   total maps cleanly to L1 if you've dropped L1 to 50 pts
   (Recipe #47).

Then plan the L1 threshold to match. If the total is 50 pts,
L1 should be 50 pts (or lower so onboarding unlocks ENGINE_A).
Otherwise the user completes onboarding, gets 50 pts, sees
"still at level 0," and asks "what was the point of the
celebration."

**When this hits again:** any time the wizard step list changes.
Audit: `grep "pointsReward" src/lib/onboarding/steps.ts`. Sum
the amounts (look up each in `src/lib/os-points/config.ts`). If
the sum doesn't match the user's expected total, redistribute.

## Recipe #49 — OnboardingHero at top of dashboard (added Aug 26 2026, display-only)

**Symptom:** the `<OnboardingHero />` component renders above
the welcome section on `/dashboard` showing "Setup · X/Y complete"
with an "Open the onboarding wizard" CTA. After the wizard is
finished, the hero is supposed to render nothing (`knownOnboarded
=== true ? return null`). But the user reported seeing it even
when onboarded because the lifecycle fetch in OnboardingHero
occasionally returned `required_count=7` (from the 7-step ladder)
instead of 4 (the Round 9 trim). The hero then took the wrong
branch and rendered.

**Resolution (Aug 26 2026):** the user explicitly requested the
hero be removed entirely. Removed the import + the JSX from
`src/app/dashboard/page.tsx`. The wizard is still available at
`/onboarding` from the sidebar for anyone who needs to revisit
it. The `OnboardingHero` component file is preserved in
`src/components/onboarding/OnboardingHero.tsx` in case it's
needed for a future surface.

If a future product surface needs an onboarding nudge, the
right shape is:
- source of truth is `profile.onboardingComplete` (synchronous,
  from UserContext) — never `lifecycle.completed_count` (async,
  can be stale)
- if `profile.onboardingComplete === true`, render nothing
- if `profile.onboardingComplete === undefined` (mid-load), render
  a skeleton placeholder, NOT the full hero
- only the explicitly-undefined `false` case renders the hero

This is Recipe #35's pattern: source-of-truth = `useUser().profile.
onboardingComplete`, three-state render with skeleton placeholder.

The Aug 26 decision was just to remove it; the right shape
remains as documented in Recipe #35 for any future use.

## Why this session didn't fall into the same traps as Round 8

- The cross-account broadcast glitch was the first Supabase
  Realtime-over-multi-user bug I'd seen. Recipe #45 captures
  the diagnostic + per-user-channel fix so any future "shared
  channel between users" bug has a starting point.
- The "Loading…" black screen had a similar shape to Recipe
  #18 (setTimeout safety net) but at the context level rather
  than per-fetch. Recipe #46 distinguishes the two layers.
- The 50-pt + L1 ladder change had to migrate in pairs — see
  Recipe #47. Half the work (TS only) would have shipped a
  broken system.

## Files changed this session

- `src/context/UserContext.tsx` — channel name per-user; finally
  block with 8s setLoading safety net
- `src/app/dashboard/page.tsx` — removed OnboardingHero import
  + JSX
- 9 server routes — broadcast channel name per-user
- `src/app/api/realtime/stream/route.ts` — SSE relay subscribes
  to per-user channel
- `src/lib/os-points/config.ts` — LEVEL_ANCHORS rewritten
  (L1 = 50 pts); added accent_theme, risk_disclaimer, walkthrough
  to POINTS
- `src/lib/onboarding/steps.ts` — pointsReward wired for the
  three previously-unwired steps
- `supabase/migrations/202608260009_onboarding_points_and_l1.sql`
  — DROP/RECREATE app_level_for(); upsert new reasons;
  recompute user_accounts.app_level; NOTIFY pgrst
- `public/sw.js` — bumped v42 → v44 across two commits
