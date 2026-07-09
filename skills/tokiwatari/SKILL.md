---
name: tokiwatari
description: Search iOS debug event logs recorded by the Tokiwatari SDK — UI events and API calls merged into one per-session timeline. Use when debugging an iOS app to find what UI action preceded which API call, why a request failed, or what happened around a given moment.
---

## 0. What tokiwatari is

The app (DEBUG build, Tokiwatari SDK) writes every UI event and API call into a SQLite file inside its sandbox. The `tokiwatari` CLI reads that file (readonly) and gives you a merged, ordered timeline. Events are ordered by `session_sequence` (monotonic per session) — never by wall-clock time.

Run `tokiwatari doctor` first if anything seems off (path resolution, schema version, event counts).

## 1. Basic workflow: sessions → timeline → ui --like → around → show

```bash
# 1. Which session do I care about? (newest first; usually the top one)
tokiwatari sessions

# 2. Overview of what happened (defaults to the latest session when --session is omitted)
tokiwatari timeline
tokiwatari timeline --kind api --limit 50          # only API calls
tokiwatari timeline --session <id> --before-seq 120  # page further back

# 3. Find the UI event you care about. Identifier naming is app-specific —
#    check the app repo's docs for its event catalog; the tail is often a
#    dynamic value, so search with LIKE prefixes.
tokiwatari ui --like 'tea_tapped_%'

# 4. Read what happened around it (correlation = read the neighborhood)
tokiwatari around 118 --before 5 --after 10
tokiwatari around 118 --before-ms 2000 --after-ms 2000   # time window instead

# 5. Drill into one event: full headers, request/response bodies, ui parameters
tokiwatari show 119                 # by sequence (from timeline/ui/api/around output)
tokiwatari show --status 500        # latest matching event — "the 500 that just happened"
tokiwatari show --url-like '%/v1/brews%'
```

`around` accepts count limits (`--before`/`--after`, default 10 each) and time windows (`--before-ms`/`--after-ms`); when combined, both conditions apply, so the narrower one wins. Output is always ordered by `session_sequence`.

`show` prints ONE event in full: list output stays compact on purpose; use `show` whenever you need bodies. Truncated bodies are marked (`truncated at 64KB`); sensitive values — headers like Authorization/Cookie and JSON body keys like password/token — are stored as `<redacted>`.

API search:

```bash
tokiwatari api --status 500
tokiwatari api --url-like '%/v1/teas%' --min-duration-ms 1000

# GraphQL: operations are recorded as identifier "GraphQL:<Type>:<Name>"
tokiwatari api --like 'GraphQL:%'             # every GraphQL call
tokiwatari api --like 'GraphQL:Mutation:%'    # mutations only
tokiwatari api --like '%:SearchTeas'         # by operation name
```

GraphQL rows show the operation instead of the URL path in list output (`POST GraphQL:Query:SearchTeas 200 145ms`); `show` unfolds the query text and prints `variables` separately.

## 2. Global flags

| Flag | Meaning |
|---|---|
| `--json` | Success prints the data value as-is (pipe straight into `jq`). Failure prints `{"error": ..., "hint": ...}` and exits 1 — `hint` tells you how to self-repair (e.g. run `sessions`, candidate UDIDs). Prefer `--json` when you will parse the output. |
| `--db <path>` | Read a SQLite file directly (bypasses source resolution). Use for exported/AirDropped snapshots. |
| `--bundle-id <id>` | App to inspect. Resolution order: flag > `TOKIWATARI_BUNDLE_ID` > `.tokiwatari.json` in cwd. |
| `--udid <udid>` | Simulator or device. Resolution order: flag > `TOKIWATARI_UDID` > `.tokiwatari.json` > auto-detect (exactly one booted simulator / connected device; otherwise the error hint lists candidates). |
| `--source <s>` | `simulator` (default, live read) or `device` (physical iPhone: pulls a snapshot via devicectl into a local cache; snapshots within ~5s are reused). Resolution order: flag > `TOKIWATARI_SOURCE` > `.tokiwatari.json` `source` key. |
| `--refresh` | Force a fresh device pull, ignoring the freshness cache. Use right after reproducing something on the device. |

## 3. Escape hatch: raw SQL

When the canned subcommands can't express the question (aggregation, `json_extract`, joins), use `query`. The connection is readonly, so writes are structurally impossible. **Read `references/schema.md` first** for the exact table definition and `json_extract` examples.

```bash
tokiwatari query "SELECT identifier, COUNT(*) FROM events WHERE event_kind='ui' GROUP BY 1 ORDER BY 2 DESC"
```

## 4. Pitfalls

- `--session` omitted means the **latest** session, not all sessions. Pass `--session <id>` from `sessions` output to inspect an older one.
- Ordering is by `session_sequence`; timestamps exist for time windows and readability only. Don't sort by `timestamp` in raw SQL.
- Text output shows timestamps in **local time**; the database and `--json` output are **UTC**. When writing raw-SQL time windows, use UTC strings (take them from `--json`, not from the text display).
- Identifiers can contain dynamic values (`tea_tapped_42`) — search with LIKE patterns (`tea_tapped_%`), not exact matches, unless you know the value.
- A new session starts on every app launch (including Build & Run) and after ~30 min of inactivity. If something you just reproduced is missing from `timeline`, it may sit in the previous session — check `sessions` first.
- Old sessions are pruned by the SDK (latest 10 kept by default); if a session vanished, that is expected retention behavior.
- `--source device` reads a *snapshot*, not a live database: events recorded after the last pull appear only after the next pull (add `--refresh` to force one). If the pull fails, ask the user to share an exported snapshot from the app (`Tokiwatari.exportSnapshot()`) and read it with `--db <path>`.
