# LOAT/0.1 — Ledger of All Things Protocol Spec

**Status:** Draft. Reference document for Cortex architecture.
**Origin:** Challenger pass session 2026-04-08. Synthesized from two independent spec drafts (Opus-tier and fast-tier models).

---

## One-Page Summary

**One table. Two types. Append-only. Observer-indexed.**

The LOAT is a data model for recording things and their relationships, from the perspective of specific observers, without collapsing different observers' views into a single canonical record.

---

## Schema

```sql
CREATE TABLE loat (
  id          TEXT PRIMARY KEY,    -- ULID (time-sortable, globally unique)
  type        INTEGER NOT NULL,    -- 0 = pier, 1 = beam
  kind        TEXT,                -- pier: person|place|project|concept|event|state|capture|text|trace
                                   -- beam: corrects|relates_to|is_part_of|caused|observed_during|contradicts|tombstone
  content     TEXT,                -- payload (markdown, JSON, plain text — opaque to protocol)
  ref_from    TEXT,                -- source node ID (beams only, REFERENCES loat(id))
  ref_to      TEXT,                -- target node ID (beams only, REFERENCES loat(id))
  observer    TEXT NOT NULL,       -- who created this node (agent name, user ID, instance ID)
  visibility  TEXT DEFAULT 'private',  -- private | domain | shared | public
  source      TEXT,                -- provenance URI or surface identifier
  lat         REAL,                -- optional location (decimal degrees)
  lng         REAL,                -- optional location (decimal degrees)
  created_at  TEXT NOT NULL        -- ISO 8601 UTC timestamp
  -- NO updated_at COLUMN. The column does not exist. Changes are new nodes.
);

CREATE INDEX idx_loat_observer ON loat(observer, created_at);
CREATE INDEX idx_loat_beams_from ON loat(ref_from) WHERE type = 1;
CREATE INDEX idx_loat_beams_to ON loat(ref_to) WHERE type = 1;
CREATE INDEX idx_loat_kind ON loat(kind, created_at);
```

---

## Types

### Pier (type = 0)

A zero-dimensional point. A thing that exists. Timestamped, immutable, referenceable.

| Field | Required | Description |
|-------|----------|-------------|
| `id` | yes | ULID |
| `type` | yes | `0` |
| `kind` | no | Classification (person, place, project, concept, event, state, capture, text, trace) |
| `content` | no | Payload in any format. Opaque to the protocol. |
| `observer` | yes | Who asserted this pier's existence |
| `visibility` | yes | private, domain, shared, public |
| `source` | no | Provenance — which device, surface, or system created it |
| `lat`, `lng` | no | Location at creation time |
| `created_at` | yes | ISO 8601 UTC |

### Beam (type = 1)

A one-dimensional connection. A relationship between two nodes. **Also a node** — beams can be targets of other beams.

| Field | Required | Description |
|-------|----------|-------------|
| `id` | yes | ULID |
| `type` | yes | `1` |
| `kind` | no | Relationship type (see vocabulary below) |
| `ref_from` | yes | Source node ID (pier or beam) |
| `ref_to` | yes | Target node ID (pier or beam) |
| `content` | no | Relationship metadata (weight, confidence, notes) |
| `observer` | yes | Who asserts this relationship |
| `visibility` | yes | private, domain, shared, public |
| `created_at` | yes | ISO 8601 UTC |

---

## Rules

1. **Append-only.** INSERT only. No UPDATE. No DELETE. Changes are new nodes that recontextualize old ones.

2. **Beams are nodes.** A beam has `ref_from` and `ref_to` pointing at other nodes. But a beam is itself a node — it can be the target of other beams. Meaning stacks infinitely.

3. **One observer per node.** The `observer` field records who created it. The same real-world fact can appear as separate nodes under different observers.

4. **Visibility is per-node.** Private nodes are visible only to their observer. Domain nodes are visible to all observers in the same instance. Shared nodes are visible to listed observers. Public nodes are visible to all observers across all instances.

5. **Deletion is a tombstone beam.** To "remove" a node from a view, create a beam of kind `tombstone` or `contradicts` pointing at it. The original node remains in the ledger.

6. **IDs are ULIDs.** Universally Unique Lexicographically Sortable Identifiers. No coordination required between instances. Time-sortable. Globally unique.

7. **`ref_from` and `ref_to` must reference existing nodes.** Insertion order validates referential integrity.

---

## Beam Kind Vocabulary (open, extensible)

| Kind | Meaning | Example |
|------|---------|---------|
| `relates_to` | General connection | "This capture relates to this project" |
| `is_part_of` | Composition | "This entry is part of this ledger" |
| `caused` | Temporal causation | "This signal caused this processing event" |
| `observed_during` | Temporal co-occurrence | "This capture happened during this transit" |
| `corrects` | Error correction | "This transcription corrects this misspelling" |
| `contradicts` | Disagreement | "This assessment contradicts that earlier one" |
| `tombstone` | Withdrawal from view | "This pier is withdrawn from my index" |

New kinds auto-create. The vocabulary is open — any string is valid.

---

## Operations

```
CREATE_PIER(kind, content, observer, visibility, opts) → id
CREATE_BEAM(from_id, to_id, kind, observer, visibility, opts) → id
QUERY(filters) → [node]
SUBGRAPH(root_id, depth, observer) → [node]
EXPORT(observer, topic_id, depth) → {nodes, checksum}
IMPORT(nodes, receiving_observer) → :ok | {:error, reason}
```

---

## Interchange Format

Canonical form: one JSON object per line (JSONL), UTF-8, `\n` delimited, keys sorted.

```jsonl
{"id":"01J...","type":0,"kind":"concept","content":"Stripe equity","observer":"vocation","visibility":"domain","created_at":"2026-04-08T15:30:00Z"}
{"id":"01K...","type":1,"kind":"relates_to","ref_from":"01J...","ref_to":"01L...","observer":"vocation","visibility":"domain","created_at":"2026-04-08T15:30:01Z"}
```

Optional envelope for ordering: `{"ledger_id": "uuid", "seq": 42, "node": {...}}`.

---

## Federation (V3+)

Two LOAT instances sync by:

1. Comparing Merkle roots of their public/shared nodes.
2. If roots differ, exchanging deltas since last sync.
3. Merge is union — append-only stores never conflict on insert.
4. Observer IDs are prefixed with instance ID when federated: `"tenet:vocation"`, `"forge:team-2"`.
5. Compliance-tagged nodes (`hipaa`, `pii`, `financial`) are physically excluded from federation deltas.

Minimum wire format: HTTPS + JSONL bundles. Signed with Ed25519 for authenticity.

---

## Storage Recommendations

| Deployment | Storage | Rationale |
|------------|---------|-----------|
| Single-node, personal | SQLite (WAL mode) | One file, portable, queryable. Handles ~50K inserts/sec. |
| Multi-user, shared | Postgres | RLS for observer scoping, scale, replication. |
| Interchange | JSONL | Human-readable, git-diffable, streamable. |
| Audit/archive | JSONL + Merkle root | Append-only log with integrity verification. |
| Human view | Markdown (rendered from LOAT) | Read model, not source of truth. |

---

## What LOAT Is Not

- **Not a database engine.** LOAT is a data model and interchange protocol. It runs on top of SQLite, Postgres, or any append-capable store.
- **Not a replacement for graph databases.** LOAT doesn't solve graph traversal at scale. It provides a disciplined vocabulary for recording things and relationships.
- **Not globally consistent.** Each observer has their own view. Consistency is local (per-observer), not global.
- **Not a consensus protocol.** Federation is set reconciliation (Merkle delta exchange), not distributed consensus. Conflicts are additional beams, not resolved merges.
