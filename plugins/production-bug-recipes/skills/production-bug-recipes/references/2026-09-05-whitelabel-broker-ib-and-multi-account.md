# the white-label broker + Multi-Account Lessons — Sep 5 2026

Non-trivial lessons from the white-label broker IB integration and the
multi-account refactor. These are CLASS-LEVEL patterns, not
session-specific logs. When working on any broker integration or
multi-account state in the platform, read this first.

---

## 1. The white-label broker is an IB LABEL on the broker, NOT a separate broker

**The single biggest modeling mistake we kept making:**

The original V1.0 Vision document described white-label broker as a standalone
execution engine with its own `/api/whitelabel/execute`, `/api/whitelabel/positions`,
etc. endpoints. That model is WRONG.

Real architecture (verified against whitelabel-broker.example production JS):

```
the platform UI
   ↓ login with the broker creds
whitelabel-broker.example  ← IB label only, sets a session cookie
   ↓
the broker  ← the actual execution engine
```

white-label broker's API surface in the real contract is:
- `/api/auth/login` → returns user + `Set-Cookie: whitelabel_session=...`
- `/api/auth/me` → returns user record (cookie auth)
- `/api/admin/*` → admin tools (requires admin cookie)
- `/api/dev/affiliates`, `/api/dev/admin-deposits`, `/api/dev/sweep-history`, `/api/dev/users-with-transfers` → IB partner network
- `/api/broker/otp` → opens a broker session for the user

**What does NOT exist on real white-label broker:**
- Public trading API (no `/api/whitelabel/execute`, `/api/whitelabel/positions`)
- Per-firm URL paths (it's a single-domain site)
- Bearer tokens / API keys (only HTTP-only session cookies)

**Implication for the codebase:**
- Trading routes DO NOT change. `/api/broker/execute` etc. are unchanged.
- white-label broker IB users use the same the broker execution as everyone else.
- `broker_platform = 'whitelabel'` is just a LABEL in `user_accounts`, not a routing decision.
- white-label broker user gets the same the broker account id, the same positions, the same P&L.

**What we built that USES white-label broker's real API:**
- `/api/whitelabel/connect` — login + save cookie
- `/api/whitelabel/select-account` — user picks which broker account is theirs
- `/api/whitelabel/disconnect` — clear the IB label
- `/api/whitelabel/proxy` — forward authenticated requests to white-label broker

**What we DELETED that was based on the wrong V1.0 Vision model:**
- `/api/whitelabel/account-data`, `/execute`, `/close`, `/modify`, `/positions`, `/orders`, `/instruments`, `/signals`, `/copy-signal`, `/news`, `/community/*` — all of these proxied non-existent endpoints.

---

## 2. white-label broker auth is cookie-based, not Bearer

**Critical detail that bit us twice:**

white-label broker uses HTTP-only session cookies set by `/api/auth/login`. NOT Bearer tokens. NOT API keys.

- Login response: `Set-Cookie: whitelabel_session=<jwt>; HttpOnly; SameSite=Lax`
- Subsequent calls: forward the cookie via `Cookie: whitelabel_session=<jwt>`
- Cookies have a finite lifetime (~24h). Re-login when expired.

The user shared a `pk_live_***` key thinking it was the white-label broker API key. It was in Stripe format and white-label broker doesn't accept API keys at all. Treat any future "API key" shared as Stripe-format carefully — white-label broker doesn't use them.

**In our code:**
```typescript
// src/lib/whitelabel/client.ts — login
const setCookie = res.headers.get('set-cookie') ?? '';
// Extract name=value pairs (strip HttpOnly, Path, etc.)
const cookie = setCookie.split(/,\s*(?=[^;]+=)/)
    .map(c => c.split(';')[0].trim())
    .filter(Boolean)
    .join('; ');
return { cookie, user };

// Then forward on subsequent calls:
await whitelabelFetch('/api/auth/me', {}, { cookie });
```

Store the cookie in `user_accounts.whitelabel_access_token` (column is a TEXT, despite the name).

---

## 3. Engine unlock race condition in useSignals

**Pattern that breaks "show all engine signals" feature:**

`useSignals` builds an "unlocked engines" set from `engine_unlocks` + OS level. While the query is in flight, `unlockedEngines === null`.

If the realtime subscription handler checks `if (!unlockedEngines?.has(...)) return`, the optional chaining returns `undefined` (falsy) when null. Every incoming signal gets silently dropped during that 1-2 second window.

ENGINE_A (L0, always unlocked) survived because the platform-level default set already included it. ENGINE_D/ENGINE_E/etc. got dropped.

**Fix:** return an optimistic Set from `buildUnlockedEngineSet` (platform-level default + any loaded overrides). The realtime path can always check `.has()` without a null short-circuit.

```typescript
// CORRECT — never returns null
function buildUnlockedEngineSet(
    userEngineUnlocks: Record<EngineId, boolean> | null,
    osLevel: number,
): Set<string> {
    const unlocked = new Set<string>();
    for (const engine of ENGINE_LIST) {
        if (userEngineUnlocks && engine in userEngineUnlocks) {
            if (userEngineUnlocks[engine]) unlocked.add(engine);
        } else {
            // No override row — fall back to OS level
            const required = ENGINE_UNLOCK_LEVEL[engine];
            if (required === 0 || osLevel >= required) {
                unlocked.add(engine);
            }
        }
    }
    return unlocked;
}
```

**Where this pattern applies:** any code path that filters realtime data based on async-loaded user state. Optimistic defaults eliminate the race.

---

## 4. Push notifications: `notify_on_tp_sl` migration bug

**Pattern that affects existing users silently:**

The 2026-07-28 push subscribe route didn't set `notify_on_tp_sl` (column added later). The 2026-08-04 fix commit added `notify_on_tp_sl: true` to the subscribe route + ran migration `fix_notify_on_signal.sql`:

```sql
UPDATE push_subscriptions
SET notify_on_signal = true,
    notify_on_tp_sl = COALESCE(notify_on_tp_sl, true),
    ...
WHERE is_active = true
  AND (notify_on_signal = false OR notify_on_signal IS NULL);  -- ← ONLY fixes this subset
```

**Bug:** the WHERE clause only updated rows where `notify_on_signal` was also false. Users who had `notify_on_signal=true` (early subscribers who enabled signal notifications first) were skipped, leaving `notify_on_tp_sl=false`.

**Symptom:** user gets entry push but no TP1/TP2/TP3/TP4/SL pushes. No error — silent filtering at `eq('notify_on_tp_sl', true)` in `/api/signals/notify`.

**Fix migration pattern (Sep 3 2026):** one-shot UPDATE that filters by the symptom, not by the historical default:

```sql
UPDATE push_subscriptions
SET notify_on_tp_sl = true, updated_at = NOW()
WHERE is_active = true
  AND notify_on_signal = true  -- user wants signals, so they want TPs too
  AND (notify_on_tp_sl = false OR notify_on_tp_sl IS NULL);
```

**General lesson:** when fixing user-table defaults, the migration must include ALL the bug-affected rows, not just a heuristic subset. If a future change touches `notify_on_signal` defaults, run a similar migration to re-check.

---

## 5. Push notification deep-link pattern (bypass Tbroker)

**Pattern for "user taps push notification → sees the action item":**

The signals page has a 3-minute Tbroker filter — old signals aren't shown. But push notifications arrive within seconds of the signal, and the user might tap minutes later. By then the signal is filtered out.

**Solution: include the signal_id in the push URL.**

```typescript
// /api/signals/notify
url = body.url
    || (signal_id ? `/dashboard/trading?tab=SIGNALS&signal_id=${encodeURIComponent(signal_id)}` : '/dashboard/trading?tab=SIGNALS');
```

```typescript
// useSignals.ts — accept pinSignalId
export function useSignals(limit = 20, opts: { pinSignalId?: string } = {}) {
    // ...
    // In the initial fetch, after the TTL-filtered fetch, do:
    if (opts.pinSignalId && !normalised.find(s => s.id === opts.pinSignalId)) {
        const { data: pinRow } = await supabase
            .from('signal_log')
            .select('*')
            .eq('id', opts.pinSignalId)
            .maybeSingle();
        if (pinRow) {
            normalised = [normalise(pinRow), ...normalised];
        }
    }
}
```

```typescript
// SignalsView — read the URL param
useEffect(() => {
    if (typeof window === 'undefined') return;
    const params = new URLSearchParams(window.location.search);
    setPinSignalId(params.get('signal_id') ?? undefined);
}, []);
```

**Use `window.location.search` not `useSearchParams`** because Next 15+ requires `<Suspense>` boundary for `useSearchParams`. Read URL params client-only in `useEffect`.

**Applies to:** any push notification that should land on a specific item (signal id, position id, ticket id, etc.).

---

## 6. Multi-account pattern: `is_active` partial unique index

**Pattern for "user has many connections, only one is active":**

When a user can have multiple saved connections (e.g. Demo + white-label broker + Broker Direct + the CFD broker) but only ONE powers the dashboard at a time:

```sql
CREATE TABLE trading_accounts (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    account_type    TEXT NOT NULL CHECK (account_type IN ('demo', 'broker', 'whitelabel', 'cfd_broker')),
    display_name    TEXT NOT NULL,
    broker_account_id   TEXT,
    credentials     JSONB NOT NULL DEFAULT '{}'::jsonb,  -- plain JSONB unless compliance requires encryption
    metadata        JSONB NOT NULL DEFAULT '{}'::jsonb,
    is_active       BOOLEAN NOT NULL DEFAULT false,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- The safety net: at most ONE active row per user
CREATE UNIQUE INDEX idx_user_trading_accounts_one_active_per_user
    ON trading_accounts(user_id)
    WHERE is_active = true;
```

**Why partial index over a CHECK constraint:** a CHECK like `CHECK (count_active <= 1)` requires a trigger. The partial unique index is enforced atomically by Postgres on every INSERT/UPDATE.

**Switch flow:**
```typescript
// 1. Mark current inactive
await db.update(trading_accounts)
    .set({ is_active: false })
    .where(eq(trading_accounts.user_id, userId))
    .where(eq(trading_accounts.is_active, true));

// 2. Mark target active
await db.update(trading_accounts)
    .set({ is_active: true, last_used_at: new Date() })
    .where(eq(trading_accounts.id, targetId));

// 3. Mirror active state into the runtime columns (user_accounts.tl_*)
//    so the existing single-account code paths keep working.
```

The mirror step is key — keep `user_accounts.broker_connection_status` + `broker_account_id` etc. as the single source of truth for runtime, and treat `trading_accounts` as a "saved connections" registry.

**Applies to:** any "user can have N of thing X but only one is active" pattern. Examples: active subscription tier, primary email, default shipping address.

---

## 7. Supabase CHECK constraint pattern: clean stale values before tightening

**Pattern when adding a tighter CHECK constraint to a table with existing data:**

The first run of a migration adding a CHECK constraint will fail if any existing row violates it:

```sql
ALTER TABLE public.user_accounts
  ADD CONSTRAINT user_accounts_broker_platform_check
  CHECK (broker_platform IS NULL OR broker_platform IN ('mt5', 'dxtrade', 'broker', 'cfd_broker', 'whitelabel'));
-- ERROR: 23514: check constraint "..." is violated by some row
```

**Solution:** a cleanup migration that maps stale values to canonical ones BEFORE the constraint:

```sql
-- 1. Map known stale values to canonical
UPDATE public.user_accounts SET broker_platform = 'cfd_broker' WHERE broker_platform = 'genesis';
UPDATE public.user_accounts SET broker_platform = 'broker' WHERE broker_platform IS NULL OR broker_platform = '';

-- 2. Bucket any remaining unknown values to the safe default
UPDATE public.user_accounts SET broker_platform = 'broker'
  WHERE broker_platform NOT IN ('mt5', 'dxtrade', 'broker', 'cfd_broker');

-- 3. Drop + re-add the constraint
ALTER TABLE public.user_accounts DROP CONSTRAINT IF EXISTS user_accounts_broker_platform_check;
ALTER TABLE public.user_accounts ADD CONSTRAINT user_accounts_broker_platform_check
  CHECK (broker_platform IS NULL OR broker_platform IN ('mt5', 'dxtrade', 'broker', 'cfd_broker', 'whitelabel'));

-- 4. Verify
SELECT broker_platform, COUNT(*) FROM public.user_accounts GROUP BY broker_platform;
```

The diagnostic SELECT at the end is critical — paste the output back to confirm all rows are valid.

**General rule:** when changing a CHECK constraint, run a diagnostic first to see what values exist, THEN write the cleanup migration with the right mappings.

---

## 8. Docker build context size: exclude `.git` (551MB savings)

**Pattern for keeping Railway/Render builds fast:**

The `.git` directory is typically 200-600MB (every commit, every branch). Including it in Docker build context:
- Slows down every build (uploads 500MB+ to the builder)
- Can exceed context size caps on free/hobby tiers
- Invalidates cache unnecessarily

**`.dockerignore`:**
```
node_modules
.next
.git
env file*
!env file.prod
*.md
android
ios
marketing
docs
scripts/marketing
server
services
chrome-profile
.metaapi
```

Also: `git archive HEAD | tar -x` produces a clean source tree without `.git` — useful for "what would the build see?" sanity checks.

**Lesson:** when debugging "build is slow" or "build OOMed", the first thing to check is `.dockerignore`.

---

## 9. Next.js 15+: dynamic params must be awaited

**Pattern (silent type error → runtime crash):**

Next.js 15 changed `params` to a Promise:

```typescript
// ❌ WRONG — type error in Next 15
export async function PATCH(
    req: NextRequest,
    { params }: { params: { id: string } },
) {
    const targetId = params.id;
}

// ✅ CORRECT
export async function PATCH(
    req: NextRequest,
    { params }: { params: Promise<{ id: string }> },
) {
    const targetId = (await params).id;
}
```

If you copy-paste a Next 14 pattern into a Next 15+ project, the build fails with:
> Type 'Promise<{ id: string; }>' is not assignable to type '{ id: string; }'

**Applies to:** all dynamic route handlers in Next 15+.

---

## 10. PWA icon centering: COM, not bounding box

**Pattern for centering a brand mark in app icons:**

Center-of-mass of the foreground pixels (using numpy weighted sum) is the right anchor. Bounding box centers the bounding rectangle, not the visible content.

```python
import numpy as np
from PIL import Image

img = np.array(Image.open('source.png').convert('RGBA'))
# Mask: where alpha > 128 (visible pixels)
mask = img[:, :, 3] > 128
ys, xs = np.indices(img.shape[:2])
com_y = int(ys[mask].mean())
com_x = int(xs[mask].mean())

# vs. canvas center
canvas_w, canvas_h = img.shape[1], img.shape[0]
canvas_cy, canvas_cx = canvas_h // 2, canvas_w // 2

# offset = (com_x - canvas_cx, com_y - canvas_cy)
# An offset of (-1, 11) on a 1280×1146 canvas is essentially pixel-perfect.
```

**Lesson:** always test icons at small sizes (16×16 favicon, 192×192 PWA) — large visible offsets get amplified. The fix is a re-center using COM, not "make the canvas bigger."

---

## Quick reference: The white-label broker contracts we DID confirm

If working on white-label broker-related code in the future:

| Endpoint | Method | Auth | Purpose |
|---|---|---|---|
| `/api/auth/login` | POST | none | Login, returns user + sets cookie |
| `/api/auth/me` | GET | cookie | Get current user |
| `/api/auth/logout` | POST | cookie | Logout |
| `/api/auth/register` | POST | none | Register new user |
| `/api/dev/affiliates` | GET | cookie | List IB affiliates |
| `/api/dev/affiliates/[id]` | GET | cookie | Single affiliate |
| `/api/dev/admin-deposits` | GET | cookie | Admin deposits |
| `/api/dev/sweep-history` | GET | cookie | IB sweep history |
| `/api/dev/users-with-transfers` | GET | cookie | Users with transfers |
| `/api/admin/*` | various | admin cookie | Admin tools |
| `/api/version` | GET | none | Version info |
| `/api/geo-lang` | GET | none | Geo + language |
| `/api/broker/otp` | POST | cookie | Open broker session |

**Confirmed absent:**
- No public trading API (no execute/positions/orders on white-label broker)
- No per-firm paths
- No Bearer tokens / API keys
