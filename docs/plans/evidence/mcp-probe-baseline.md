# MCP probe baseline

Measured on 2026-11-26 with `bench/mcp/probe.py --reps 3 --concurrency 1,4,8 --timeout 90` against the installed release build's `lilo-mcp`. The probe uses only `data:` pages and closes the agent tabs it creates. Raw rows were written to the git-ignored `bench/mcp/results/probe-2026-11-26T203118Z.jsonl`.

## Result

| Measure | 1 bridge | 4 bridges | 8 bridges | Product consequence |
| --- | ---: | ---: | ---: | --- |
| `tools/list` payload | 35,694 bytes, about 8,923 tokens, 35 tools | same | same | The schema tax is fixed per client and dominates small tasks. Reducing the tool surface is the largest token lever. |
| `navigate` p50 | 707 ms | 712 ms | 701 ms | Page settling dominates navigation and does not degrade under this modest concurrency. Shorter or asynchronous settle semantics are the latency lever. |
| screenshot result mean | about 67,050 bytes, p50 25.8 ms | about 67,050 bytes, p50 37.2 ms | about 67,051 bytes, p50 44.8 ms | Screenshot payloads are the largest per-call transport cost and scale linearly with concurrency. |
| `read_page` p50 | 6.2 ms | 6.9 ms | 5.0 ms | Page reads are cheap on the small probe page. |
| errors | 0 | 0 | 0 | No contention failure appeared at eight independent bridge processes for this workload. |

The largest tool descriptions in the schema payload were `computer` (1,466 characters), `performance` (1,389), `network_mock` (1,122), `flow_start` (847) and `tabs_context_mcp` (741). Descriptions account for 14,736 characters of the 35,694 byte payload; the rest is mostly parameter schema. Editing prose alone cannot remove most of the tax. The high-return direction is fewer or progressively exposed tool schemas, not prose compression.

## Decisions this evidence supports

1. Treat schema-surface reduction as higher ROI than further micro-optimizing individual fast tools.
2. Do not prioritize a process or connection scalability rewrite yet: eight concurrent bridge processes completed this workload without errors and with only modest p90 degradation.
3. Investigate screenshot artifact references or visual payloads separately from model quality, because transport bytes are measurable even when image token cost is client-specific.
4. Before changing long-running call deadlines, measure real pages rather than inferring from the probe's small `data:` page. The probe already shows that the fixed settle wait, not multi-client lock contention, dominates its navigation latency.
