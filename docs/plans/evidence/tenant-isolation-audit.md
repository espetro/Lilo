# Lilo agent tenant isolation audit

Static reading of the agent sources at commit 086443c6, 2026-11-26. No code was run, so every walkthrough is derived from code and still needs its fixture. Paths are relative to `Lilo/Agent/` unless they start with another folder. "Tenant" means one logical agent; today the nearest object is `AgentSession` (one per socket connection).

## 1. Already isolated

| # | Mechanism | Evidence | Limit |
|---|---|---|---|
| I1 | Same-user socket gate: mode 0600 plus peer uid check | `AgentSocketServer.swift:63`, `:89-95` | Gates users, not tenants |
| I2 | One `AgentSession` per accepted connection, replies go to that connection | `AgentControl.swift:689-691`, `:713-728`, `:733-795` | Reconnect adoption moves state (G9) |
| I3 | Per-session folder map with fresh `TabFolder` ids, so two same-titled sessions do not share a folder | `AgentControl.swift:766`; `AgentFolders.swift:82-86` | Not for Lilo conversation sessions, which share the conversation folder (`AgentMCP.swift:53-56`) |
| I4 | `agentTab` resolves numbers only in the caller's folders and isolated space | `AgentFolders.swift:255-269` | Folder membership is the only ownership record (G14) |
| I5 | User private tabs refused unless in the caller's own isolated space | `AgentFolders.swift:282-284` | |
| I6 | `tabs_context_mcp` lists only the current folder plus own isolated tabs | `AgentTools.swift:125-135` | `agentTab` is wider than the listing |
| I7 | Closed or stopped connection cannot keep driving tabs; its requests are cancelled | `AgentFolders.swift:251`; `AgentControl.swift:695`, `:638` | |
| I8 | One private space per session, with a non-persistent store keyed by space or tab id | `AgentFolders.swift:92-102`, `:222-224`; `Lilo/Profiles/ProfileManager.swift:64-69`; `Lilo/Engine/WKEngineFactory.swift:411-412` | A window showing the space gives new tabs a per-tab store (`Lilo/Tabs/TabManager.swift:576-583`), so "one jar" depends on UI state |
| I9 | Isolated space deleted at session end or last isolated tab close; its stores, downloads list and permissions released | `AgentControl.swift:642`; `AgentTools.swift:162`; `AgentFolders.swift:111-115`; `Lilo/App/BrowserContext.swift:837-840` | |
| I10 | Page-opened tabs and popups inherit the opener's folder or isolated space | `AgentFolders.swift:191-202`; `Lilo/Window/MainWindowController+Navigation.swift:373-375`, `:413-415` | |
| I11 | A tab leaving agent control drops capture, inspector, recording, dialog handler and emulated viewport | `AgentFolders.swift:404-437` | Only on leaving the union of all sessions (G14) |
| I12 | `gif_creator`, console, network and devtools state are keyed by tab and reached through `agentTab` | `AgentInteractionTools.swift:147`, `:157-158`, `:222-242`; `AgentDevTools.swift:470-473` | Same limit as G14 |
| I13 | Cookie `get`, `delete`, `clear` limited to hosts of the caller's tabs | `AgentDevTools.swift:236-240`, `:414`, `:419`, `:455` | The data store is still shared (G5); `set` is unscoped (G4) |
| I14 | Each `run` program uses its own non-persistent web view and calls tools as its own session | `AgentInteractionTools.swift:423-427`, `:486-488` | |
| I15 | Profile switch moves only the caller's folders, one Agents space per profile | `AgentFolders.swift:470-483`; `AgentProfiles.swift:137-140` | |
| I16 | `reset_profile` refused in a user profile and while another session has tabs in the Agents profile; wipe refused if a user space lives there | `AgentProfiles.swift:31`, `:42-49`, `:65-70` | See G12 |
| I17 | Per-connection MCP state: `requests`, `pendingReplies`, `waitingForUser`, `tabCalls`, authorization | `AgentControl.swift:753-786`; `AgentMCP.swift:18`, `:27` | |
| I18 | A different live process of the same signed app does not adopt a dropped session | `AgentControl.swift:663-664`; `LiloTests/Agent/AgentFoldersTests.swift:648` | Only while the old launcher pid is alive |

## 2. Global or race-prone today

### Shared stores

- **G1 Screenshots are global.** `screenshots` and `nextScreenshotNumber` live on `AgentControl` (`AgentControl.swift:81-82`); ids are sequential `screenshot_N` (`AgentScreenshot.swift:165-167`); `upload_image` looks up by id with no owner check and no consent (`AgentInteractionTools.swift:195-197`). Consequence: any session can exfiltrate another's capture, including a user-profile page.
- **G1b** The 20-entry cap is global FIFO (`AgentScreenshot.swift:168`) and the list clears only when no session at all is left (`AgentControl.swift:644`). Consequence: one tenant evicts another's handles, and images outlive their owner.
- **G2 Saved flows are one directory keyed by name only** (`AgentFlows.swift:220-232`). `flow_save` overwrites silently (`:284`); `flow_run` opens any name (`:339-340`). The SHA-256 is unkeyed and in the same file (`:277`, `:349`), so it detects hand edits, not replacement. Consequence: cross-tenant read through replay and cross-tenant poisoning.
- **G2b** Flows keep literal URLs, non-secret input values, typed text and fetch URLs (`AgentFlows.swift:129-131`, `:147`, `:168`, `:184`) and persist across runs. `run` does not check `tool` against `recordable` (`:371`, `:392`); no MCP tool path to plant such a file was found (writing one needs same-user filesystem access).
- **G3 Recordings** are control-global maps keyed by tab (`AgentControl.swift:78-79`). Access is tab-gated, so no direct cross-session read; the 256 MB bound is per tab with no global quota (`AgentInteractionTools.swift:570`). GIF export writes any chosen file name into the shared Downloads folder and replaces it (`:576-582`). Consequence: one tenant overwrites another's export.

### Cookies, profiles, wipe

- **G4 `cookies set` is unscoped (known bug, confirmed).** The `set` branch never reads `hosts` or calls `reachable`: `AgentDevTools.swift:431-447`, against `get` at `:419` and `delete`/`clear` at `:455`; the store is the tab's data store (`:240`). The tool description promises scoping only for the other three (`:86-88`). Consequence: session fixation or contamination for any domain in the shared Agents or a granted user profile.
- **G5 One persistent Agents profile for every independent session** (`AgentProfiles.swift:12-20`; `AgentControl.swift:762-763`; `AgentFolders.swift:224`). Cookies, storage, cache and history are common, so B navigates to a host and reads A's HttpOnly cookies via `cookies get` (`AgentDevTools.swift:416-430`). Non-GET `fetch` asks no consent there (`AgentTools.swift:282`).
- **G6 `profileId` is on `AgentSession`, not a tenant or task** (`AgentControl.swift:763`; `AgentProfiles.swift:140`). Subagents on one connection all move when one calls `switch_profile` (`AgentFolders.swift:470-483`).
- **G7 Profile grants are keyed `clientName|identity|profileId`** and persisted (`AgentProfiles.swift:123`, `:150-165`). Any later session with the same pair gets the user profile unasked. The question carries no executable, session or task (`AgentProfiles.swift:124`; `AgentControl.swift:405-425`). With an empty identity the grant is still saved (no `isEmpty` guard, `AgentProfiles.swift:134`), unlike connection approval (`AgentControl.swift:380`). `forgetProfileGrants` matches by prefix, so revoking `a` also drops a client named `a|b` (`AgentProfiles.swift:155`).

### Identity, consent, permissions

- **G8 Client identity is coarse.** It is the parent of `lilo-mcp` (`AgentControl.swift:300-310`), identified by signing id plus team, else path (`:318-325`). All agents behind one gateway, or all scripts under one interpreter, share one identity. `clientName` is self-declared (`AgentMCP.swift:47`).
- **G8b Connection consent is shared** by name plus identity (`AgentControl.swift:364-366`, `:388`): one answer admits every waiting connection. With an empty identity, different processes claiming one name share one question (key `name\n`).
- **G8c `alwaysAllowedSites` is one global list** (`AgentControl.swift:503-509`, written at `:622-625`, read at `:531-533`). "Always allow" answered for A removes the question for every client and session, sensitive actions and subdomains included (`AgentClientPermissions.swift:31`, `:41-43`).
- **G8d Per-client permission ignores identity and session:** keyed by app id or raw name (`AgentControl.swift:547`). `.always` granted for an app applies to any approved or token-admitted session using a name that maps to it. `revoke(name)` resets the app-wide entry (`:276`).
- **G8e Conversation token skips consent.** A matching `lilo/conversation` token authorizes with no identity check (`AgentMCP.swift:50-59`). The token is a per-conversation UUID (`Lilo/Conversations/ConversationHost.swift:88`) passed in the environment (`:400`, `:509`), so child processes inherit it. Whether unrelated same-user processes can read it is **unverified** (macOS process-environment visibility not tested). Several holders share one folder and the Space's profile.

### Session adoption (reconnect)

- **G9 Adoption criteria** (`AgentControl.swift:660-665`): same name and same pid (identity not compared), or same non-empty identity and the earlier pid dead. `handOver` moves folders, isolated space (its cookies), title, project, activity and `profileId` (`:667-676`).
- **G9a `resumeDroppedSession` takes the first matching dropped session** (`:651-654`), with no conversation or tenant key. With two dropped sessions of one identity, a reconnect can receive the other's tabs.
- **G9b `handToHeir` needs no reconnect.** At close, and every 500 ms in the grace period, any live matching session with no tabs inherits (`:678-686`, `:698`, `:705-708`). The heir may be older than the closed session (no `connectedAt` check), and its own `profileId` and `title` are overwritten.
- **G9c** One process holding several connections (a gateway) matches on pid, so closing logical agent A hands its state to idle agent B (`:662`, `:681`).
- `flow` and `flowName` are not handed over (`:667-673`), so a reconnect loses an open recording.

### Shared-connection races

- **G10 `session.title` is a mutable routing key** (`AgentControl.swift:769-770`; set at `AgentTools.swift:316-319`). Untitled `tabs_create_mcp` or `tabs_context_mcp` uses the last title from anyone on the connection (`AgentFolders.swift:82`).
- **G10b** The first title adopts the untitled folder, with whatever another caller put there (`AgentTools.swift:320-322`).
- **G10c** `agentTab`, `cookies` and `reset_profile` reload span all folders of the session (`AgentFolders.swift:256`; `AgentDevTools.swift:237`; `AgentProfiles.swift:75-80`), contrary to "conversations and subagents sharing one connection stay apart" (`AgentTools.swift:16`).
- **G10d** One isolated space (`AgentControl.swift:768`) and one flow recording (`:788`) per connection: B's calls are recorded into A's flow (`AgentMCP.swift:183`, `:189`) and B's `flow_save` ends it (`AgentFlows.swift:250-251`).
- Same title across two sessions: no folder collision (I3), but the folder name is only the title (`AgentFolders.swift:119`), so the user cannot attribute it, and the action log is per client name with no session id (`AgentActionLog.swift:28-38`, `:83`), including names that sanitize alike.

### Lifecycle, disclosure, host resources

- **G11 End-of-session wipe is racy and folder-based.** `end` schedules an async wipe when no remaining `profileId == nil` session has a folder (`AgentControl.swift:646`). A session creating its first folder between the check and the wipe (`AgentProfiles.swift:32`) can lose fresh state. Ordering inside WebKit is **unverified**.
- **G12 `reset_profile` counts only sessions with open tabs** (`AgentProfiles.swift:45-48`): a tenant between tabs loses its sign-ins. Check and wipe are separated by an `await` (`:70-72`) with no lock.
- **G13 `reset_profile` refusal leaks other tenants' folder names and idle time** (`AgentProfiles.swift:51-58`). `endedTabNumbers` and sequential tab numbers form a minor oracle (`AgentControl.swift:36-39`; `AgentFolders.swift:239-244`, `:262-266`). `list_profiles` shows every profile name and the user's current one to any authorized session (`AgentProfiles.swift:105-109`).
- **G14 Tab state survives a move between sessions' folders.** `refreshControlledTabs` acts only on the symmetric difference of the union set (`AgentFolders.swift:399-404`), so a tab the user drags from A's folder to B's keeps console/network capture, inspector rules, `initScript`, extra headers and recordings. A non-private user tab dragged into an agent folder becomes drivable (`:256`, `:282`).
- **G15 System pasteboard is shared:** `cmd+c`, `cmd+x`, `cmd+v` run the native commands on the tab's web view (`AgentInput.swift:231-253`, `:260-263`). That these use the general pasteboard is WebKit behavior, not shown in this repo. Consequence: tenant to tenant, and user to tenant, with no consent.
- **G16 Files:** screenshot `savePath` writes or replaces any absolute `.png` with no consent (`AgentScreenshot.swift:30-32`, `:150-160`). HAR, profile and heap files share one temp folder, and any save deletes day-old files of all sessions (`AgentDevTools.swift:394-405`). Reading them through MCP upload still asks the user (`AgentInteractionTools.swift:175`, `:199`).
- **G17 Debug only:** `window_capture` ignores the session and renders the active window (`AgentWindowCapture.swift:35-52`; `AgentTools.swift:307-309`).
- **Not audited / unverified:** `devtools_command` reach into cookies or storage beyond the tab (protocol surface not enumerated); stored site permissions shared by agent tabs (`Lilo/Window/MainWindowController+Navigation.swift:723` reads them before the agent denial); extensions in user profiles; WebContent process sharing.

## 3. Cross-tenant attack walkthroughs

A is the victim and B the attacker; both are authorized sessions.

1. **Screenshot theft.** A: `computer {action:"screenshot", tabId:a}` returns `screenshot_1`. B: `upload_image {imageId:"screenshot_1", tabId:b, ref:<file input>}`, then `javascript_tool` reads the file. Fails to stop: `AgentInteractionTools.swift:195-197` (no owner), `AgentScreenshot.swift:165`.
2. **Flow read.** A: `flow_start`, `form_input` a non-secret value into textbox "Phone", `flow_save {name:"checkout"}`. B: opens its own page with a "Phone" textbox, `flow_run {name:"checkout", tabId:b}`, reads the field. Fails to stop: `AgentFlows.swift:147`, `:339-340`, `:378-386`.
3. **Flow poisoning.** A saves `checkout`. B records different steps (a `navigate` to `https://b.example.com`) and calls `flow_save {name:"checkout"}`. A runs `flow_run`, executing B's steps in A's profile under A's approvals. Fails to stop: `AgentFlows.swift:284`, `:349`.
4. **Cookie fixation.** A works on `app.example.com` in the Agents profile. B, whose tab shows another host: `cookies {action:"set", tabId:b, cookie:{name:"sid", value:"b", domain:"app.example.com"}}`. A reloads and sends B's cookie. Fails to stop: `AgentDevTools.swift:431-447`.
5. **Cookie theft.** A signs in on `app.example.com`. B: `tabs_create_mcp`, `navigate` there, `cookies {action:"get", tabId:b}`. Fails to stop: shared store (`AgentProfiles.swift:12-20`); host filter satisfied by B's own navigation (`AgentDevTools.swift:238-239`).
6. **Adoption hijack.** A and B share identity and name; A's launcher has exited; B is connected with no tabs (or connects within the grace). A's socket closes. B: `tabs_context_mcp` lists A's tabs, with A's isolated cookies and user profile. Fails to stop: `AgentControl.swift:663-664`, `:678-686`, `:667-676`.
7. **Grant and site-approval reuse.** A: `switch_profile {profile:"P"}`, user allows. B (same name and identity): the same call returns with no question (`AgentProfiles.swift:123`). Variant: user ticks "always" for `shop.example.com` on A's click; B's sensitive click there asks nothing (`AgentControl.swift:622-625`, `:533`).
8. **Reset destroys an idle tenant.** A sets a cookie, then closes its tabs and stays connected. B: `reset_profile` succeeds; A's sign-in is gone. Fails to stop: `AgentProfiles.swift:45-49`.

Shared-connection variant (gateway): subagent A calls `tabs_create_mcp {title:"A"}`, B calls `tabs_create_mcp {title:"B"}`, A calls `tabs_create_mcp {}` and lands in B's group; B can drive any A tab number. Fails to stop: `AgentFolders.swift:82`, `:256`.

## 4. Suggested fixtures

Base: subclass `AgentToolTestCase` (window, private socket, `client`, `switchToUserProfile`). Add a second `AgentTestClient(path: socketURL)` and drive it with `initialize(name:)` and `callTool`. Allowed names are "Test Agent", "Codex", "claude-code" (`LiloTests/Agent/AgentToolTestCase.swift:9-12`). All test clients share the test process pid and identity, so use **different names** for independent tenants; use the same name plus a hand-set `session.clientPID` and `AgentControl.reconnectGrace` for adoption (`AgentFoldersTests.swift:613-646`). The base sets grace to zero (`AgentToolTestCase.swift:46`). Serve pages with `TinyHTTPServer`. Each fixture asserts the secure behavior, so it fails today.

| Fixture | Walk | Drive | Assert |
|---|---|---|---|
| `testAnotherSessionCannotUploadMyScreenshot` | 1 | A screenshot; B `upload_image` on a served file input | B gets an error; input has no file |
| `testAnotherSessionCannotRunMyFlow` | 2 | `flow_start`/`form_input`/`flow_save` on A; B `flow_run` | Error "No flow named"; B's field empty |
| `testSavingAFlowNameLeavesAnotherSessionsFlowAlone` | 3 | Both save one name; A runs | A's URL and values replay |
| `testCookiesSetReachesOnlyTheSitesOfTheAgentsTabs` | 4 | B `cookies set` for a foreign host; A opens it, `cookies get` | Refused; no cookie in store. `testCookiesReachOnlyTheSitesOfTheAgentsTabs` (`AgentDevToolsTests.swift:106`) sets an off-host cookie as setup and must be reseeded through the store |
| `testSessionsDoNotShareCookies` | 5 | A cookie set on the server host; B navigates same host, `cookies get` | A's value absent |
| `testAnIdleSameAgentSessionDoesNotInheritClosedTabs` | 6 | Two "Test Agent" clients live; set A `clientPID = 99_999`, grace 10 s, close A | B sees "No tab group exists yet" |
| `testAReconnectTakesItsOwnDroppedSession` | 6 / G9a | Drop two sessions, reconnect second | Gets its own tab numbers (needs a reconnect key that does not exist yet) |
| `testAProfileGrantStaysWithItsSession` | 7 | `switchToUserProfile(a)`; B `switch_profile` | `pendingConsentAnswers` non-empty |
| `testAlwaysAllowIsScopedToTheAskingAgent` | 7 | Consequential click by A, `answerConsent(id, granted:true, alwaysAllowSite:)`; B same click, other name | B is asked. Do not set `LILO_AGENT_CLICKS` |
| `testResetSparesAnIdleAgentsSignIns` | 8 | A cookie, close its tabs; B `reset_profile` | Refused, or A's cookie survives |
| `testUntitledCallsStayInTheCallersTask` | shared | Sequence on one client with a per-caller tenant parameter | Needs the tenant API; today only pins current behavior |
| `testResetRefusalNamesNoOtherAgentsTask` | G13 | B titled tab; A `reset_profile` | Reply omits B's title; update `AgentFoldersTests.swift:165`, which expects the name today |
| `testATabMovedBetweenAgentsDropsTheFirstOnesState` | G14 | `applyBrowserCommand(.moveSidebarItem)` as in `AgentIsolationTests.swift:44` | B sees no earlier console messages or mock rules |

Open design call (owner: maintainer): `testSessionsDoNotShareCookies` assumes per-tenant ephemeral storage becomes the default. If the shared Agents profile stays by design, drop it and walkthrough 5, and document the shared jar as intended.
