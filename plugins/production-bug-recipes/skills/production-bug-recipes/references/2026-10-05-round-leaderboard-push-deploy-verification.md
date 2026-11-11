# Oct 5 2026 round — Leaderboard seed data + push deploy verification

This round shipped:
- `aecb1dc3` / `40157cdb` / `ed5ccaea` — Leaderboard filter + service-role client (rolled out via 3 commits due to deploy verification pain)
- `142ce1b1` — Push notification diagnostics + webpush log
- Plus direct DB cleanup (51 seed users + 51 partner rows deleted)

Plus several one-off fixes (not leaderboard-related, captured separately):
- `f8224613` — Bell panel min-height (#98)
- `688c051e` — iOS viewport lock + 16px input font-size (#99)
- `28deff5c` — Admin inbox thread delete (#104)
- `4d0a0c91` — Education forward-flow CTA (#101)

The leaderboard work alone merits this reference; the rest are already in the Sep 27 round file.

## 1. The leaderboard bug (Recipes #106, #107)

**Symptom:** App Drawer → Learn → Leaderboard shows "0 traders ranked / 0 top score / No traders on the board yet" even though 60+ users exist in `user_accounts` with `onboarding_complete=true` and `points > 0`.

**Investigation path:**

```python
# 1. Query DB directly with service role
SELECT id, full_name, points, is_active, application_status, onboarding_complete
FROM user_accounts
WHERE is_active = true AND onboarding_complete = true
ORDER BY points DESC;

# Returns 60+ rows including Tomáš Costa at 334,820 points.
# So the data exists.

# 2. Hit the deployed API
curl -s https://www.yourdomain.com/api/leaderboard/os-points?limit=5
# Returns: {"ok":true,"rows":[],"fetchedAt":"..."}

# 3. Check the route's auth setup
cat src/app/api/leaderboard/os-points/route.ts
# Found: createClient(...NEXT_PUBLIC_SUPABASE_ANON_KEY...)
# The route uses the anon key → subject to RLS.
```

**Root cause (two compounding issues):**

1. The `/api/leaderboard/os-points` route used the anon Supabase key. The RLS policy on `user_accounts` (from migration `202608280000_leaderboard_rls.sql`) only granted SELECT to `auth.role() = 'authenticated'`. The leaderboard's anon-key call returned `auth.role() = 'anon'`, so the policy blocked the read — query returned 0 rows.

2. A migration `202609250002_leaderboard_rls_allow_anon.sql` was committed to fix the policy by adding the `anon` role to SELECT. But it was never run on production. The route's own comment block noted "Run that migration once after this commit to make the leaderboard actually return rows for unauthenticated viewers." That follow-up was missed.

**Lesson:** A code comment saying "you must also run this migration" is a bug waiting to happen. The fix is to **not depend on the migration** — switch the route to use the service-role client. Bypasses RLS entirely. The columns we select (id, full_name, avatar_url, points) are intentionally public; the route is server-side, the client only sees the JSON response. The endpoint is a marketing surface.

**Code change:**

```ts
// Before
import { createClient } from '@supabase/supabase-js';
function getSupabase() {
    return createClient(
        process.env.NEXT_PUBLIC_SUPABASE_URL ?? '',
        process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY ?? ''
    );
}

// After
import { createServiceClient } from '@/lib/supabase/service';
// ...use createServiceClient() in the handler
```

## 2. The seed-user pollution (Recipe #108)

After the RLS fix, the leaderboard was returning 60+ rows — but 51 of those were test seed accounts I created earlier (Tomás Costa, Felix Müller, Andrey Petrov, etc., all with `@app.demo` emails). The user had asked previously to delete the test cohort. The cohort was still there, holding 3,018,202 fake platform points that buried the 11 real members.

**Filter doesn't fix it. Data cleanup does.** I tightened the leaderboard filter to `application_status='approved'` (the authoritative "admin-vetted" signal) AND deleted the 51 seed users directly from production via the service-role key.

**Cleanup recipe (used here, reusable for any "delete a cohort" task):**

```python
import urllib.request, json

SUPABASE_URL = 'https://<project>.supabase.co'
SUPABASE_KEY = '<service-role key>'

# 1. Find the cohort by a distinguishing marker (email pattern, status, etc.)
req = urllib.request.Request(
    f'{SUPABASE_URL}/rest/v1/user_accounts?select=id,email&email=like.*%40app.demo&is_active=eq.true',
    headers={'apikey': SUPABASE_KEY, 'Authorization': f'Bearer {SUPABASE_KEY}'}
)
with _get(req, timeout=15) as r:
    cohort = json.load(r)
cohort_ids = [u['id'] for u in cohort]
ids_csv = ','.join(cohort_ids)

# 2. SAFETY: confirm the cohort marker is exact (no false positives)
#    in our case: every email MUST end with @app.demo
bad = [u for u in cohort if not u['email'].endswith('@app.demo')]
if bad: sys.exit(1)

# 3. Find FK-referencing tables BEFORE deleting user_accounts
#    Cascade order matters; if you delete parents first, FK
#    constraints can fail. Find child tables:
#    - partners (user_id FK)
#    - trading_subscriptions (user_id FK)
#    - push_subscriptions (user_id FK)
#    - notifications (user_id FK)
#    - etc.
#    Each one needs a DELETE BEFORE the parent user delete.

# 4. Delete children first
req = urllib.request.Request(
    f'{SUPABASE_URL}/rest/v1/partners?user_id=in.({ids_csv})',
    method='DELETE',
    headers={'apikey': SUPABASE_KEY, 'Authorization': f'Bearer {SUPABASE_KEY}'}
)
_get(req)

# 5. Delete parents
req = urllib.request.Request(
    f'{SUPABASE_URL}/rest/v1/user_accounts?id=in.({ids_csv})',
    method='DELETE',
    headers={'apikey': SUPABASE_KEY, 'Authorization': f'Bearer {SUPABASE_KEY}'}
)
_get(req)

# 6. Verify
req = urllib.request.Request(
    f'{SUPABASE_URL}/rest/v1/user_accounts?select=id&email=like.*%40app.demo',
    headers={'apikey': SUPABASE_KEY, 'Authorization': f'Bearer {SUPABASE_KEY}'}
)
with _get(req, timeout=15) as r:
    data = json.load(r)
print(f'Remaining seed users: {len(data)}')  # Must be 0
```

**Pattern:** Before deleting `user_accounts` rows, do a sweep of FK-referencing tables (partners, push_subscriptions, notifications, etc.) and delete the children's matching rows first. The Supabase REST API has a `Prefer: count=exact` header that returns the count of affected rows in `content-range` — use it to verify each step.

**The lesson:** Filter changes don't fix data. When the user says "only show me real users," the right answer is "tighten the filter AND clean the data." Both are needed; either alone is incomplete.

## 3. Railway deploy verification gotcha (Recipe #109)

This was the most painful part of the round. I shipped 3 commits in a row trying to verify the leaderboard fix was live:

1. `aecb1dc3` — service-role client switch
2. `61433452` — `console.info` log
3. `8f5686cb` — `_debug_v118` field in the response
4. `787d0d69` — version marker with timestamp

**None of them showed up in the live response.** Even after 6+ minutes of waiting. The Railway webhook was either not firing, the build was queued for a long time, or there was a silent build error I couldn't see.

**Detection patterns I tried:**

```bash
# Add a debug marker in the response
return NextResponse.json({
    ok: true,
    _debug_v118: 'service-role-RUNNING-' + new Date().toISOString(),
    _raw_count: data?.length ?? 0,
    rows: ...
})

# Hit it
curl -s https://www.yourdomain.com/api/leaderboard/os-points?limit=5
# Still returns: {"ok":true,"rows":[],"fetchedAt":"..."}
# _debug_v118 is missing → new code is NOT live.
```

**What I could not do:** open the Railway dashboard to see build logs. As an agent without that access, I had no signal whether a deploy was queued, failed, or simply not yet picked up.

**What worked as a fallback:** I ran `npx next build` locally and `grep -r 'v118' .next/` to confirm the source had been compiled into the build. If the local build has it, the source is correct — the deploy lag is on Railway, not in the code.

**Lesson:** Without dashboard access to the deploy platform, your only verification signals are:
- Local build succeeds + contains your marker (`grep` for a unique string)
- The remote response either includes the marker (deployed) or doesn't (not yet)

If the remote response doesn't include the marker after 5+ minutes, **don't keep pushing fixes to the same code**. The issue is the deploy pipeline, not the code. Either:
1. Wait longer (sometimes Railway queue is just slow)
2. Inform the user that the commit is on `main` but may not be live yet, and they should check the deploy dashboard
3. Don't refactor + repush + force-push hoping the next deploy catches up — that just creates churn in git history

**The commit history I produced for this fix:**

```
aecb1dc3 fix(leaderboard): switch os-points route to service-role client  ← first attempt
61433452 debug(leaderboard): log query result count                          ← debug 1
8f5686cb debug(leaderboard): echo raw count + version marker               ← debug 2
787d0d69 debug(leaderboard): v118 marker                                   ← debug 3
40157cdb fix(leaderboard): switch os-points route to service-role client  ← squashed, force-pushed
ed5ccaea fix(leaderboard): filter to admin-approved users only (drop test seed)  ← the real fix
142ce1b1 debug(push): add diagnostics endpoint + log webpush send results  ← unrelated
```

**The user-facing code shipped:** `40157cdb` (squashed service-role switch) and `ed5ccaea` (filter tightening). The 3 debug commits were squashed into `40157cdb` before the push went final. The git history is clean — but in-session, I produced 4 commits that all looked like "fixes" because the verification was so hard. The pattern to avoid: don't refactor + commit + push + wait + repeat. Instead, the first push should be the right push (with a strong debug marker in the response so you can confirm it's live). If it doesn't appear after 5 min, the issue is the deploy pipeline, not your code — tell the user to check the dashboard.

## 4. Push notification diagnostics (Recipe #107)

User reported "I'm not seeing any push notifications." DB showed 2 active Apple push subs, `last_sent_at` updating on recent events — meaning the broker (APNs) was accepting the push, but the user didn't see anything on the device.

**Diagnostic endpoint added: `/api/push/diagnostics`**

```ts
// GET /api/push/diagnostics — with bearer token
{
  "subscription_count": 2,
  "active_count": 2,
  "vapid_public_key_present": true,
  "vapid_public_key_fingerprint": "1a2b3c4d",
  "subscriptions": [
    {
      "id": 46, "is_active": true,
      "endpoint_prefix": "https://web.push.apple.com/QJgmNKu_SyK9...",
      "endpoint_kind": "apple",
      "last_sent_at": "2026-10-07T12:02:03.828+00:00",
      "user_agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) ...",
      "created_at": "2026-09-09T14:30:07.10959+00:00",
      "updated_at": "2026-09-23T23:36:36.095+00:00"
    }
  ],
  "devices_detected": 1,
  "hints": ["You have 2 active subscriptions for the same account..."],
  "next_steps": [
    "POST /api/push/test — sends a test notification...",
    "On iOS: if the test returns ok=true but you see nothing, ..."
  ]
}

// POST /api/push/diagnostics { action: 'dedupe' }
// Keeps the most-recently-updated sub, deactivates the rest.
```

**Plus logging in the dispatch helper:**

```ts
// src/lib/signals/notify-dispatch.ts — sendPush
console.info('[notify-dispatch] webpush delivered', {
    endpoint_prefix: subscription.endpoint.slice(0, 40),
    tag: (payload as any)?.tag ?? null,
});
// On failure:
console.error('[notify-dispatch] webpush FAILED', {
    endpoint_prefix: subscription.endpoint.slice(0, 40),
    statusCode: e?.statusCode,
    body: typeof e?.body === 'string' ? e.body.slice(0, 200) : null,
    message: e?.message,
});
```

**iOS PWA push delivery gotcha (Recipe #107):** When `last_sent_at` updates correctly but the user sees nothing on the device, the issue is iOS-specific and not server-fixable. The most common cause: **multiple push subscriptions from reinstalls**. iOS may dedupe visible notifications when 2+ device tokens fire. The fix: call `/api/push/diagnostics { action: 'dedupe' }` to keep the most-recently-updated sub.

Other iOS-specific causes (not server-fixable):
- PWA no longer installed on home screen — iOS only delivers web push to installed PWAs
- Notification permission was revoked (Settings → Notifications)
- iOS Focus / Do Not Disturb filtering
- Stale device token after extended period without the PWA being opened

User's resolution path: 1) call diagnostics + dedupe, 2) POST /api/push/test, 3) if test ok=true but no notification, delete PWA from home screen, reopen, re-add, re-grant permission.
