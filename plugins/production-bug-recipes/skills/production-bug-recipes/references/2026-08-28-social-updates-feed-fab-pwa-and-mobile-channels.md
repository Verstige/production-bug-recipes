# Social tab rebuild, FAB composer, PWA warm-restart fix, mobile channel switching — Aug 28 2026 (Rounds 31s–31w)

The user reframed the social/community tab from "messaging-style" to
a Community Updates feed (read-only cards: new members, signals,
announcements). This session surfaced four durable patterns that
go beyond the existing recipe set.

---

## Recipe #56 — `useEffect` infinite render loop from inline arrow function in dependency array (added Aug 28 2026)

**Symptom:** a feature works on first load but then the page becomes
unresponsive — scrolling is janky, console is flooded with the same
log line, browser eventually shows "Page Unresponsive". No TypeScript
errors. `tsc` and `next build` both clean.

**Root cause:** a parent passes an inline arrow function as a prop to
a child. The child has `useEffect(() => { ... }, [onHeightChange])`.
On every parent render, the arrow function is a NEW reference. The
effect sees a "changed" dependency → re-fires. The effect calls
`setCards(...)` which triggers a parent render → new arrow function →
infinite loop.

```tsx
// Parent (BAD)
<UpdatesFeed
  onHeightChange={() => {           // ← new ref every render
    scrollRef.current?.scrollTo({ top: scrollHeight, behavior: 'smooth' })
  }}
/>

// Child (BAD)
useEffect(() => {
  onHeightChange?.()                // ← fires on every parent render
}, [onHeightChange])               // ← sees a "new" ref each time
```

TypeScript doesn't catch this. ESLint's `react-hooks/exhaustive-deps`
warning is suppressed by `// eslint-disable-next-line`. The bug only
manifests at runtime.

**The 5-minute diagnostic:** open DevTools console. If you see the
same `console.log` or `[Component] doing X` line repeating hundreds of
times per second, you have an infinite render loop. The throttle
inside the actual fetch (e.g. `setLoading(false)` only fires once)
masks the root cause — the loop is in the *render*, not the work.

**Two valid fixes:**

1. **Drop the dependency entirely** (the right answer when the
   callback is fire-and-forget):
   ```tsx
   useEffect(() => {
     buildUpdatesFeed().then(...)
   }, [])  // eslint-disable-next-line react-hooks/exhaustive-deps
   ```
   The parent's `onHeightChange` is invoked exactly once on mount.
   Subsequent parent re-renders don't touch the child effect.

2. **Memoize the callback** (the right answer when the parent needs
   to actually trigger child work on demand):
   ```tsx
   const handleHeightChange = useCallback(() => { ... }, [])
   <UpdatesFeed onHeightChange={handleHeightChange} />
   ```
   The callback's identity is stable across renders so the effect
   only fires when something the callback *closes over* changes.

**The general principle:** any `useEffect` dependency that holds a
function is fragile. Either:
- The function does not need to be a dep → drop it.
- The function does need to be a dep → memoize it with `useCallback`
  or `useMemo`.

If neither fits, the parent-child data flow probably needs
rethinking (lift state, use refs, use a context with a stable
dispatch).

**This applies broadly:** any time you see a parent passing a callback
to a child and the child has that callback in a `useEffect` dep array,
audit the reference stability. The bug shows up in real-world code as
"the page freezes after a few seconds" or "scrolling is laggy" —
not as a stack trace.

**Pairs with:** `react-three-fiber` skill — same pattern shows up in
frame-driven `useFrame` callbacks when the parent re-renders without
memoizing.

---

## Recipe #57 — iOS PWA warm-restart: redirect-on-load kicks users back to /login (added Aug 28 2026)

**Symptom:** user opens the app from background on their iPhone (the
PWA didn't get force-killed — they just switched apps and came back).
All data is gone — even though they were logged in. They have to
force-close the app, reopen, and re-establish the session. Round 29
shipped a localStorage cache for the user profile, but the bug
persists in the community page specifically.

**Root cause:** the page-level redirect effect fires on the FIRST
render after warm-restart:

```tsx
// Page mount (BAD)
React.useEffect(() => {
  if (user === null) {
    router.replace('/login')              // ← fires immediately
  }
}, [user, router])
```

On a warm-restart, `useUser()` returns `user: null` for ~200ms while
Supabase rehydrates the session token from localStorage. The redirect
fires before the auth state resolves, bouncing the user to /login
even though their cached token was valid.

There's a parallel issue: the `if (!user) return <AuthGate />` block
also fires during that 200ms window, flashing the sign-in gate.

**The fix — three pieces:**

1. **Destructure `loading` from useUser:**
   ```tsx
   const { user, profile, loading: userLoading } = useUser()
   ```
   `UserContext` already exposes a `loading` boolean that flips true
   on mount and false after the Supabase rehydration completes.

2. **Wait for `loading: false` before redirecting:**
   ```tsx
   React.useEffect(() => {
     if (userLoading) return  // wait for rehydration
     if (user === null) {
       router.replace('/login')
     }
   }, [user, userLoading, router])
   ```

3. **Render a skeleton during loading, not the AuthGate:**
   ```tsx
   if (userLoading) return <CommunityLoadingSkeleton />
   if (!user) return <AuthGate />
   ```
   The skeleton (3 shimmer bars + 3 card silhouettes) keeps the
   previous content on screen until Supabase confirms the session.
   No more flash of the sign-in gate.

**Why the skeleton matters:** if you show `<AuthGate />` during the
loading window, the user sees "Sign in to access Community" for ~200ms
even when their session is valid. That's confusing and breaks trust.
A skeleton says "we're loading" without changing the user's
perception of auth state.

**The general principle:** any redirect-on-mount or "show sign-in if
no user" effect MUST gate on the auth context's loading flag, not
just on the user being null. The UserContext loading flag exists for
exactly this reason.

**Pairs with:** Recipe from `nextjs-pwa` skill on PWA warm-restart
edge cases. The `this skill` skill has a related
recipe on iOS sessionStorage losing data on WebView kill (Round 29
moved to localStorage); this recipe is the **next** layer — auth
state restoration after the localStorage fix is in place.

**Diagnostic:**
```bash
# On the iPhone, open the app from background (don't force-close).
# Open DevTools (chrome://inspect or Safari Web Inspector).
# Watch the console for "user: null" → "user: <uuid>" transitions.
# If the page redirects to /login before the user appears, this
# recipe applies.
```

**Same pattern shows up in:**
- `/dashboard` (handled correctly — has the loading gate)
- `/login` (no redirect, so no issue)
- `/dashboard/trading/community` (this recipe — was broken)
- Any future gated page that uses `useUser()` without checking
  `loading`

---

## Recipe #58 — Mobile drawer can't change ChatOS's active channel because state is internal (added Aug 28 2026)

**Symptom:** on mobile, you tap the hamburger → the drawer slides in
with a list of channels. You tap "Coffee Lounge" — the drawer
closes, the chat tab opens, but you're still on whatever channel was
previously selected. Tapping another channel does the same thing.
The user thinks channel selection is broken on mobile.

**Root cause:** the global hamburger drawer is in CommunityPage
(parent). ChatOS (child) holds `activeChannel` in its own
`useState`. The drawer's click handler only did
`setActiveTab('chat')` — never told ChatOS to switch channels:

```tsx
// Parent (BAD)
onClick={() => {
  setActiveTab('chat')              // ← switches TAB
  setSidebarOpen(false)
  // ← never tells ChatOS which channel to load
}}

const [activeChannel, setActiveChannel] = useState<Channel | null>(null)
// Child (ChatOS) — owns this internally, parent can't reach it
```

The user perceives "tap channel → nothing happens" because the chat
tab opens but the actual channel doesn't change.

**The fix — controlled-component pattern:**

1. **Lift the relevant slice of state to the parent:**
   ```tsx
   // Parent
   const [selectedChannel, setSelectedChannel] =
     useState<Channel | null>(null)
   ```

2. **Pass it as a prop:**
   ```tsx
   <ChatOS selectedChannel={selectedChannel} />
   ```

3. **Child reads it in a dedicated effect:**
   ```tsx
   // Child (ChatOS)
   useEffect(() => {
     if (!selectedChannel) return
     if (selectedChannel.id === activeChannel?.id) return  // ← guard
     setActiveChannel(selectedChannel)
     setMessages([])  // ← clear stale messages from previous channel
   }, [selectedChannel])
   ```
   The id-based guard prevents the effect from re-firing when the
   parent re-renders with the same channel pointer (i.e. on every
   render — `selectedChannel` is a stable reference, so it's only
   when the *value* actually changes that we re-fire).

4. **Parent updates the state when the user picks:**
   ```tsx
   <button onClick={() => {
     setSelectedChannel(ch)         // ← child follows
     setActiveTab('chat')            // ← also switch tab
     setSidebarOpen(false)
   }}>
   ```

**Design rule:** when two sibling components (or parent + child) need
to read/write the same state, lift it to the lowest common parent.
The child doesn't need to give up all its internal state — just the
piece that crosses the boundary.

In ChatOS's case, this means ChatOS keeps its own `messages`,
`connected`, `inputText`, etc. The parent only owns the
"which channel is selected" pointer. ChatOS subscribes via the
`selectedChannel` prop, ChatOS handles everything else.

**The general principle:** the lift-state pattern is React 101 but
people forget to apply it across the parent/child boundary that
exists at the *page level*. A drawer rendered in CommunityPage and
a chat surface rendered by ChatOS are functionally siblings — they
can't share state unless the page lifts it.

**Pairs with:** Recipe in `react-three-fiber` skill on lifting canvas
state up to the page level so a sidebar can change the active scene.
Same principle, different framework.

**Diagnostic:**
- User says "I can see channels in the drawer but tapping does
  nothing"
- Or "switching channels on mobile doesn't work but it works on
  desktop"
- The clue: desktop works because the desktop's persistent sidebar
  is INSIDE ChatOS — it talks to the same internal state. Mobile
  uses the global drawer which is OUTSIDE ChatOS — it can't talk to
  the internal state at all.

---

## Recipe #59 — Button-triggered modal composer (FAB pattern) for surfaces with limited vertical space (added Aug 28 2026)

**Symptom:** a chat-style surface has a persistent composer row at the
bottom (Telegram style). On mobile or short viewports, the composer
eats 60-80px of vertical real estate even when the user is just
scrolling and reading. Combined with a 5-app nav at the bottom of
the screen, there's not much room left.

**The fix — FAB + modal overlay:**

1. **Closed state is a single round FAB (Floating Action Button):**
   ```tsx
   <button
     typeName="fc-fab"
     style={{
       position: 'fixed',
       right: 16,
       bottom: 88,  // clears the BottomDock + margin
       width: 56,
       height: 56,
       borderRadius: '50%',
       background: 'linear-gradient(135deg, #a855f7, #7c3aed)',
       boxShadow: '0 8px 24px rgba(168, 85, 247, 0.45)',
     }}
   >
     <PenLine size={20} />
   </button>
   ```

2. **Click opens a centered modal with backdrop:**
   ```tsx
   {open && (
     <div
       className="fc-overlay"
       onClick={handleClose}              // ← click backdrop to dismiss
     >
       <div
         className="fc-modal"
         onClick={(e) => e.stopPropagation()}  // ← don't dismiss when clicking inside
       >
         {/* avatar + textarea + send button */}
         {/* hidden Trade Setup panel */}
         {/* image attach + cancel */}
       </div>
     </div>
   )}
   ```

3. **Z-index layering for surfaces that overlap a bottom dock:**
   ```
   BottomDock     — z-index 60 (5-app nav)
   fc-fab         — z-index 55 (round button, above dock visually)
   fc-overlay     — z-index 65 (modal backdrop)
   fc-modal       — z-index 70 (modal card sits on top of everything)
   ```

4. **Escape key dismisses; body scroll locked while open:**
   ```tsx
   useEffect(() => {
     if (!open) return
     const onKey = (e: KeyboardEvent) => {
       if (e.key === 'Escape') { setOpen(false); reset() }
     }
     window.addEventListener('keydown', onKey)
     return () => window.removeEventListener('keydown', onKey)
   }, [open])

   useEffect(() => {
     if (open) {
       const prev = document.body.style.overflow
       document.body.style.overflow = 'hidden'
       return () => { document.body.style.overflow = prev }
     }
   }, [open])
   ```

5. **Modal card max-height respects the dock:**
   ```css
   .fc-modal {
     max-height: calc(100dvh - 140px);  /* leave room for the BottomDock */
   }
   ```

**Why the FAB + modal wins over a persistent row:**
- Closed state: 56×56 round button = 2,500 px² vs 60-80px tall row
  = 14,000 px² (5.6x larger).
- The user explicitly opts in to writing a post. No accidental
  focus on the composer when scrolling.
- Trade setup form (LONG/SHORT, entry, stop, TP1-4) has all the room
  it needs in the modal — no cramped row.
- The 5-app nav stays visible at the bottom; the modal overlays
  above it via z-index 70, not below it.

**The general principle:** any "always-visible input affordance"
can usually be replaced with a single FAB + modal. The user gets
more screen real estate when not actively composing, and the modal
gives the composer more room when they ARE.

**Pairs with:** the floating-composer recipe (#54) — FAB is the
closed state of the same surface. The FAB stays at `bottom: 88px`
(mobile) or `bottom: 24px` (desktop) so it sits above the BottomDock
on every viewport.

---

## Cross-cutting patterns from this session

### A. "Mock data + reload-on-post" anti-pattern

The `useMock = true` short-circuit combined with `loadPosts()` as the
post-send callback is a double trap: every post triggers a reload,
which reloads the static mock list, which overwrites the just-posted
real row. Recipe #53 covers the fix; this session re-discovered the
exact same pattern in a different surface.

**The generic shape:** if you have `if (demoMode) loadMock(); return`
inside any load function, the write path MUST be aware that the
read path is mocked. The fix is the same every time: have the write
return the new entity, append it to local state with a dedupe
check, never re-read from the (mocked) source after a write.

### B. Tab-order swap + FAB + drawer match — the "everything is for someone else" moment

The user said the Social tab's content "is actually already on the
Chat OS page and I like how it's already designed." That's a tell:
the previous direction was wrong, and the user kept iterating
without telling the agent directly. Three sessions of iteration
on a chat-style composer, when all they wanted was a community
updates feed. The agent should have asked "is this the right shape
for this surface?" before shipping 6 rounds of iMessage cards.

**The lesson for the agent:** when a user gives 3+ rounds of detailed
visual feedback on a surface, take a step back and ask "is the
concept right?" before refining the visual. The surface itself may
be wrong. The chat-style composer → updates-feed pivot in this
session was a half-hour swap; if the agent had asked after Round 31o
("we're now 6 rounds into a composer you may not want — should we
rethink the surface?") it would have saved a day of iteration.

### C. The "Shipping without deploying" gap

Same as the prior session reference: the agent pushes commits to
`main` but the user has to pull + deploy manually. In this session
the user had THREE builds stuck in Railway's queue during their
platform-wide slowdown. The agent's "fixed!" claims were correct
about the code but meaningless to the user until the deploy
cleared. Be explicit about deploy state: "code is on `main`, but
the queue is stuck. Wait for Round N+2 to go live before testing."

### D. The "My code isn't deploying" diagnostic

When the user reports "still seeing the old behavior," check the
service worker version (or some other stable version marker) before
assuming the fix didn't take. In this session:

```bash
curl -sS https://www.yourdomain.com/sw.js | grep CACHE_VERSION
# Local:    const CACHE_VERSION = 'app-v107'
# Prod:     const CACHE_VERSION = 'app-v105'
# Gap: Rounds 31q-31w are NOT live
```

If prod SW < local SW, the fix isn't deployed — debug the deploy
queue, not the code. This is faster than re-reading the diff for
the 5th time looking for what might be wrong.

---

## Files touched this session

| File | Purpose |
|---|---|
| `src/components/community/social/SocialOS.tsx` | Wrapped feed in UpdatesFeed, replaced PostComposer with FloatingComposer, fixed infinite-loop with empty deps |
| `src/components/community/social/UpdatesFeed.tsx` | New: Community Updates feed (new members / signals / announcements) |
| `src/components/community/social/UpdatesFeed.css` | Card styles for new member / new signal / announcement / milestone |
| `src/components/community/social/FloatingComposer.tsx` | New: FAB + modal composer with Trade Setup form |
| `src/components/community/social/FloatingComposer.css` | FAB + modal overlay styles, modal card sizing |
| `src/components/community/CommunityPage.tsx` | Tab reorder (chat first), drawer controlled-channel, skeleton loading state |
| `src/components/community/CommunityPage.css` | Drawer branding styles (logo, gradient header, channel states matching desktop) |
| `src/components/community/chat/ChatOS.tsx` | Added `selectedChannel` prop + effect to respond to parent channel changes |
| `src/lib/community/mock-posts.ts` | 50-post preview fixture (still used; toggle via `useMock`) |

---

## Pairs with

- `nextjs-pwa` skill — PWA warm-restart + service worker cache bugs (Recipe #57 + prior references on iOS SW quirks)
- the companion platform skill — Community Updates feed + FloatingComposer surface area
- `user/user-interaction-standards` — trigger phrases:
  - "I can see channels but tapping does nothing" → Recipe #58
  - "All the content disappears after I reopen the app" → Recipe #57
  - "Showing 1 real traders" (returns silently) → Recipe #56
  - "This should be a community updates page, not chat" → Cross-cutting B
- `code-audit` skill — § "Mock-vs-real state-divergence" pairs with the anti-pattern in Cross-cutting A
