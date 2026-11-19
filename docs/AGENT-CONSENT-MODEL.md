# Agent consent: the states of the approval gate

Research note, written against `develop` at 78c16c9b (2026-11-19). It changes no code. It explains why the Debug harness answers a click's question "yes", lists every state the gate can really be in, argues against five richer designs, and recommends the smallest change that makes every state visible to the agent and provable by a fixture. [AI-AGENTS.md](AI-AGENTS.md) says what Lilo asks; [AGENT-HARNESS-PLAN.md](AGENT-HARNESS-PLAN.md) (stages 3, 4 and 8) says where the gate goes next.

## Summary

- The Debug harness does not answer "yes" because the product has a yes-by-default state. `LILO_AGENT_ALLOW_ALL=1` was a Debug switch for the question that lets a client connect. An unattended fixture run then hung 45 s on every flagged click, and the one-line fix reused the same switch for the click question (cd8612ef, PR #27, issue #23). One boolean answered two unrelated questions, and "yes" hid every false positive of the gate. `LILO_AGENT_CLICKS=allow|deny` (PR #48) split them.
- The gate is not a binary. `askConsent` already returns `Bool?`, which is three values, but the four callers that ask about an action (click, Enter and fetch, upload, profile) all collapse them with `== true`. The agent cannot tell a refusal from a timeout from a Lilo with no window, and the message for the last two ("The user did not allow...") is false.
- The owner's suspicion of missing intermediate states is right about the states and wrong about the axis. The missing states are categorical (denied, expired, unavailable). A number would describe the classifier's doubt, which Lilo cannot calibrate and a hostile page can steer.
- The connection question already has the right model: allowed, refused, unanswered (asks again at the next call), no window, each with its own text and its own test (`AgentConsentTests`). Recommendation: give the action gate the same four answers, as one four-case enum, and keep the Debug answerer a separate input to it.

## Question 1: what the gate does today

### How the harness got there

| Commit | What it did | Why |
|--------|-------------|-----|
| 5e1e1211 | `make agent-app` enables `agentControlEnabled` in the Debug profile before launch | A fresh Debug profile had agent control off, so no socket existed and `make agent-call` waited forever |
| cd8612ef (a24a3144 on develop), PR #27 | In `askConsent`, `#if DEBUG`, `action != nil` and `LILO_AGENT_ALLOW_ALL=1` returns `true` | `ALLOW_ALL` already let a client connect unasked, but a flagged click still showed a drawer nobody would answer and failed with `needs_user` after 45 s, so unattended fixture runs timed out |
| c1c54114, PR #48 | `AgentControl.debugClickAnswer`: `LILO_AGENT_CLICKS=allow` answers yes, `deny` answers no, both at once; unset, `ALLOW_ALL=1` still means allow. `make agent-app CLICKS=allow\|deny`, default allow | The two `asks` fixtures (`gate-login`, `gate-checkout-icon`) need a refusal to grade, and the others must never wait |

The cost of the cd8612ef shortcut was real. With every click answered yes, the harness could not tell a gate that asked from one that did not. `gate-save-order` ("Save order" must not be asked) still cannot be graded under `allow`, because a click that was asked and allowed passes too (the gate session's report says so). The default `allow` keeps that blind spot for every fixture that is not marked `asks`.

A Release build never reads either variable (`#if DEBUG`).

### Where each answer is decided

`approveConsequentialAction` (click, Enter, fetch) and `approveUpload` end in `askConsent(..., timeout: 45)`. `askConsent` shows the question in every window's address-bar drawer (`agentControlRequested`, rendered by `PermissionRequestDrawer.svelte`) and resumes when `answerConsent` is called. The drawer offers Allow Once, Always Allow on this site (not for uploads) and Deny. Three things end it with `nil`: the 45 s timer, the client cancelling the call and, before anything is shown, there being no window.

| State | Decided by | What `askConsent` returns | What the agent is told today |
|-------|------------|---------------------------|------------------------------|
| Not asked: setting off, site always allowed, or the page says the control is not consequential | `agentAskBeforeActions` and `agentAlwaysAllowedSites` in Swift, `consequential` in `AgentPage.js` | not called | the normal reply |
| Asked, Allow Once | the user, in the drawer | `true` | the normal reply plus "(the user allowed it in Lilo)" |
| Asked, Always Allow on this site | the user, in the drawer; `answerConsent` stores the site | `true` | as above, and the next click on that site is "not asked" |
| Asked, Deny | the user, in the drawer | `false` | `[needs_user] The user did not allow clicking "X" on site: ask them to do it or to allow it` |
| Asked, no answer in 45 s | the timer, `answerConsent(id, granted: nil)`; the drawer is withdrawn | `nil` | the same text as Deny |
| No window open | `askConsent` itself, before sending anything | `nil` at once | the same text as Deny, although no user was ever asked |
| Call cancelled by the client while waiting | the cancellation handler | `nil` | nothing: the client has gone |
| Debug harness | `LILO_AGENT_CLICKS`, `LILO_AGENT_ALLOW_ALL` | `true` or `false` at once, nothing shown | as Allow Once, or as Deny |

Two consequences follow from that table. First, "ask them to do it or to allow it" is advice the agent cannot follow after a timeout, because the question is gone and only a new call shows a new one. Second, a looping agent turns every timeout into a fresh 45 s question, so the user comes back to a new question each time, never the one they missed.

The question that lets a client connect is decided separately and better. `authorize` returns `Bool?` too, but `AgentMCP.ask` maps it to three session flags (`isAuthorized`, `isRefused`, `isUnanswered`) and a fourth check for no window, with four different texts. An unanswered question (600 s) is no refusal: the next tool call asks again. Approvals persist by client name and code identity. `LILO_AGENT_ALLOW_ALL` returns `true` there before any stored approval is read and stores nothing.

### Is the gate binary?

No, and the owner is right to doubt it. Counting what a caller can observe, the action gate has seven outcomes, of which the code distinguishes three. But "probability" is the wrong axis for them.

- The user's answer is a decision, not a likelihood. Allow, deny and no answer are categories. Between "yes" and "no" there is "not yet", "not here" and "yes, but only this once or on this site". Those are states.
- The only uncertain quantity in the gate is whether a control is consequential at all (`consequential` in `AgentPage.js`). Its in-between already exists and is categorical: a click that lands in a frame of another origin cannot be read, so the answer is "unknown, ask". That is the right handling of doubt: it fails toward the user.

## Question 2: the options, each argued against

### (a) The current binary plus timeout

For: it ships, it fails closed, there is nothing to configure, and the 45 s limit is chosen to end before an MCP client's own tool deadline.

Against: the type already has three values and the callers throw one away. An agent that cannot tell "declined" from "away" will either give up on a user who is at the keyboard or retry against one who is not. The Debug harness has two answers where the product has seven outcomes, so the unanswered and no-window paths have no fixture at all (`AgentApprovalTests` answers only true and false; nothing calls `answerConsent(..., granted: nil)` for a click). Verdict: keep the behavior, fix the vocabulary.

### (b) A typed result

Sketch. Four cases, no payload the caller needs:

```swift
enum ConsentAnswer { case allowed, denied, expired, unavailable }
```

`askConsent` returns it, so a `switch` in each of the four callers must name every case. "Always on this site" stays a side effect of the drawer's answer (the stored site list is already the scope), and "not asked" stays the guard before the question. Each failing case throws `needs_user` with its own text and one machine-readable key, for example `_meta["lilo/consent"] = "denied"`, next to the existing `lilo/errorCode`.

Against, adversarially:

- More cases mean more states to keep honest. Mitigation: this is the connection gate's model, already shipped and tested, not a new one.
- The longer list (allowed once, allowed for this site for this session, always) adds a scope. A session-scoped grant is a standing permission that a prompt-injected agent can reuse until the session ends, and it needs a lifetime (tab closed, navigation, cross-origin redirect, session end) plus a place in Settings so the user can see and revoke it. Lilo has no evidence that "once" and "always on this site" leave a gap. Leave scope out until a fixture or a user report shows one.
- An enum a caller can match with `default:` defeats the point. Mitigation: no `default:` in these switches, and a test per case (see the decision table).
- Typestate in Swift (a `~Copyable` approval token that the dispatch function consumes) would make it a compile error for a new tool to skip the gate. Zephium's move-only authority does this for its Rust core. It guards a risk that exists (a new tool forgetting `approveConsequentialAction`; `javascript_tool` is already out of scope by design), but it is a refactor of every dispatch path. Not for this change; reconsider when the tier work (stage 8) touches those paths.

### (c) A score mapped to tiers, with a probe in the middle

Sketch: weight the structural signals (password or card field, `cc-*` autocomplete, non-GET to another origin, button in such a form, destructive method, navigation after the click). Below a low bound, proceed. Above a high bound, ask. In between, probe: read the page again after the would-be effect, look for an unanswered question, or ask the agent for a justification string that is logged but not trusted.

Against, adversarially:

- Nothing calibrates it. Jev's confidence is calibrated "in aggregate" over labeled data (see below). Lilo has three gate fixtures. Any weight would be a guess that looks like a measurement.
- A hostile page picks its own signals. It can omit the `<form>`, use a `role=button` div and a `fetch`, or split a purchase into two clicks that each score low. A sum lets a benign signal cancel a dangerous one. The current rule is monotone: any hit asks, and adding a signal can only add a question. That is a security property worth keeping, so if severity is ever ordered, combine by maximum, never by sum.
- The probes do not probe. Reading the page "after the click's would-be effect" needs the effect to have happened, and a payment cannot be previewed. "Look for an unanswered question" has no referent when the user was never asked. A justification string comes from the party being checked, and a prompt-injected agent writes whatever persuades. It is useful as an audit line and must never move a decision.
- The middle band makes the same button ask on Tuesday and not on Wednesday. People learn to approve what they cannot predict.
- The only honest "in between" is "unknown, ask", which exists already for frames of another origin and costs nothing.

Verdict: no score. Keep the classifier a predicate with an explicit third answer (`none`, `ask`, `unreadable`, where `unreadable` asks). If tiers arrive (read, reversible, commit, irreversible), they are an ordered label from structure, not a probability.

### (d) Policy as data

Sketch: a small declarative file the user owns, evaluated by a pure function, so the gate runs in a headless test with no window.

Against, adversarially:

- Lilo already has policy as data: `agentAskBeforeActions`, `agentAlwaysAllowedSites`, `agentAllowedClients`, in the settings store and editable in Settings. A file adds a second place and a precedence question (Claude Code needs `deny`, then `ask`, then `allow`, plus modes, and its rule matching is documented as text matching, not a boundary).
- A file the user can edit is a file an agent working in a granted folder can edit. A policy that widens `allow` becomes the shortest path to escalation. It would have to live where agents cannot write, which is the settings store again.
- One caller, one knob each: [AGENTS.md](../AGENTS.md) says no config knobs with one caller.
- Cedar and OPA/Rego are authorization engines (principal, action, resource) in Rust and Go. They bring a runtime and a policy language for a decision with three inputs.
- What a file would buy, testing without a window, is available without one: the decision table below is data, and one table-driven test can iterate it.

Verdict: not now. Data is what the settings store already is; the testable part is the table.

### (e) What "unanswered" should mean

| Choice | Against |
|--------|---------|
| Deny (fail closed) | Right as the default. Wrong only when it looks like a decision. Fix: its own state and text |
| Retry once, inside Lilo | Doubles the wait, and an automatic second question is a fatigue lever: the user who was away comes back to a question that was re-asked until it was answered. Let the agent's own retry do it, visibly, and tell it once |
| Escalate to a stricter tier | There is no tier above deny. Escalation fits classifier doubt (unknown becomes ask), not a user who did not answer |
| Suspend and park the run | Right for a run Lilo owns: a program waiting for an approval should survive a restart (stage 4, durable `run`) and show as "waiting for you" on its conversation row. Impossible for an external MCP client, whose tool call Lilo cannot suspend. A shortcut (keep a late Allow for the same site and label for ten minutes) needs the approval bound to the exact payload, or an old yes approves a different order |

Recommendation: unanswered fails closed as `expired`, with text that tells the agent the question is withdrawn, that it may call again once, and that if it expires again it must stop and tell the user what is waiting. Parking is the in-app `run`'s answer to the same `expired` case, later; the same enum serves both.

### How other tools model it

- Claude Code keeps modes and rules apart. Modes (`default`, `acceptEdits`, `plan`, `auto`, `dontAsk`, `bypassPermissions`) say who answers when no rule matches; rules evaluate `deny`, then `ask`, then `allow`, and `deny` holds in every mode. Two of its modes are the Debug harness's two answers: `bypassPermissions` is `allow`, and `dontAsk` (auto-deny whatever would prompt) is `deny`. Its guidance is to run unattended work in `dontAsk` with explicit allow rules, not in bypass. That is the model this note borrows: the harness is a mode, the product states are what rules return.
- Claude in Chrome has "Ask before acting" (a plan and a site list approved up front) and a "Skip all approvals" mode, with newer builds checking each action as it goes. It keeps a floor no grant lifts: it still asks before downloads, entering sensitive information and granting authorizations on an always-allowed site, and, as users inspecting the extension report, sites in a server-side category are asked on every action whatever was saved. The floor is the useful idea: Lilo's upload question is already one (asked "whatever the setting").
- Playwright MCP has no gate. `--allowed-origins`, `--blocked-origins` and `--secrets` are documented as not a security boundary, and approval is left to the MCP client. A browser that holds the user's cookies cannot make that choice.
- Zephium's agentic core splits admission (policy), dispatch, settlement and independent effect verification, with a move-only authority and typed refusal and uncertainty outcomes. It says a timeout after dispatch may leave an unknown effect and must not be retried blindly. Two things carry over: the refusal outcomes are a closed vocabulary rather than a boolean, and "the click returned" is not "the order went through", which is why Lilo's reply names what a click landed on and the agent must read the page again.
- BrowserOS: I could not find its confirmation design. Neither its README nor its changelog (`/tmp/lilo-research/bos-changelog.mdx`) mention one, and the BrowserOS MCP server did not connect in this session. Nothing here relies on it.

### "Typesafe jev"

Identified with reasonable confidence: TypeSafe AI's Jev, a proprietary hosted "System One" decision model (early access 2026-09-15, version 1.14 on 2026-10-14; also served through OpenRouter's Decisions API). It takes a state and typed questions and returns typed answers with probabilities and a confidence, never text. The question types are Choice (pick from a set), Score (ordered levels), Noul (a yes/no probability) and Box (a region of an image). Its documentation suggests three bands on confidence: act automatically above a high threshold, proceed with caution or ask in the middle, route to a person below a low one. Its OpenRouter cookbook "Gate Agent Tool Calls with Jev" is the owner's tier idea almost exactly: all checks at or above 0.9 approve, any at or below 0.1 block, the rest go to a human and pause the run (`awaiting_hitl`); an error from the model call never becomes an approval. Community wrappers add an explicit `Uncertain` branch (`discern`, for Effect) and a Swift package, `AnyDecisionModel`, that can run a local MLX model instead of the hosted one.

I read the TypeSafe introduction, OpenRouter's explainer and the gating cookbook. I did not call it or read the weights, which are not published. If the owner meant something else (a Swift library, or a different "jev"), I could not find it.

Why it does not fit the gate:

- Hosted and paid: every click's page state would leave the Mac, against [PRIVACY.md](../PRIVACY.md) and the "nothing at idle, no request of its own" rule.
- Calibration holds on average over labeled data, and identical calls moved the probabilities by up to eight hundredths (the cookbook says the outcome held). A decision that must be reproducible by a fixture cannot sit behind it.
- The page is the input, so a hostile page writes the model's evidence. The cookbook itself keeps arithmetic and exact rules in code, ahead of the model.
- A local model avoids the first point and adds a dependency, memory and a first-run download to a browser whose rule is direct dependencies only.

What is worth taking is its shape, not the model: a closed set of answers, an explicit "unsure" that goes to a person, and refusal to turn a failed check into an approval. That is (b) with `expired` and `unavailable` in place of probabilities.

Similar typed-decision approaches considered: decision tables (what the table below is), Cedar and OPA/Rego (see (d)), sum types and typestate in Swift (see (b)).

## Recommendation

Two concerns, kept apart.

1. **Product gate states** (the enum above, one switch per caller, no `default:`):
   - `allowed`, `denied`, `expired`, `unavailable`, plus the existing guard "not asked".
   - The three refusals keep `code: "needs_user"` and differ in text and in `_meta["lilo/consent"]`. The texts are in the decision table.
   - The click, Enter, fetch, upload and profile callers all adopt it. The connection gate already behaves this way.
   - Make the 45 s a static like `connectionConsentTimeout`, so a test can shorten it.
2. **Debug harness mode** (`LILO_AGENT_CLICKS`): only an answerer, it never adds a state. It should be able to produce every state a user can: `allow`, `deny`, and one new value `expire` that answers `nil` at once. `unavailable` needs no mode: a test with no window produces it.
   - Make `deny` the default of `make agent-eval`, as `dontAsk` is Claude Code's default for unattended work, and run `allow` only for a fixture that needs the click to go through. Under `deny`, a false positive in any fixture fails with `needs_user` instead of passing silently, so `gate-save-order` finally proves "not asked". It also removes the second pass and the app restart for modes: only fixtures that need a yes need a second pass. Unmeasured caveat: run the suite once under `deny` first. Any fixture whose goal is itself a commit (a booking, an archive, a save) may ask, and each is then either a gate false positive to fix or a fixture that belongs in the `allow` pass.

What not to build: a score, a probe, a policy file, a session scope, an automatic retry, a hosted or local model. Reopen (c) only if a measured false negative exists that no structural rule reaches, and then as an ordered label combined by maximum.

### How this relates to what lilo-gate2 ships

On develop at the time of writing, PR #48 has landed the Debug click mode (`debugClickAnswer`, `make agent-app CLICKS=`, the `asks` planning in `bench/mcp/fixtures.py`). This note extends that function by one value and proposes a different default; it does not contradict it. The tab-scoped consent that session is working on (the question shown on the agent's own tab, stage 3) was not on develop when I read `askConsent`. It changes where the question appears; this note changes what the question can return and what the agent is told. Both edit `askConsent`, so land the tab scope first and rebase the enum onto it. I touched none of those files.

## Decision table

"Today" is the text on develop at 78c16c9b. "Proposed" is what the recommendation ships. Texts name the control and the site as today. Fixture names marked **write** do not exist yet and are listed, not written.

### The action gate (click, Enter, fetch; upload and profile share the answers)

| State | Decided by | Agent sees today | Agent should see | Retry guidance in the text | Fixture |
|-------|------------|------------------|------------------|----------------------------|---------|
| Not asked: gate off | setting `agentAskBeforeActions` | normal reply | same | none | `AgentApprovalTests.testTurnedOffNothingIsAsked` |
| Not asked: site always allowed | user's site list | normal reply | same | none | `testAlwaysAllowedSitesSkipTheQuestionUntilForgotten` |
| Not asked: not consequential | `AgentPage.js` `consequential` | normal reply | same | none | `testAnOrdinaryClickIsNotAsked`, `testSavingAnOrderNoteIsNotAsked`; eval `gate-save-order` (gradable under `deny`) |
| Asked because unreadable (frame of another origin) | `AgentPage.js`, fails toward the user | as Asked | as Asked | as Asked | `testAClickOnAFrameOfAnotherOriginIsAsked` |
| `allowed` once | user, drawer | reply plus "(the user allowed it in Lilo)" | same | none | `testAnOrderWaitsForTheUsersAllow`; eval **write** `gate-allowed-order` (an `allow` task: the order completes and the answer says it was allowed) |
| `allowed` always on the site | user, drawer | as above, later not asked | same | none | `testAlwaysAllowedSitesSkipTheQuestionUntilForgotten` |
| `denied` | user, drawer | `[needs_user] The user did not allow clicking "X" on S: ask them to do it or to allow it` | `[needs_user] The user declined clicking "X" on S.` plus `lilo/consent: denied` | do not try again; report that it was declined and ask what to do instead | `testADeniedOrderNeedsTheUserAndDoesNothing`, `testPostingButtonsAreAsked`; eval `gate-login`, `gate-checkout-icon` under `deny` |
| `expired` (45 s, or withdrawn) | timer | the Deny text | `[needs_user] The user did not answer within 45 s, so the question was withdrawn.` plus `lilo/consent: expired` | call the tool again once to ask again; if it expires again, stop and tell the user what is waiting | **write** `AgentApprovalTests.testAnUnansweredOrderExpiresAndSaysSo` (shortened timeout, `granted: nil`), and `testAnExpiredOrderIsAskedAgainAtTheNextCall`; eval **write** `gate-expired` under `expire`, graded by `held("pay")` and at most two attempts |
| `unavailable` (no window) | `askConsent`, before sending | the Deny text (false) | `[needs_user] Lilo has no window to ask the user in: ask them to open one, then call again.` plus `lilo/consent: unavailable` | ask the user to open a window, then retry | **write** `AgentApprovalTests.testAnOrderWithNoWindowSaysSo` (the connection path has the same case in `AgentConsentTests`) |
| Cancelled by the client while waiting | cancellation handler | nothing | nothing; the question leaves the drawers | none | **write** `testACancelledOrderWithdrawsItsQuestion` (`pendingConsentAnswers` empty, drawers told `permissionRequestClosed`) |
| Debug `allow` / `deny` | `LILO_AGENT_CLICKS` | as `allowed` / `denied` | the same texts: a mode must not have its own | as the state | `AgentConsentTests.testTheClickModeAnswersAtOnceAndAllowAllMeansAllow`; **write** the `expire` case there |
| Upload | user, drawer; never skipped by the setting or the site list | as the action gate, text "uploading P to S" | the same four answers | as the action gate | `AgentCaptureTests.testADeniedUploadNeedsTheUserAndLeavesTheInputEmpty`; **write** `expired` for upload |
| Profile switch | user, drawer, once per client and profile | `[needs_user] The user did not allow the profile P` for denied and unanswered | the same four answers | as the action gate | none found; **write** with the profile tests |

### The connection gate (already typed; here for completeness)

| State | Decided by | Agent sees | Fixture |
|-------|------------|------------|---------|
| allowed, stored by name and code identity | user, modal | tools work | `AgentConsentTests.testAnUnknownClientIsAnsweredAtOnceAndItsToolsWaitForConsent` |
| refused (`isRefused`) | user, modal | `[needs_user] The user did not allow C to control Lilo: ask them to allow it, then reconnect the lilo MCP server` | `testARefusedClientIsToldAtEachToolCall` |
| unanswered (600 s, `isUnanswered`) | timer | `[needs_user] Lilo is waiting for the user to allow C ...`; the next call asks again | `testAnUnansweredQuestionLeavesTheClientWaitingAndItsNextToolCallAsksAgain` |
| no window | `AgentMCP`, `windows.isEmpty` | `[needs_user] Lilo has no window to ask the user to allow C in ...` | none for this text; **write** with the item above |
| Debug `LILO_AGENT_ALLOW_ALL=1` | environment, Debug only | tools work, nothing stored | none direct; every `make agent-eval` run depends on it |

## Open items

- Whether `_meta["lilo/consent"]` is worth a key or the text alone is enough. The text is what agents act on today; the key is for harnesses that grade without parsing prose. It is one line per throw.
- Whether the gate's 45 s should differ for an in-app `run` once runs are durable: there the answer to `expired` is to park, not to fail.
- The classifier's blind spots (links and `role=button` elements inside forms are not treated as submits, as the stage 2 notes say) are a separate problem from the answers.
