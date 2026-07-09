# tokiwatari-cli

Tokiwatari searches the SQLite timeline of UI events and API calls that the companion [`tokiwatari-ios-sdk`](https://github.com/mii-chan/tokiwatari-ios-sdk) records inside an iOS app.

Designed as an interface for AI coding agents: compact token-efficient output, `--json` with self-repair `hint`s on failure, and a bundled agent skill. The database is always opened read-only — the SDK is the sole writer.

## Installation

Runs as a single self-contained Swift binary. From a checkout:

```bash
swift build -c release
cp .build/release/tokiwatari /usr/local/bin/   # or anywhere on PATH
```

Simulator/device resolution needs Xcode's `xcrun` (`simctl` / `devicectl`).

## Quick start

```bash
cd your-app-repo                  # with .tokiwatari.json, or pass --bundle-id
tokiwatari doctor                 # sanity-check path resolution, schema, counts
tokiwatari sessions               # list sessions, newest first
tokiwatari timeline               # merged UI+API timeline of the latest session
```

```
session a1b2c3d4  42 events  2026-07-05 19:12:03 ~ 19:15:47
seq  time          kind  summary
118  19:14:02.113  ui    tea_tapped_42
119  19:14:02.350  api   POST /v1/brews 500 1240ms
```

## Commands

| Command | Purpose |
|---|---|
| `sessions` | List sessions (newest first) with time range and event count |
| `timeline` | Merged UI+API timeline of one session (`--kind`, `--limit`, `--before-seq` paging) |
| `around <seq>` | Events around a sequence — count limits and/or time windows; the narrower wins |
| `ui` | Search UI events by identifier (`--like 'tea_tapped_%'`) |
| `api` | Search API logs (`--status`, `--url-like`, `--like 'GraphQL:Mutation:%'`, `--min-duration-ms`) |
| `show [seq]` | Full detail of one event: headers, bodies, parameters |
| `query "<SQL>"` | Read-only raw SQL escape hatch (aggregations, `json_extract`, joins) |
| `install-skill` | Install the bundled agent skill (`SKILL.md` + references) to `--dest <path>` |
| `doctor` | Diagnose path resolution, database, schema version, WAL state |

Every listing command (`timeline`, `around`, `ui`, `api`, `show`) defaults to the **latest session**; pass `--session <id>` for older ones. Their output is always ordered by `session_sequence` (per-session monotonic counter) — never by wall-clock time. `query` runs against the whole database, ordered by whatever the SQL says.

GraphQL requests are recorded with a logical identifier (`GraphQL:Query:GetUser`, `GraphQL:Mutation:AddFavorite`), shown in place of the URL path in list output and searchable via `api --like`.

## Global flags

| Flag | Meaning |
|---|---|
| `--json` | Success prints the data as-is; failure prints `{"error", "hint"}` and exits 1 |
| `--db <path>` | Read a SQLite file directly (exported snapshots, fixtures) |
| `--bundle-id <id>` | App to inspect |
| `--udid <udid>` | Simulator or device (auto-detected when exactly one is available) |
| `--source <s>` | `simulator` (default, live read) or `device` (snapshot pull) |
| `--refresh` | Force a fresh device pull, ignoring the ~5s freshness cache |

Resolution order for each setting: flag > environment variable (`TOKIWATARI_BUNDLE_ID` / `TOKIWATARI_UDID` / `TOKIWATARI_SOURCE`) > `.tokiwatari.json` in the working directory > auto-detection.

`.tokiwatari.json` (project root):

```json
{ "bundleId": "<bundle identifier>", "udid": null, "source": "simulator" }
```

## Data sources

- **Simulator** (default): resolves the app sandbox via `simctl` and reads the database in place — live, no copying. Container paths are cached in `~/.cache/tokiwatari/paths.json`.
- **Device** (`--source device`): pulls a snapshot of the database from a connected iPhone via `devicectl` (development-signed app required) into `~/.cache/tokiwatari/device/`. Snapshots within ~5s are reused; `--refresh` forces a pull. Note this reads a *snapshot*, not a live database.
- **File** (`--db`): reads any exported snapshot directly — e.g. one AirDropped from the app via the SDK's `exportSnapshot()`.

## Output conventions

- Text output shows timestamps in **local time** (`show` includes the UTC offset); the database and `--json` output are **UTC**. Build raw-SQL time windows from the UTC values.
- JSON bodies in `show` are pretty-printed with keys sorted for display; the stored payload keeps the original bytes.
- Sensitive header values and sensitive JSON body keys (password, token, ...) are stored as `<redacted>` by the SDK.

## Agent integration

```bash
tokiwatari install-skill --dest ~/.claude/skills/tokiwatari
```

The skill teaches the workflow (`sessions` → `timeline` → `ui --like` → `around` → `show`) and the schema for raw SQL.

## Schema contract

[`skills/tokiwatari/references/schema.md`](skills/tokiwatari/references/schema.md) is the canonical definition of the `events` table — the single contract between the SDK and this CLI, and part of the installed agent skill. Drift is detected mechanically: the CLI compares `PRAGMA user_version` on every connection and fails with a hint on mismatch.

## Development

Built with swift-argument-parser and GRDB.swift. The behavior suite generates its fixture databases into a temp directory and spawns the built binary as a subprocess.

```bash
swift test                                          # the whole suite
swift build -c release --arch arm64 --arch x86_64   # universal release binary
scripts/embed-skills.sh   # regenerate the embedded skill after editing skills/
```

## License

[MIT License](LICENSE.txt)
