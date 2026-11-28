# Multi-agent roadmap

Roadmap for making Lilo the OSS reference for multi-agent browser workflows. Companion to [AGENT-HARNESS-PLAN.md](../AGENT-HARNESS-PLAN.md), [agent-plugin-research.md](agent-plugin-research.md), [plugin-surface-plan.md](plugin-surface-plan.md), [agents-settings.md](agents-settings.md) and [agents-config-and-headless.md](agents-config-and-headless.md).

Date: 2026-11-26. This is a plan only; it changes no product behavior by itself.

This is a learning-first implementation plan. The stages are decision gates, not calendar phases. A stage can be repeated, shortened or stopped when its evidence says the design is wrong.

## 1. Product position

Lilo becomes the OSS reference for multi-agent browser workflows by owning the browser control plane:

- explicit tenants, run groups, runs and conversations;
- intentional shared or isolated browser state;
- consent, capabilities, quotas and tab ownership;
- durable run observability and audit;
- equal semantics across external MCP, in-browser ACP and headless execution.

Lilo does not become a full persistent-companion platform. Memory, model routing, SaaS connectors, scheduling and rich bot identity remain external orchestrator or plugin concerns.

The short version:

> MCP and headless are the reference runtime. In-browser ACP is the reference cockpit. Bots and companions are plugins or integrations.

## 2. Product principles

1. **Evidence before expansion.** Every large feature starts with a fixture, prototype, spike or dogfood script.
2. **Isolation before cooperation.** Shared workspaces are meaningful only after isolated tenants are enforceable.
3. **Visibility before autonomy.** Headless and long-running work require stronger audit, not weaker oversight.
4. **Conformance before claims.** Lilo is a reference only when external harnesses can run the same tests.
5. **One control plane.** MCP, ACP and headless are adapters over the same tenant, policy and audit semantics.
6. **Plugins for platform breadth.** Scheduling, memory, connectors and agent-team extras should not enter core until two independent consumers need the same host capability.
7. **Local and private measurement.** Product learning uses local redacted events, fixtures, fake data and explicit dogfooding. No page content, credentials or real user data belong in reports.

## 3. Shift-left operating loop

Every stage uses the same loop:

1. Write the assumption as a falsifiable statement.
2. Build the cheapest artifact that can disprove it.
3. Test with a deterministic fixture, fakeHost prototype, local dogfood workflow or external integration spike.
4. Record the result and decision in the assumption register.
5. Proceed, narrow, pivot or stop.

The purpose is to catch product and architecture flaws while they are still documents, fixtures or prototypes rather than Swift, Svelte, localization and migration work.

## 4. Canonical learning workflows

Use four canonical workflows throughout the roadmap. They are the product test cases, not just benchmark tasks.

| Workflow | Shape | What it teaches |
|---|---|---|
| Parallel research | Several independent agents research separate questions at once | Isolation, resource use, consent load, tab grouping, time to answer |
| Orchestrated implementation | One orchestrator delegates implementation and verification subtasks | Shared workspaces, handoff, run groups, cooperative visibility |
| Persistent monitor | A recurring job checks a site or dashboard and reports changes | Headless audit, durable identity, scheduling boundary, profile continuity |
| Sensitive credential task | An agent uses a signed-in site for a bounded operation | User-profile leases, credential projection, consent comprehension, revocation |

Each workflow should exist in three forms as soon as feasible:

- a deterministic local fixture using made-up sites;
- a dogfood script against safe test accounts or local services;
- a user-facing prototype scenario with fake data.

## 5. Assumption register

Create the register before implementation. Initial entries:

| ID | Assumption | Cheapest test | Pivot signal |
|---|---|---|---|
| A1 | Independent parallel tasks are more common than cooperating subagents | Workflow inventory and dogfood scripts in stage 0 | Cooperative work dominates, so shared workspaces move earlier |
| A2 | "Workspace" is clearer to users than "tenant" | fakeHost copy prototype in stage 1 | Users cannot explain what a workspace shares; test task, team or session language |
| A3 | Users mean credential reuse when they ask to share a profile | Profile-mode comprehension test | Users expect full live-state continuity, requiring a different product explanation or lease model |
| A4 | External harnesses will pass stable tenant/run IDs if given a simple contract | Bifrost, coordinate and ACP integration spikes | Harnesses cannot or will not pass IDs, so Lilo must key tenancy by upstream connection only |
| A5 | A visible cockpit reduces unsafe autonomy | Before/after dogfood measurement of time to notice and stop bad behavior | Users ignore the cockpit, so approval and notification design need redesign |
| A6 | A declarative team manifest covers the useful part of Strawberry-style teams | Paper manifest review plus a thin prototype | Users need scheduling, memory and connectors before teams feel useful, confirming plugin boundaries |
| A7 | Shared-app tenant isolation is sufficient for most local workflows | Conformance and scaling fixtures | Repeated isolation or process-blast-radius failures justify process/container tiers earlier |
| A8 | Headless parity is acceptable to users if run history is inspectable | Headless dogfood plus ledger review | Users distrust invisible work, requiring stronger notifications or visible-by-default behavior |
| A9 | The browser should not own scheduling | Coordinate/plugin spike | Scheduling is inseparable from the cockpit value proposition, forcing a narrow core scheduler decision |
| A10 | A2A messaging can remain external | Agent Relay/coordinate integration spike | Browser-side handoff requires messages as a host capability, not just external chat |

Keep this register in the plan or repo design doc and update it whenever a stage ends.

## 6. Stage overview

| Stage | Goal | Main artifact | Gate |
|---|---|---|---|
| 0 | Understand current behavior and real workflows | Baseline evidence pack | Primary workflows and top risks chosen |
| 1 | Validate product language, UX and threat model | Prototype plus conformance design | Users understand sharing and control; severe threats have answers |
| 2 | Fix isolation hotbugs with tests first | Security conformance harness | Zero cross-tenant fixture violations |
| 3 | Implement minimal tenant/run control plane | Shared identity, ledger and lifecycle | MCP, ACP and headless produce equivalent records |
| 4 | Make MCP/headless the reference runtime | Integration guide and conformance report | External harnesses pass isolation and scaling fixtures |
| 5 | Build the in-browser cockpit MVP | Active/recent workspace UI | Users can see, understand and stop multi-agent work quickly |
| 6 | Add cooperative teams through thin core plus plugins | Team manifest and plugin boundary | Cooperation is useful without turning Lilo into a bot platform |
| 7 | Harden, scale and publish the OSS reference | Versioned contract and public conformance suite | Independent harnesses reproduce the reference results |

Stages 0 and 1 must happen before substantial implementation. Stages 2 to 4 can overlap only after their stage gates are clear. Stage 5 can start as a prototype early, but its production implementation waits for the control-plane data model. Stage 6 should not start before isolated tenancy is real.

## 7. Stage 0: evidence and baseline

### Objective

Understand what happens today, which workflows matter, and where the current product already fails.

### Work

1. Write the four canonical workflows as runnable scripts against the current MCP, ACP and headless surfaces.
2. Run them with made-up local sites and safe test accounts. Capture current failures without fixing them.
3. Instrument existing sessions locally and redacted: client identity, connection count, folder/space use, profile mode, tab count, consent prompts, errors, cancellations, run duration and overlapping actions.
4. Reproduce known cross-session risks in deterministic fixtures: shared Agents profile state, global screenshot handles, global saved flows, broad consent grants and ambiguous client renaming.
5. Inventory integration constraints:
   - whether Bifrost can key upstream stdio connections by downstream tenant/run;
   - what stable IDs coordinate already provides;
   - what identity ACP conversations can supply at creation;
   - whether Agent Relay-style systems need anything beyond tenant/run IDs;
   - which parts of [agents-config-and-headless.md](agents-config-and-headless.md) are already landed, especially parked-tab throttling, background-host mode and windowless consent.
6. Collect product evidence from target users or maintainers where possible. For a solo/OSS project, structured dogfooding plus conversations with harness maintainers is enough at this stage.
7. Produce a terminology test: agent, task, run, session, workspace, team, tenant. Do not settle implementation names before testing comprehension.

### Artifacts

- `baseline evidence pack`: workflow recordings or traces, failure list and current overhead measurements. First entry: [evidence/tenant-isolation-audit.md](evidence/tenant-isolation-audit.md), a static audit of what the agent surface already isolates (per-session folders, isolated spaces, host-scoped cookie reads) and where it leaks (unscoped `cookies set`, global screenshot and flow stores, same-identity grants and adoption, shared-connection title races), with file:line evidence, eight attack walkthroughs and a fixture list.
- Assumption register v1.
- Terminology map.
- External integration constraint matrix.

### Measures

- number of concurrent sessions that collapse into one effective tenant today;
- time required to answer "which agent did this?" from existing logs;
- number of reproduced cross-session leakage or ownership failures;
- consent prompts per workflow and per completed task;
- memory/process growth for 1, 4, 8 and 16 lightweight concurrent sessions;
- frequency of credential reuse needs across the four workflows.

### Exit gate

Proceed when the two highest-value workflows are chosen explicitly and the top security/product flaws are reproduced rather than merely suspected.

### Pivot or stop conditions

- If independent parallel work dominates, delay shared-workspace UI and prioritize isolation/scale.
- If cooperative work dominates, move shared tenant semantics into stage 3 rather than stage 6.
- If credential sharing is the central blocker, prioritize the profile-mode spike before broad cockpit work.

## 8. Stage 1: product and adversarial design validation

### Objective

Catch UX, terminology, trust and threat-model flaws before building the control plane.

### Work

1. Build a fakeHost or static prototype of the Agents menu as an active/recent workspace list. Use fake agents, fake hosts and fake runs.
2. Test three cockpit variants:
   - agent-centric list;
   - workspace-centric list;
   - run-centric timeline.
3. Test user comprehension with small tasks:
   - Which agent is acting?
   - Which agents share cookies?
   - What happens when I stop this workspace?
   - What did this run change?
   - What is waiting for approval?
4. Write the tenant/run state machine: created, active, waiting for user, paused, completed, failed, cancelled, expired, cleaned up.
5. Write abuse cases before APIs:
   - prompt-injected agent attempts lateral movement;
   - malicious client forges tenant metadata;
   - one tenant floods consent prompts;
   - an agent uses a leaked tab id;
   - two agents race to use one live profile;
   - a headless job runs after the user forgets it;
   - durable permissions accumulate beyond their original task.
6. Draft conformance fixtures before implementation, including negative tests.
7. Prototype profile-mode copy with simple examples:
   - isolated temporary workspace;
   - shared team workspace;
   - durable agent profile;
   - user profile lease;
   - projected sign-in.
8. Review two or three declarative Agent Team manifests with potential users and external harness authors. Do not implement them yet.

### Artifacts

- Cockpit prototype with before/after copy variants.
- Tenant/run lifecycle diagram.
- Threat model v1.
- Conformance fixture specification v1.
- Profile-mode matrix.
- Team manifest examples and feedback.

### Measures

- percentage of test participants or dogfood reviewers who correctly identify sharing boundaries;
- time to find the waiting approval;
- time to stop the correct workspace;
- number of high-severity abuse cases without a mitigation or explicit non-goal;
- copy comprehension failures by term.

Targets can be strict because the sample is small: any consistent confusion about shared cookies, live-profile use or stop behavior is a design failure, not a rounding error.

### Exit gate

Proceed when:

- workspace language is understandable or replaced;
- every high-severity abuse case has a mitigation or explicit non-goal;
- conformance fixtures cover the critical negative cases;
- the two canonical workflows can be represented in the proposed model without special cases.

### Pivot or stop conditions

- If users cannot reason about tenant/profile modes, simplify to three modes and hide advanced projection.
- If the workspace metaphor fails, test task-centric or team-centric language before implementation.
- If trusted tenant metadata cannot be made understandable to integrators, simplify to connection-per-tenant as the only supported secure topology.

## 9. Stage 2: security foundation and conformance harness

### Objective

Fix the highest-risk isolation bugs with tests first. Do this before adding team features or more parallelism.

### Work

1. Implement the conformance runner in `bench/mcp` or the appropriate existing harness location.
2. Add deterministic local fixtures for:
   - cross-tenant cookie reads and writes;
   - `cookies set` host escaping;
   - cross-tenant tab mutation through leaked ids;
   - global screenshot artifact access;
   - cross-tenant flow access;
   - consent grant leakage;
   - client rename after initialization;
   - unsafe session adoption;
   - concurrent JSON-RPC id collision behavior.
3. Fix the hotbugs already identified in the v2 plan:
   - scope `cookies set`;
   - namespace screenshots, flows and artifacts;
   - make consent and profile grants tenant-aware;
   - freeze client/tenant identity after initialization;
   - tighten reconnect and adoption rules;
   - separate shared-connection request namespaces.
4. Extend the redacted action log schema only as needed to support the fixtures. Do not log content or secrets.
5. Keep these changes small and upstreamable where possible. They are correctness and security fixes, not the full multi-agent product.

### Artifacts

- Multi-agent conformance harness v0.
- Security hotfix series.
- Red-team fixture results.

### Measures

- cross-tenant cookie read count;
- cross-tenant tab mutation count;
- cross-profile action count;
- consent grant leakage count;
- fixture runtime and flake rate;
- benchmark cost/time regression from the fixes.

### Exit gate

Zero cross-tenant violations in the deterministic fixtures, with repeated passes. Flaky isolation is a failing gate, not a test problem to hide.

### Pivot or stop conditions

If ephemeral spaces or shared process architecture cannot satisfy the fixture requirements, escalate the high-isolation process/container tier earlier and narrow the claims made for shared-app isolation.

## 10. Stage 3: minimal tenant/run control plane

### Objective

Introduce the shared identity, lifecycle and record model used by all surfaces, without yet building the full cockpit or team system.

### Work

1. Implement explicit `Tenant`, `RunGroup`, `Run` and optional `Conversation` identity.
2. Define which component is authoritative for each identity:
   - ACP host-created identity for in-browser conversations;
   - connection-derived identity for direct MCP clients;
   - trusted gateway-injected identity for approved shared gateways;
   - job/run identity passed through headless launch or coordinate integration.
3. Add a durable run ledger. Spike JSONL versus SQLite before deciding:
   - JSONL is simpler and matches current logs;
   - SQLite is better for querying concurrent runs and retention;
   - choose only after measuring write contention, query needs and migration cost.
4. Implement lifecycle transitions, cancellation, cleanup and retention.
5. Add per-tenant quotas for tabs, concurrent tool calls, artifacts and consent prompts.
6. Implement initial profile modes:
   - isolated ephemeral tenant;
   - explicit shared tenant;
   - exclusive user-profile lease.
7. Keep durable per-tenant profiles and credential projection behind spikes until evidence shows they are needed.
8. Bind MCP, ACP and headless entry points to the same ledger and lifecycle events.

### Artifacts

- Control-plane implementation behind a feature flag or debug setting.
- Identity contract draft.
- Run ledger v1.
- Lifecycle and cleanup tests.

### Measures

- overhead per tool call and per run creation;
- equivalence of ledger records across MCP, ACP and headless;
- cleanup correctness after normal completion, cancellation, crash and browser restart;
- consent queue behavior under per-tenant floods;
- memory/process scaling before and after quotas.

Initial performance target: no meaningful median fixture-time regression beyond a small agreed budget, measured rather than assumed. If overhead is visible, reduce work before expanding the surface.

### Exit gate

MCP, ACP and headless runs produce equivalent tenant/run records and pass the isolation fixtures. Cleanup is deterministic. Identity cannot be rewritten after creation.

### Pivot or stop conditions

- If the ledger query requirements are trivial, stay with the simpler storage design.
- If shared tenant semantics create too many edge cases before cooperation is needed, implement the model internally but expose only isolated mode at first.
- If trusted gateway identity cannot be implemented safely, support only connection-per-tenant and document the limit.

## 11. Stage 4: MCP and headless reference runtime

### Objective

Make the external runtime good enough that other harnesses can treat Lilo as the reference browser layer. This stage extends [agents-config-and-headless.md](agents-config-and-headless.md); it does not create a second headless architecture.

### Work

1. Implement or specify the preferred topology: one upstream `lilo-mcp` connection per tenant/run.
2. For shared connections, implement trusted tenant metadata only from approved local gateways. Never trust tenant labels supplied directly by arbitrary clients.
3. Add job handles for long-running operations and consent waits where the 30-second client timeout problem applies.
4. Reuse the headless work stream already planned in [agents-config-and-headless.md](agents-config-and-headless.md): parked-tab throttling, background-host mode, windowless consent and resource posture. The multi-agent work here is to bind those modes to the same tenant, quota and ledger code path as visible mode.
5. Integrate coordinate as the reference durable execution queue:
   - coordinate supplies job/run identity;
   - Lilo records browser tenant/run state;
   - completion events link back to ledger entries.
6. Publish a minimal integration guide for external orchestrators.
7. Add caching only after measurement:
   - static schema/generated binding cache;
   - very short revision-keyed snapshot dedupe;
   - tenant-scoped artifact references;
   - no cross-tenant authenticated cache.
8. Benchmark realistic concurrency at 1, 4, 8 and 16 agents using paired tasks.

### Artifacts

- External integration guide.
- Bifrost or gateway reference patch/specification.
- Headless parity test results.
- Coordinate recipe.
- Conformance report v1.

### Measures

- cost per fully successful task;
- isolation violations;
- infrastructure-error rate separated from agent failure;
- p50/p90 latency per tool call;
- memory and WebContent process scaling;
- consent wait behavior past client timeouts;
- cache hit rate, stale-read rate and incorrect-action rate.

### Exit gate

At least two independent harness shapes can drive concurrent isolated workflows through the documented interface and pass conformance. Headless and visible runs produce equivalent safety records.

### Pivot or stop conditions

- If external harnesses cannot key connections or pass stable identity, narrow the officially supported topology rather than pretending identity is safe.
- If caching produces any stale-action failures in fixtures, disable semantic caching and keep only schema/artifact optimizations.
- If process-pool blast radius dominates at realistic workloads, narrow concurrency claims and evaluate stronger isolation earlier.

## 12. Stage 5: in-browser cockpit MVP

### Objective

Make multi-agent work visible and controllable in Lilo without turning Lilo into an orchestrator.

### Work

1. Upgrade the Agents menu/button into active and recent workspaces.
2. Show for each workspace:
   - display name and agent/client;
   - state and current action;
   - waiting approvals;
   - profile/sharing mode;
   - tab count and current hosts;
   - run age and cost-driving activity where available;
   - errors and end state.
3. Add workspace actions: reveal tabs, answer approval, pause where meaningful, stop, open redacted log, clean up artifacts.
4. Link browser history entries to run IDs without inserting operational records into normal browsing history.
5. Bind ACP conversations to trusted tenant/run identity at creation.
6. Improve consent presentation for concurrent agents:
   - per-workspace queues;
   - sensitive actions clearly separated;
   - bulk deny for a tenant;
   - no cross-tenant global prompts hidden behind one generic approval.
7. Use fakeHost capture scenarios before implementing the full UI. Validate copy, grouping and empty states first.

### Artifacts

- Cockpit MVP.
- Agent workspace history view.
- Consent triage UI.
- UI capture evidence in light and dark modes when PRs are created.

### Measures

- time to identify which agent is acting;
- time to find and answer the correct approval;
- time to stop the correct workspace;
- mistaken approval or stop rate in dogfooding;
- number of user complaints/confusions about sharing and profile state;
- idle CPU/memory cost of the cockpit when no agents run.

### Exit gate

A user can answer these quickly and correctly:

- what is running;
- what is waiting;
- what shares state;
- what changed;
- how to stop it.

The cockpit must cost nothing visible at idle. If it polls or keeps work alive merely to display status, redesign it.

### Pivot or stop conditions

- If the cockpit becomes an orchestrator feature magnet, freeze scope and move scheduling/team management ideas to plugin design.
- If users do not understand workspace state even after copy iteration, simplify the visible model and keep advanced tenancy mostly internal.

## 13. Stage 6: cooperative teams and plugin ecosystem

### Objective

Support orchestrator/subagent collaboration and Strawberry-like team clarity without absorbing the bot platform into core. This stage builds on [plugin-surface-plan.md](plugin-surface-plan.md); it must not grow a parallel plugin, scheduler or connector architecture.

### Work

1. Finalize explicit shared-tenant workspace semantics:
   - who can join;
   - what tabs/artifacts are shared;
   - how handoff works;
   - what consent scope means inside the shared tenant;
   - how membership ends.
2. Implement tab handoff as an explicit operation rather than implicit access through global tab ids.
3. Prototype the Agent Team manifest:
   - roster;
   - driver references;
   - tenant modes;
   - workspace grouping;
   - resource limits;
   - consent defaults.
4. Build the thinnest launcher needed to instantiate a team from ACP agents. Keep memory, model routing and scheduling outside.
5. Build or specify an Automations/Teams plugin that uses coordinate for schedules and durable execution, following the capability, manifest, deadline and manager-panel rules in [plugin-surface-plan.md](plugin-surface-plan.md).
6. Evaluate Agent Relay or similar A2A messaging externally. Integrate identity references, but do not implement a messaging fabric in Lilo core unless two independent consumers prove it is necessary.
7. Let external platforms such as OpenMausBot/OpenBots/Orca-style systems create or attach to Lilo workspaces through the documented runtime interface.

### Artifacts

- Shared workspace conformance fixtures.
- Agent Team manifest draft.
- Team launcher prototype or plugin.
- External A2A integration assessment.

### Measures

- successful cooperative completion rate versus isolated baseline;
- number of accidental cross-agent accesses prevented by explicit handoff;
- user comprehension of shared versus isolated tenants;
- overhead of team startup and cleanup;
- percentage of team use cases that require only the manifest versus requiring platform features Lilo intentionally does not own.

### Exit gate

Cooperative agents provide measurable value over isolated parallel agents in the canonical orchestrated workflow, without weakening isolation guarantees outside the explicit shared tenant.

### Pivot or stop conditions

- If cooperation mostly means messaging rather than shared browser state, keep Lilo workspace integration minimal and let external messaging tools solve it.
- If users expect persistent memory/schedules before teams are useful, keep teams as a plugin/ecosystem feature rather than moving the platform into core.
- If shared tenancy creates frequent consent confusion, expose only isolated multi-agent mode in the cockpit and treat shared tenancy as an advanced integration mode.

## 14. Stage 7: hardening, scale and public reference release

### Objective

Turn the implementation into a credible OSS reference other projects can adopt and test against.

### Work

1. Version the tenant/run/workspace contract.
2. Publish the conformance suite with clear setup instructions and deterministic fixtures.
3. Add security review passes:
   - metadata forgery;
   - consent bypasses;
   - artifact leakage;
   - adoption/reconnect abuse;
   - cross-profile actions;
   - headless permission drift.
4. Add stress and resource tests:
   - 1, 4, 8 and 16 concurrent runs;
   - long-running sessions;
   - crash and restart cleanup;
   - large pages, screenshots and snapshots;
   - consent flood and cancellation storms.
5. Decide on durable per-tenant profiles and credential projection based on measured workflow need.
6. Decide whether a high-isolation process/container tier is required for high-autonomy or untrusted workloads.
7. Define what is upstreamable, what remains fork-first and what remains plugin-only.
8. Write the public architecture guide and external orchestrator examples.

### Artifacts

- Versioned architecture contract.
- Public conformance suite.
- Security model document.
- Performance and scaling report.
- Reference integrations.
- Maintainer-facing upstream/fork split.

### Measures

- zero critical isolation failures across repeated conformance runs;
- pass^k and flake rate for multi-agent fixtures;
- cost per fully successful task;
- memory/process growth;
- time to first user-visible status;
- time to stop a run;
- documentation success rate for an external integrator.

### Exit gate

An independent harness can follow the guide, run the conformance suite and reproduce the key safety and concurrency results without private knowledge of Lilo internals.

## 15. Cross-stage measurement model

Use four measurement lanes consistently.

### Safety

- cross-tenant cookie reads/writes;
- cross-tenant tab mutations;
- cross-profile actions;
- consent grant leakage;
- forged identity acceptance;
- incorrect session adoption;
- unsafe retry after `possibleCommit`.

These are hard gates. A fast or cheap system with any violation fails.

### Product comprehension

- time to identify the active agent;
- time to locate pending consent;
- time to stop the right workspace;
- correct understanding of what is shared;
- correct understanding of what headless means;
- mistaken stops, approvals or credential assumptions.

These are product gates. If users cannot understand the model, the implementation does not matter.

### Reliability and cost

- strict full success;
- weighted partial score;
- pass@k and pass^k;
- false-completion rate;
- correct-stop rate;
- infrastructure-error separation;
- cost per fully successful task;
- input/cache/output tokens and observation size;
- wall time and tool latency.

These compare implementation variants fairly.

### Resource and scale

- memory per tenant/run;
- WebContent process count;
- CPU at idle and under load;
- artifact disk use;
- cleanup completeness;
- consent throughput;
- behavior at 1, 4, 8 and 16 concurrent runs.

These determine whether shared-app tenancy remains the right default.

## 16. Fork and upstream strategy

Separate work into three tracks from the start.

### Upstreamable early

- security and correctness hotfixes;
- deterministic fixture infrastructure where acceptable;
- small consent scoping improvements;
- action-log metadata that is clearly useful;
- bug fixes with focused repro cases.

### Fork-first experimental

- tenant/run control plane;
- cockpit workspace UI;
- multi-agent headless parity experiments;
- background-host and windowless-consent behavior where [agents-config-and-headless.md](agents-config-and-headless.md) already marks them fork-first;
- Bifrost gateway topology;
- team manifest prototypes;
- scaling and caching experiments.

### Plugin or external only

- scheduling and recurring work;
- durable team execution;
- connectors;
- memory systems;
- richer bot identity/personality;
- A2A messaging;
- marketplace or registry concepts.

This protects upstream review load and avoids presenting a large speculative architecture before the evidence exists.

## 17. First concrete backlog

The first work items should be small and evidence-producing:

1. Create the assumption register and canonical workflow scripts.
2. Instrument current MCP/ACP/headless sessions enough to produce a baseline tenant-collapse report.
3. Build deterministic fixtures reproducing shared Agents profile leakage and global artifact access.
4. Implement the `cookies set` host-scoping hotfix with tests.
5. Prototype three cockpit information architectures in fakeHost using fake data.
6. Write tenant/run lifecycle and abuse-case document v1.
7. Audit the current state of the headless stream in [agents-config-and-headless.md](agents-config-and-headless.md) and record which multi-agent assumptions it already satisfies.
8. Spike trusted identity propagation through ACP conversation creation and one external MCP path.
9. Spike Bifrost connection-per-tenant behavior and document the result.
10. Spike run ledger storage: JSONL versus SQLite, measured on concurrent writes and simple queries.
11. Draft coordinate job/run ID integration using one headless canonical workflow.
12. Run the first 1/4/8/16 concurrency scaling probe after fixtures exist, not before.
13. Review results and update the roadmap before implementing the full control plane.

## 18. What not to build yet

Do not build these until their stage evidence says otherwise:

- persistent semantic agent memory in core;
- a scheduling or cron system in Lilo core;
- connector marketplace or account integrations;
- rich bot personalities or social roster;
- an A2A messaging network;
- durable per-tenant profiles for every agent by default;
- credential projection for all sites;
- process-per-agent isolation as the default;
- semantic browser-result caching across tenants;
- a full team manifest implementation before isolated tenancy passes conformance.

## 19. Decision cadence

At the end of each stage, produce a short decision note:

- what was learned;
- which assumptions were confirmed, weakened or disproved;
- what changed in the architecture;
- what should be built next;
- what should explicitly not be built;
- whether the stage gate passed.

This keeps the plan iterative and prevents the final architecture from becoming a large upfront bet.
