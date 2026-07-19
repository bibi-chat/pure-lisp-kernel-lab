# Agent scope index

| Scope | Domain | Owned paths | Output | Examples |
| --- | --- | --- | --- | --- |
| [release-foundation](scopes/release-foundation/scope.json) | coordination foundation | agent contracts and ignore rules | release-foundation/v1 | valid roadmap; ignored key |
| [standalone-verifier](scopes/standalone-verifier/scope.json) | verifier and compilers | `tool/`, `references/`, `tests/verifier/`, `tests/egraph/`, `skill/` | kernel-verifier/v1 | accepted pipeline; rejected warning |
| [rational-quant](scopes/rational-quant/scope.json) | RQ8 package | `packages/rational-quant/`, `tests/rational-quant/` | rational-quant/v0.1 | exact scale; unsupported scale |
| [mirror-kernel](scopes/mirror-kernel/scope.json) | bounded compiler | `packages/mirror-kernel/`, `tests/mirror-kernel/` | mirror-kernel/v0.1 | exact cover; unsupported shape |
| [release-integration](scopes/release-integration/scope.json) | public release | public docs, CI, runners, reports | release-candidate/v1 | full local gate; secret rejection |
| [publish-alpha](scopes/publish-alpha/scope.json) | GitHub publication | no source paths; GitHub resource | public-release/v1 | pushed main; verified tag |
| [hosted-ci](scopes/hosted-ci/scope.json) | hosted runtime reproducibility | workflow and regenerated acceptance report | hosted-ci/v1 | pinned SBCL; passing public run |
| [rq8_public_doc](scopes/rq8_public_doc/scope.json) | public RQ8 package boundary | package README only | rq8-public-doc/v0.1.0-alpha.1 | unary example; no serialization claim |
| [release_positioning](scopes/release_positioning/scope.json) | fair public evidence | root README, evidence docs, release notes, claim reports | release-positioning/v0.1.0-alpha.1 | Q8 baseline; bounded alpha.1 notes |
| [publish_alpha1](scopes/publish_alpha1/scope.json) | corrected GitHub publication | coordinator-owned Git and GitHub resources | public-release/v0.1.0-alpha.1 | passing merge; immutable tag; profile pin |

Roadmap: [`.agents/roadmap.json`](roadmap.json)

Handoff evidence: [`.agents/handoff.json`](handoff.json)

Dispatch readiness: `python3 "${CODEX_HOME}/skills/orchestrate-project-agents/scripts/dispatch_wave.py" .`
