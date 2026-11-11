# 2026-09-27 — Sep 27 round: notifications, PWA zoom lock, admin delete, education forward-flow

Eight commits shipped on Sep 27 covering the notifications bell panel CSS, iOS
PWA form-field zoom lock, admin inbox thread delete cascade, education
last-lesson forward flow, the contracts flip-flop mea culpa, the TP/SL
bell-feed kind extension, and the signals Tbroker restoration. The recipes
below are the **class-level lessons** — the kind that future sessions
will hit without context if not captured.

---

## Recipe #98 — Notification bell panel collapses to header height when list is empty

**Symptom:** User opens the bell on the dashboard. Sees the "Notifications"
header with the X close button. Below the header — a transparent void,
through which the dashboard cards ("CONNECTED", "TOTAL EQUITY", etc.)
are visible. The panel looks like it's not rendering at all.

**Root cause:** `.nb-panel` (the bell dropdown) had `display: flex;
flex-direction: column` with a `flex: 1; min-height: 0` child (`.nb-list`)
and **no height or min-height on the panel itself**. With an empty list,
the panel collapsed to just the ~50px header — the empty `flex:1` child
collapsed to 0 height. The `background: #000000` only fills whatever
space the panel actually occupies, so the rest was clipped by
`overflow: hidden` and the dashboard showed through.

The bell was rendering fine on the **initial** open, but the user
perceived "nothing is showing" because the empty area between the
header and the bottom of where the panel should have been was
transparent.

**Fix:** Set `height: 480px; min-height: 240px;` on the panel. 480px
fits ~12 notification rows at ~40px each (title + body + meta +
padding). 240px is the floor so the empty/loading/error state
("Couldn't load notifications · HTTP 500", "You're all caught up",
etc.) always has room to be visible. `max-height: calc(100vh - 80px)`
caps on tiny screens.

```tsx
function NotificationBell() { /* ... */ }

.nb-panel {
  position: fixed;
  top: 64px;
  right: 16px;
  width: 380px;
  height: 480px;           /* enough for ~12 rows */
  max-height: calc(100vh - 80px);
  min-height: 240px;        /* floor for empty-state rendering */
  background: #000000;
  display: flex;
  flex-direction: column;
  /* ... */
}
```

**General pattern:** any flex-column overlay that has a header +
scrollable list body must set **height and min-height** on the parent.
Relying on `flex: 1; min-height: 0` on the child collapses the parent
to header height when content is missing, hiding error states,
Empty states, and "still loading" states behind a transparent void.

**Detection recipe:** any "I open the modal/panel and see nothing"
report where the header is visible but the body is transparent —
the parent is collapsing. Add `min-height` to the parent. If the
issue is on mobile where the panel is supposed to be fullscreen,
the same `min-height: 240px` rule still applies (just `max-height:
100%` instead of `calc(100vh - 80px)`).

**Adjacent fix in the same round:** the bell's `fetchFirst()` callback
was silently swallowing HTTP errors and network failures with an
empty `catch {}` block. That meant if the fetch did fail, the user
saw "You're all caught up" with no explanation. Now `fetchFirst`
records the error in state and the empty state renders the error
text. Also replaced the small 6px unread dot with a numbered unread
badge (`nb-row-unread-num`) showing `idx + 1` so users can scan-read
how many notifications they haven't acknowledged.

---

## Recipe #99 — iOS Safari auto-zooms inputs even when `userScalable: false`

**Symptom:** User taps a text input on the PWA (email login, signup,
connect broker modal). The keyboard opens, **and the viewport zooms
in to ~150%** so the field is readable. After dismissing the keyboard,
the user is stuck zoomed in. They have to pinch back out manually.
On a PWA this is jarring because the user expects native-app behavior.

**Root cause:** iOS Safari has a form-field zoom behavior: when the
user taps an input with `font-size < 16px`, the browser auto-zooms
the page. **This happens regardless of `viewport` meta settings.**
Setting `userScalable: false, maximumScale: 1, minimumScale: 1` on
the viewport meta is necessary but not sufficient. The font-size
gate is a separate CSS property.

**Fix:** Both controls, applied together:

```tsx
// src/app/layout.tsx
export const viewport: Viewport = {
  width: 'device-width',
  initialScale: 1,
  maximumScale: 1,        // ← locks pinch + double-tap zoom
  minimumScale: 1,        // ← prevents auto-zoom bounce-back
  userScalable: false,    // ← same intent at meta level
  viewportFit: 'cover',   // ← notched devices
  interactiveWidget: 'resizes-content',  // ← Android keyboard handling
};
```

```css
/* All form inputs: font-size >= 16px */
.broker-field input,
.input-wrapper input,
input[type="text"],
input[type="email"],
input[type="password"],
textarea {
  font-size: 16px;  /* iOS auto-zoom threshold */
}
```

**Detection recipe:** any mobile-only "the screen zoomed in" complaint
on a PWA — check `font-size` on the input first, viewport meta second.
A 14px input on a 16px+ viewport meta **still** triggers iOS auto-zoom.

**Audit:** grep for `font-size:.*1[0-5]px` in any `*.css` file
applied to `input`, `textarea`, or `select` selectors. Any hit is a
candidate. Bump to 16px. Visual difference at 14→16 is usually
acceptable on mobile (the input was tiny anyway); on desktop the
jump is negligible.

**General pattern:** when locking the viewport to 1.0×, the page must
ALSO meet the iOS auto-zoom gate. CSS-level font-size is the gate;
viewport meta is the lock. Both are required.

---

## Recipe #100 — Notification bell only showed initial signals; TP/SL hits went to web-push only

**Symptom:** User asked for "all of the signal notifications and all
of the PWA push notifications" to appear in the bell feed. The bell
showed initial signal posts (`⚔️ ENGINE_B signal: EURUSD BUY`) but **not**
TP/SL hits. TP/SL hits fired the platform-level toast but vanished from the
in-app feed as soon as the platform toast aged out.

**Root cause:** `src/lib/signals/notify-dispatch.ts` had:

```ts
// ── Bell-feed insert for new signals only ─────
if (input.type === 'signal') {
  await notifyUser(/* writes to notifications table */);
}
// TP/SL updates don't go to the bell feed — they're shown in the
// positions/history tabs as the user watches the trade live.
```

The intent was reasonable (TP/SL are shown live in positions/history),
but the user wanted a single in-app log of all events so they can
scroll back through recent activity. The bell is the natural surface
for that.

**Fix:** Extended the bell-feed insert block to handle three kinds:

```ts
if (input.type === 'signal') {
  bellEntry = { kind: 'signal', title: '⚔️ ENGINE_B signal: EURUSD BUY', ... };
} else if (input.type === 'tp_hit') {
  bellEntry = { kind: 'tp', title: '⚔️ ENGINE_B TP2 hit · EURUSD', ... };
} else if (input.type === 'sl_hit') {
  bellEntry = { kind: 'sl', title: '⚔️ ENGINE_B SL hit · EURUSD', ... };
}

if (bellEntry) {
  await Promise.allSettled(
    eligibleSubs.map((s) => notifyUser(svc, {
      user_id: s.user_id,
      kind: bellEntry.kind,
      title: bellEntry.title,
      body: bellEntry.body,
      link: bellEntry.link,
      ref_id: bellEntry.ref_id,    // shared per event, fn_insert_notification dedups
      metadata: bellEntry.metadata,
    }))
  );
}
```

Each variant has its own `kind` ('signal' | 'tp' | 'sl') so the
`KIND_META` map's icons/colors are distinct (cyan activity for signal,
green trending-up for TP, red trending-down for SL). Each variant's
`link` points to where the user can act:
- `signal` → `/dashboard` (analysis card)
- `tp` → `/dashboard?tab=positions`
- `sl` → `/dashboard?tab=history`

**`ref_id` design:** was previously `signal:<id>:<user_id>` (per-user),
now `tp:<signal_id>:<tp_number>` (per-event). The
`fn_insert_notification` SQL function dedups per
`(user_id, kind, ref_id)` within 60 seconds, so an event that fires
twice in the same window collapses to one row per user. Per-event
`ref_id` (vs per-user) is correct because the dedup window should
be per-event, not per-user-event-pair.

**Detection recipe:** any time a "the bell shows X but not Y" appears,
look at the dispatcher's bell-feed insert block — it's almost
certainly a `switch`/chain that only writes for one type. The user
likely wants all event types written, with each type using a distinct
`kind` so the UI's icon/color mapping can distinguish them.

---

## Recipe #101 — Education dead end: last lesson + no quiz link

**Symptom:** User reports "users are having issues continuing moving
forward from this section." Screenshot is the Education page with a
lesson at 70% complete and a "Resume lesson" CTA — but the user
can't continue past that.

**Root cause:** The lesson-complete success screen in `LessonViewer.tsx`
had:

```tsx
{next_lesson_id ? (
  <button onClick={() => onOpenLesson(...)}>Next Lesson</button>
) : (
  <button onClick={onBack}>Back to curriculum</button>
)}
```

When the user finishes the **last lesson in a module**, `next_lesson_id`
is `null`. The only button shown is "Back to curriculum." However,
to actually advance, the user must take the **module quiz** first
(because `allQuizzesPassed = tModules.every(m => !m.quiz || m.last_attempt?.passed)`
is the gate for track completion). The module quiz lives on the
platform page. Users had to scroll through 4 tracks of content to
find the quiz card. Most gave up.

**Compounding issue:** the overall-progress counter shows "70%
complete / 0 / 4 TRACKS" because:
- `overall_progress_pct = round(completedLessons / unlockedLessons * 100)` (70%)
- `tracks_completed = count(t => t.completed)` where `completed = allDone && allQuizzesPassed`

So the lesson-level and track-level counters diverge: 70% of lessons
done, 0 tracks fully completed because the user hasn't taken any
quizzes. Mathematically correct but feels contradictory.

Three changes:

```ts
// src/app/api/education/lesson/[id]/route.ts
// Now returns module_quiz + module_quiz_best_attempt alongside existing fields.
// Fetches the module-scoped quiz from education_quizzes + the user's best attempt.

// src/app/dashboard/education/page.tsx
// Wires onOpenModuleQuiz through to LessonViewer.

// src/components/education/LessonViewer.tsx
// Success-screen CTAs are now three-way:
{next_lesson_id ? (
  <button>Next Lesson</button>
) : data?.module_quiz ? (
  <button onClick={() => onOpenModuleQuiz(moduleId, data.lesson.title)}>
    {data.module_quiz_best_attempt?.passed ? 'Review module quiz' : 'Take module quiz'}
  </button>
) : (
  <button onClick={onBack}>Back to curriculum</button>
)}
```

Plus a quieter "Back to curriculum" escape hatch alongside the quiz
button (users who explicitly want to skip the quiz aren't forced into
it), and the user's last quiz attempt score + pass/fail text below
the buttons.

**General pattern:** any "complete this stage to unlock next stage"
UI must check the **gate condition** for advancing. If the gate is
"complete + take quiz," and only "complete" produces a CTA, the quiz
step is invisible. The forward-flow CTA at stage-completion must
explicitly point at the gate, not just the next stage.

**Detection:** If users complain "I'm stuck here" on a multi-stage flow,
audit each stage-complete screen for what's between the current
stage and the next. If there's a hidden gate (quiz, verification,
review, approval), surface it as a CTA. Don't assume the user knows
they need a quiz just because the data model has one.

---

## Recipe #102 — Frontend Tbroker filter as band-aid for missing listener-side cleanup

**Symptom:** Signals page was empty even though the DB had 175
`status='live'` rows in `signal_log`. I removed the
`.gte('sent_at', threeMinutesAgo)` filter and 175 signals appeared.
Then the user said "actually I want the 5-minute Tbroker back."

**Root cause:** The signals page filters on
`sent_at >= NOW() - 3 minutes` to exclude "expired" signals. But
the listener never runs a Tbroker cleanup — `status='live'` rows stay
live indefinitely until the listener resolves them via a TP/SL Telegram
post. With the filter in place, **all 175** signals are excluded.
With the filter removed, signals the listener forgot about pile up
indefinitely. Both are wrong.

**Fix in this round:** Filter set to 5 minutes (user preference). The
filter is a **frontend band-aid** for a listener-side problem. To
fix the root cause, the listener needs a periodic Tbroker cleanup:

```python
# services/telegram-listener/telegram_signal_listener.py
# (TODO — follow-up commit)
async def _ttl_cleanup_loop() -> None:
    """Flip stale 'live' signals to 'expired'."""
    while True:
        try:
            await asyncio.to_thread(_ttl_cleanup_once)
        except Exception as e:
            logger.warning(f"ttl cleanup error: {e}")
        await asyncio.sleep(300)  # every 5 min

def _ttl_cleanup_once() -> None:
    """One-shot cleanup: live signals older than 2h → expired."""
    svc.table("signal_log").update(
        {"status": "expired"}
    ).eq("status", "live").lt(
        "sent_at", (datetime.utcnow() - timedelta(hours=2)).isoformat()
    ).execute()
```

Without the listener-side cleanup, the 5-min frontend filter is a
**tradeoff** between "feed has gaps" (signals listener hasn't resolved
but user could still trade) and "feed shows stale signals" (signals
listener forgot about). The user picked "has gaps" — explicit preference.

**General pattern:** when a status field has implicit time semantics
(`'live'` = "tradeable right now") and the writer never expires them,
adding a frontend Tbroker filter is **always wrong** as a primary fix.
It hides the bug rather than fixing it. The right fix is server-side
Tbroker cleanup. Frontend filters are a band-aid while ownership is
established.

**Detection recipe:** any "this filter excludes everything" report
on a status-based feed — check whether the writer of that status
ever transitions it to the filtered-out state. If not, the filter is
hiding data instead of filtering it. Fix the writer, then the filter
becomes a real signal.

---

## Recipe #103 — Don't override verified data without contradicting evidence

**Symptom:** I shipped a contract-size audit that changed indices
(NAS100, US30, SPX500, GER40, UK100, JPN225) from `10` to `1` based
on an industry-standard assumption ("1 lot = $1 per index point").
User later reported US30 P&L values were 10× too small. Math check
against the user's broker screenshot showed the broker's actual contract
size for US30 is **10** — same as the CFD broker. I had been wrong. Reverted.

**Root cause:** I trusted an industry-standard assumption over the
file's own verification comment:

```ts
// (the file already had this comment for months)
// VERIFIED CONTRACT SIZES — NAS100 0.01 lot × 67.61 diff → $6.76
// 0.01 × 67.61 × 10 = $6.76 ✓
```

I dismissed this as "the CFD broker data" without re-checking. Both crypto
and index contract sizes were wrong this round because I overrode
verified data with assumption-derived values.

**Fix:** Reverted all six indices from `1` back to `10`. Comments in
`src/lib/broker/contract-sizes.ts` updated to own the mistake:
"Was 1, now 10 again. Don't override the file's verification comment
with industry-standard assumptions — the comment is the answer."

**General pattern:** **never override verified data without contradicting
evidence.** "Industry standard says X" is not contradicting evidence.
A user-reported bug **is** contradicting evidence. Until the user
reports an actual mismatch, leave verified data alone.

**Detection recipe:** any time you're tempted to change a verified
value because you "have a better understanding" of the system — don't.
The verification is the source of truth. If you're sure you're right,
wait for a bug report that proves it. If you ship the change and
you're wrong, the rollback costs more than the user patience saved.

**Audit workflow that would have caught this:**

1. User reports BTC P&L is 1000× too high. Fix to `1`.
2. **Before** shipping the index fix, verify against the broker
   actual data — at least one screenshot or live test on a sample
   trade.
3. The existing comment in the file shows the math works at `10`.
   Trust the comment over my assumption.

The crypto fix (`7e93d095`) was correct because there WAS a bug
report with actual data. The index fix (`390f27ab`) was wrong
because there was no bug report — I made it preemptively and was
wrong.

---

## Recipe #104 — Admin thread DELETE needs explicit cascade: storage → attachments → emails → thread

**Symptom:** User asked for "the option to delete emails from the
email inbox from admin so we have full control." No DELETE endpoint
existed; the inbox UI had no delete button.

**Fix:** Added `DELETE /api/admin/email/thread/[id]` with explicit
4-step cascade because the DB schema's foreign-key cascade doesn't
clean storage objects:

```ts
// 1. Storage (best-effort — orphan files are reclaimable later)
const byBucket = new Map<string, string[]>();
for (const a of attachmentRows) {
  byBucket.set(a.storage_bucket, [...(byBucket.get(a.storage_bucket) ?? []), a.storage_path]);
}
for (const [bucket, paths] of byBucket) {
  try { await svc.storage.from(bucket).remove(paths); }
  catch (e) { console.warn('storage remove failed (continuing)'); }
}

// 2. attachment rows
await svc.from('email_attachments').delete().in('id', attachmentRows.map(a => a.id));

// 3. emails
await svc.from('emails').delete().in('id', emailIds);

// 4. thread row (idempotent — already_gone flag for second admin)
const { data: deleted } = await svc
  .from('email_threads').delete().eq('id', id).select('id');
```

Plus a confirmation modal in the UI with:
- The thread subject quoted back (no ambiguity about what they're deleting)
- "This cannot be undone" warning
- Cancel + Delete buttons; both disabled while request is in flight
- Modal closes only via Cancel/X/backdrop-click (not Escape yet — kept simple)

**General pattern:** when adding destructive admin actions, the cascade
order matters: **storage → attachments → emails → thread**. If you
delete the rows first and the storage call fails, you have orphan
files. If you delete storage first and the row delete fails, you
have rows pointing at missing files (which is fine — the URL just 404s).

Storage cleanup is **best-effort** by design: orphan files are
reclaimable by a daily sweep. Orphan rows pointing at missing files
are broken state.

**Detection recipe:** any admin delete that touches Supabase storage
must include storage cleanup, even if it's not strictly necessary.
Storage buckets accumulate cruft fast and the user will notice
"shipping 100MB of dead attachment files" eventually.

**Idempotency:** the thread delete returns `200` even if the row was
already gone (returns `already_gone: true`). This makes the endpoint
safe for retries — if two admins click Delete simultaneously, both
get a 200, only one row actually disappears.

---

## Recipe #105 — Empty-state lessons propagate: always set `min-height` on flex-column overlay parents

**Sub-recipe cross-reference:** Recipe #98 (notification bell panel
collapse) and Recipe #82 (trading accounts empty state cramped) are
both manifestations of the same class-level lesson: **empty states
need explicit floor space**.

- Recipe #82 was horizontal-flex on a container that should have
  been column-flex. Fix: change `flex-direction`.
- Recipe #98 was flex-column with no `min-height` on the parent. Fix:
  add `min-height`.

Both share the meta-pattern: **don't rely on flex children's natural
sizing to make the parent tall enough.** Set `min-height` on the
parent based on what the empty state needs to render, not based on
what the loaded content needs.

**Detection:** any modal/dropdown/sheet/overlay that:
1. Has a header (or close button) at the top
2. Has a list/empty-state/loading area below it
3. Uses `display: flex; flex-direction: column`
4. Does NOT have a `height` or `min-height` set

...will show the "panel is broken" symptom when the list is empty.
Set `min-height: <enough for empty state to render>` on the parent.
240px is usually enough; 480px if the empty state has a spinner +
multi-line explanation + action buttons.

---

## Cross-cutting notes for this round

**Auth pattern for admin routes:** every admin route this round
(`/api/admin/email/thread/[id] DELETE`, etc.) follows the same pattern:

```ts
const auth = await getAuthContext(req);
if (!auth) return NextResponse.json({ error: 'Not authenticated' }, { status: 401 });
if (!auth.profile?.inbox_access) {
  return NextResponse.json({ error: 'Inbox access not granted' }, { status: 403 });
}
```

`inbox_access` is a flag on `user_accounts` that gates the admin
email features. For other admin features (traders, signals, IB
tracker), check `auth.profile.is_admin` instead. For partner features,
check `auth.profile.is_partner`. Each role has its own flag on
`user_accounts`. If you're adding a new admin-only route, check the
existing flag, don't introduce a new one.

**Rate limit 20/min for admin actions:** vs 60/min for reads.
Destructive actions should always have a lower rate limit than
non-destructive reads. If you add a DELETE/PATCH that mutates user
state, copy `applyRateLimit(req, { limit: 20, windowMs: 60_000 })`
from the existing DELETE handler.

**`<button>` can't nest `<button>` in HTML.** Recipe #104's
quick-delete on each thread row changed the row from `<button>` to
`<div role="button" tabIndex={0}>` so the nested trash `<button>`
could exist. Don't forget the `onKeyDown` handler for Enter/Space —
native `<button>` gives you that for free; `role="button"` doesn't.

**Patch tool multi-line JSX comments:** Recipe #85 (Sep 25 round)
covered the indentation mismatch issue. Recipe #104 hit it again on the
inbox CSS — the `replace_all` flag can help for repeat
indentation patterns but the safest pattern is still:
`read_file(offset, limit)` first, copy exact whitespace.