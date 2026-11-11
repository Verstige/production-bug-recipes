# the guided-account program Guided System & Live the broker Tracker — Architecture Notes

Captured Aug 16 2026. Companion to recipes #19-#22 in the parent SKILL.

## What this is

A multi-tab guided experience for users of the guided-account program at `/dashboard/guided_account`:
- Tier picker (first-run experience)
- Account Health (4 live cards)
- Daily Check-in widget
- 4-Week Plan + Milestones
- Decision Log
- Lesson path (keyed to tier)
- Live the broker account tracker (separate sub-account)

The the guided-account program product itself is a "deposit $X, get 10× trading capital"
instant-amplified product with a single static 10% drawdown rule.
Real money, real broker account. The user picks a tier, designates a
the broker sub-account as their guided account, and the page guides them
through keeping the account alive.

## Why this is class-level reference material

Not a one-off feature — this is a reusable pattern for any "guided
account management" surface. Future analogous products (evaluation
accounts, copy-trading accounts, prop-firm simulators) would benefit
from the same scaffolding:
- Per-feature state columns on `user_accounts`
- Three supporting tables (checkins, decisions, milestones)
- One API route with `?action=` discriminator
- Five-tab page UI with shared ChangelogView-style shell

## Schema (Aug 16 2026)

```sql
ALTER TABLE public.user_accounts
    ADD COLUMN guided_account_tier            TEXT
        CHECK (guided_account_tier IN ('T1', 'T2', 'T3', 'T4')),
    ADD COLUMN guided_account_start_date      TIMESTAMPTZ,
    ADD COLUMN guided_account_starting_balance NUMERIC(12, 2),
    ADD COLUMN guided_account_goal            TEXT,
    ADD COLUMN guided_account_broker_acc_num      INTEGER;

CREATE TABLE guided_account_checkins  (user_id, checkin_date UNIQUE, respected_rules, trades_count, biggest_win, biggest_loss, notes, created_at);
CREATE TABLE guided_account_decisions  (user_id, decided_at, decision_text, outcome_text, outcome_kind, created_at);
CREATE TABLE guided_account_milestones (user_id, week_number UNIQUE, title, target, achieved_at, created_at);
```

All tables: RLS-gated to `auth.uid() = user_id`. The `guided_account_broker_acc_num`
column lets the guided-account program page read from a different the broker
sub-account than the main dashboard balance card.

## Tier math

| Tier | Deposit | 10× balance | Max loss (10% static) | Daily budget (2.5%) |
|---|---|---|---|---|
| T1 | $125 | $1,250 | $125 | $31 |
| T2 | $250 | $2,500 | $250 | $62 |
| T3 | $500 | $5,000 | $500 | $125 |
| T4 | $1,000 | $10,000 | $1,000 | $250 |

Position sizing: 1–2% risk per trade. Withdrawal cadence: withdraw
30–50% of profits when equity crosses 110% of start.

## 4-week plan (auto-seeded when tier is set)

- W1: Establish the baseline — respect daily loss budget 5/5 days
- W2: Build the rhythm — 6 check-ins logged, position size in range
- W3: First withdrawal — equity crosses 110%, withdraw 30–50%
- W4: Prove the discipline — 4 consecutive respected check-ins

## API surface

```
GET  /api/guided_account               — full state + checkins + decisions + milestones + computed
PATCH /api/guided_account              — update tier/start_date/starting_balance/goal
POST /api/guided_account?action=checkin   — upsert today's checkin
POST /api/guided_account?action=decision  — create a decision log entry
POST /api/guided_account?action=milestone&id=…  — mark achieved
GET  /api/guided_account/broker-account        — live broker data (state, positions, history)
POST /api/guided_account/broker-account?action=select&accNum=N
GET  /api/guided_account/broker-accounts       — list sub-accounts for picker
```

All endpoints require adminFetch (recipe #16) or Bearer header.

## File map

```
src/lib/guided_account/state.ts                          — tier math + helpers + types
src/lib/office-notifications.ts                 — admin task assignee push
src/lib/guided_account/auth.ts                           — Bearer/cookie auth helper
src/app/api/guided_account/route.ts                      — main CRUD endpoints
src/app/api/guided_account/broker-account/route.ts           — live broker data fetch
src/app/api/guided_account/broker-accounts/route.ts          — sub-account list
src/app/dashboard/guided_account/page.tsx                — page UI
src/app/dashboard/guided_account/guided_account.css               — page styles
supabase/migrations/202608160002_guided_account_guided_system.sql
supabase/migrations/202608160003_guided_account_broker_account.sql
```

## Lessons learned (Aug 16 2026 session)

1. **Always use adminFetch from the dashboard**, never plain fetch.
   See recipe #16. Three failed auth fixes came from missing this.
2. **Add AbortController timeouts to upstream API calls.** Slow
   the broker + no timeout = infinite spinner. See recipe #18.
3. **Audit CSS coverage when rebuilding existing pages.** 60+ classes
   used in JSX but no matching CSS rule. See recipe #17. The diff
   between JSX class usage and CSS selectors caught it in 30 seconds.
4. **Don't delete the old route when consolidating.** Replace with
   `redirect()` so bookmarks survive. See recipes #12/#13.
5. **Sub-account selection needs server-side validation.** When user
   picks accNum=N, hit `/auth/jwt/all-accounts` to confirm N exists
   before persisting. See recipe #14 extension in #20.

## What I deliberately did NOT do (out of scope, future work)

- Live SSE for the guided-account program account state (currently fetches on mount only)
- Email reminders for daily check-ins (needs cron + email service)
- Real lesson content (currently 16 lesson titles, no body)
- Auto-detect which broker account is the guided account (matching deposit amount $125/$250/etc.)
- Per-account tier-change confirmation modal (clicking a different
  tier in the TierBar is currently a no-op TODO)
- Mobile-optimized layout for the guided-account program page
