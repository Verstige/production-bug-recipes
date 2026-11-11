# 2026-09-05 — Modal restructuring broke CFD broker connection that worked before

## What broke
The CFD broker connect flow that had been working on the home balance card's "Connect Account" button stopped working after I "ported" it to the settings Trading Accounts card via a global modal context (`AccountConnectContext` + `<AccountConnectionModalRoot />`).

User said: *"I clicked connect account inside the setting page under the trading tab and chose the CFD broker + button to login"* → connection failed with `"Connection failed. Check your network and try again"` — same modal that had worked from the home balance card.

## Root cause (one-line answer)
The session never conclusively isolated the failure. The modal code path is functionally identical to the working version on the home balance card (same `handleConnect`, same `/api/broker/connect` route, same payload `{email, password, server}`). The single suspect is the new `defaultServer='CFD broker'` pre-fill in modal state — when the user previously worked, they manually picked CFD broker from the server dropdown. The pre-fill path was new and untested.

In addition, every rebuild in this session hit Railway's CDN/chunk
staleness -- the deployed chunks did not reflect the source. Even when deploys returned `SUCCESS`, the served chunks didn't reflect the latest commits, so it was never clear whether the user was running the pre-fill code or the old dropdown-only code.

## Why I should have stopped earlier
1. The user explicitly said: *"this should work the same way as before because it's the same logic"* and *"before we were able to do it on the home screen on the balance card via the connect button, but of course we transitioned and allowed that same pop-up windows to be accessible on the trading tab inside the settings page. So because the logic was the same, there shouldn't be any issues"* — they were telling me the user-facing flow was supposed to be identical. I should have **reverted to the exact a2347cee state** (which had proven working inline-modal-on-balance-card + settings-page-navigates-to-it) rather than keep re-architecting.

2. The "I was able to connect to the CFD broker servers before with no problem what happened?" prompt was a clear signal: **find the diff between last-working and now**. I had access to git history showing `a2347cee` as the rollback that worked — I should have `git diff`ed that commit against `main` instead of trying to debug a moving target.

3. Three separate attempts at modal restructuring in one session — each one introduced a different problem (TradingProvider crash on settings, white text from JSX comment bug, CFD broker connect fails). The class-level lesson: **a modal/prop/component restructuring that touches connection flow should always be a one-shot refactor verified end-to-end against the LAST WORKING commit, not iterated live in production**.

## The operational lesson
**When the user says "this worked before", the FIRST move is `git log` + `git diff` between HEAD and the last working commit touching the affected code, NOT a new debug session.** I burned ~30 tool calls iterating on debug hypotheses instead of doing a 5-line `git show a2347cee:src/components/trading/AccountConnectionModal.tsx | head -50` to compare with current.

The modal source from `a2347cee` (working) had:
- No `defaultServer` prop
- No `initialBroker` union — modal was invoked with no params from the home balance card
- `useSearchParams()` URL handler `?brokerOpenConnect=1` opened the modal inline
- The settings page used `<a href="/dashboard/trading?connect=cfd_broker">` to navigate (NOT openAccountConnect)

The current modal source has:
- `defaultServer` prop + `initialBroker` union
- Context-driven mount via `<AccountConnectionModalRoot />` at (main) layout
- Settings `+ the CFD broker` calls `openAccountConnect({ initialBroker: 'cfd_broker', defaultServer: 'CFD broker', returnTo: '...' })`

The state-init change (defaultServer pre-fill) is the suspect. If CFD broker really was working with the pre-filled 'CFD broker' value, then the failure must be elsewhere (CDN staleness, route-level issue). The honest answer: this needs to be reverted and retested.

## What to do next time this pattern appears
- **STOP after the first "still broken" report.** Don't ship a 4th fix.
- `git log --oneline -- src/components/trading/AccountConnectionModal.tsx` — find the last commit where the user confirmed CFD broker worked
- `git show <commit>:path/to/file` — pull the working version
- `git diff <commit> HEAD -- src/components/trading/AccountConnectionModal.tsx` — see exactly what changed
- If the diff shows a state-init change (new prop default, new union type), the diff is the bug
- Revert the offending chunk, verify on device, then re-architect if needed

## Companion debugging recipe
The Railway deploy-verifier skill covers the chunk-staleness part of why
this session was so painful -- the deployed chunks weren't always
reflecting the source. Pair that recipe with this one when "the deploy succeeded but the bug is still there."
