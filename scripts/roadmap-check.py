#!/usr/bin/env python3
"""Validate the public roadmap without requiring a private Codex skill install."""

from __future__ import annotations

from collections import defaultdict, deque
import json
from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parents[1]
ROADMAP = ROOT / ".agents" / "roadmap.json"
VALID_KINDS = {"goal", "subgoal", "step"}
VALID_STATUSES = {"pending", "in_progress", "done", "active"}


def fail(message: str) -> None:
    raise ValueError(message)


def validate(payload: object) -> dict[str, object]:
    if not isinstance(payload, dict):
        fail("roadmap root must be an object")
    if payload.get("schema") != "agent-roadmap/v1":
        fail("unsupported roadmap schema")
    nodes = payload.get("nodes")
    edges = payload.get("edges")
    if not isinstance(nodes, list) or not isinstance(edges, list):
        fail("nodes and edges must be arrays")
    by_id: dict[str, dict[str, object]] = {}
    for node in nodes:
        if not isinstance(node, dict) or not isinstance(node.get("id"), str):
            fail("every node needs a string id")
        node_id = node["id"]
        if node_id in by_id:
            fail(f"duplicate node id: {node_id}")
        if node.get("kind") not in VALID_KINDS:
            fail(f"invalid node kind: {node_id}")
        if node.get("status") not in VALID_STATUSES:
            fail(f"invalid node status: {node_id}")
        by_id[node_id] = node
    main_goal = payload.get("mainGoalId")
    if main_goal not in by_id or by_id[main_goal].get("kind") != "goal":
        fail("mainGoalId must reference a goal")

    precedes: dict[str, set[str]] = defaultdict(set)
    predecessors: dict[str, set[str]] = defaultdict(set)
    indegree = {node_id: 0 for node_id in by_id}
    for edge in edges:
        if not isinstance(edge, dict):
            fail("every edge must be an object")
        source = edge.get("from")
        target = edge.get("to")
        relation = edge.get("relation")
        if source not in by_id or target not in by_id:
            fail("edge references an unknown node")
        if source == target:
            fail("self edges are forbidden")
        if relation == "precedes" and target not in precedes[source]:
            precedes[source].add(target)
            predecessors[target].add(source)
            indegree[target] += 1

    queue = deque(sorted(node_id for node_id, degree in indegree.items() if degree == 0))
    visited = 0
    while queue:
        source = queue.popleft()
        visited += 1
        for target in sorted(precedes[source]):
            indegree[target] -= 1
            if indegree[target] == 0:
                queue.append(target)
    if visited != len(by_id):
        fail("precedes edges contain a cycle")

    next_steps = []
    for node_id, node in by_id.items():
        if node.get("kind") != "step" or node.get("status") == "done":
            continue
        if all(by_id[parent].get("status") == "done" for parent in predecessors[node_id]):
            next_steps.append(node_id)
    return {
        "schema": "roadmap-check/v1",
        "valid": True,
        "nodes": len(nodes),
        "edges": len(edges),
        "nextStepIds": sorted(next_steps),
    }


def main() -> int:
    try:
        payload = json.loads(ROADMAP.read_text(encoding="utf-8"))
        print(json.dumps(validate(payload), separators=(",", ":")))
        return 0
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"roadmap check: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
