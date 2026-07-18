# Agent scope index

| Scope | Domain | Owned paths | Output | Examples |
| --- | --- | --- | --- | --- |
| [release-foundation](scopes/release-foundation/scope.json) | coordination foundation | agent contracts and ignore rules | release-foundation/v1 | valid roadmap; ignored key |
| [standalone-verifier](scopes/standalone-verifier/scope.json) | verifier and compilers | `tool/`, `references/`, `tests/verifier/`, `tests/egraph/`, `skill/` | kernel-verifier/v1 | accepted pipeline; rejected warning |
| [rational-quant](scopes/rational-quant/scope.json) | RQ8 package | `packages/rational-quant/`, `tests/rational-quant/` | rational-quant/v0.1 | exact scale; unsupported scale |
| [mirror-kernel](scopes/mirror-kernel/scope.json) | bounded compiler | `packages/mirror-kernel/`, `tests/mirror-kernel/` | mirror-kernel/v0.1 | exact cover; unsupported shape |
| [release-integration](scopes/release-integration/scope.json) | public release | public docs, CI, runners, reports | release-candidate/v1 | full local gate; secret rejection |
| [publish-alpha](scopes/publish-alpha/scope.json) | GitHub publication | no source paths; GitHub resource | public-release/v1 | pushed main; verified tag |

Roadmap: [`.agents/roadmap.json`](roadmap.json)

Handoff evidence: [`.agents/handoff.json`](handoff.json)

Dispatch readiness: `python3 ${CODEX_HOME}/skills/orchestrate-project-agents/scripts/dispatch_wave.py .`
