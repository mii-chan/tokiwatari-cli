# events table schema (user_version = 1)

Single-table discriminated union: UI events and API calls share one table, separated by `event_kind`.

This file is the **canonical definition** of the schema — the single contract between `tokiwatari-ios-sdk` (the sole writer, synced manually against this file) and the CLI (readonly). The CLI verifies `PRAGMA user_version` on every connection, so if your queries run at all, this schema is the one in effect.

```sql
CREATE TABLE events (
  session_id        TEXT    NOT NULL,
  session_sequence  INTEGER NOT NULL,   -- monotonic per session; the ONLY ordering key
  timestamp         TEXT    NOT NULL,   -- GRDB "yyyy-MM-dd HH:mm:ss.SSS" UTC string (ms precision)
  event_kind        TEXT    NOT NULL,   -- 'api' | 'ui'
  identifier        TEXT,               -- logical id; required for ui rows; app-supplied search key for api rows; main LIKE target
  http_method       TEXT,               -- api rows
  url               TEXT,               -- api rows
  status_code       INTEGER,            -- api rows
  duration_ms       INTEGER,            -- api rows; Date-diff of request start/end
  payload_json      TEXT,               -- kind-specific rest; see "payload_json shape" below. JSON1-searchable
  PRIMARY KEY (session_id, session_sequence)
);

CREATE INDEX idx_events_identifier ON events(identifier);
CREATE INDEX idx_events_kind       ON events(event_kind, session_id);
CREATE INDEX idx_events_time       ON events(session_id, timestamp);
```

Rules that queries must respect:

- `ORDER BY session_sequence` — never order *events* by `timestamp`. (The one sanctioned timestamp ordering is picking the latest *session* via `MAX(timestamp)`, as in the aggregate example below.)
- `timestamp` is an UTC string whose lexicographic order equals chronological order, so time windows are plain string comparisons: `WHERE session_id = ? AND timestamp BETWEEN '2026-07-05 10:00:00.000' AND '2026-07-05 10:05:00.000'`. Note: the CLI's *text* output displays these in local time; the stored values and `--json` output are UTC — build SQL time windows from the UTC values.
- The CLI connection is readonly; only SELECTs work in `tokiwatari query`.

## payload_json shape

- `ui` rows: the event's parameters dict stored directly, e.g. `{"tea_id":42}`. NULL when the event has no parameters.
- `api` rows:
  ```json
  {
    "request":  { "headers": {...}, "body": <json> },
    "response": { "headers": {...}, "body": <json> },
    "error": { "domain": "NSURLErrorDomain", "code": -1001 }
  }
  ```
  - `body` is a *nested JSON value* (keys sorted), not a string — `json_extract` can address into it, e.g. `$.request.body.variables.keyword`. Only JSON bodies are stored (`application/json`/`*+json`, or no Content-Type but fully parses as JSON), capped at 64KB per side after sanitization. Everything else — non-JSON, multipart, streamed, oversized — is replaced by a marker object `{"body_unavailable": "<reason>"}` with reason ∈ `too_large | sanitized_body_too_large | json_complexity_limit | invalid_json | unsupported_content_type | multipart | streamed` (`original_bytes` accompanies `sanitized_body_too_large`). There is no partial truncation: a body is stored whole or not at all.
  - The top-level string `query` of a request body — single object or each element of a batch array — is always stored as `"<omitted>"`, GraphQL or not (query documents can carry secrets that key redaction cannot catch). `operationName` and `variables` survive.
  - Sensitive header values (Authorization, Cookie, ...) are stored as `"<redacted>"`, and so are the values of sensitive JSON body keys (password, token, secret, access_token, api_key, ...; app-extendable) — matching ignores case and `_`/`-` and applies to nested objects/arrays.
  - A payload over 256KB degrades in stages: the response body and then request body become `{"body_unavailable": "event_too_large"}`, followed by omission of response headers and then request headers. If still too large the whole payload is `{"payload_dropped": "event_too_large", "original_bytes": N}`. The method/url/status columns survive regardless.
  - `error` appears when the caller passes one, always as `{"domain": ..., "code": ...}`. `request`/`response` objects are omitted entirely when empty; because components are encoded independently, `response` and `error` may coexist.

  `identifier` for api rows is the search key the app passed to `Tokiwatari.logAPIEvent(identifier:)`, stored without redaction and shown verbatim in list output; NULL when the app passed none (list output then falls back to `<method> <URL path>`). Conventions: `<METHOD> <path>` for REST calls and the GraphQL `operationName` (the Apollo interceptor recipe passes `Operation.operationName`).

## json_extract examples

Use SQLite JSON1:

```sql
-- UI: pull a parameter out of the payload
SELECT session_sequence, identifier,
       json_extract(payload_json, '$.tea_id') AS tea_id
FROM events
WHERE event_kind = 'ui' AND identifier LIKE 'tea_tapped_%';

-- API: inspect request/response bodies of failed requests
-- (bodies are nested JSON, so paths can go deeper: '$.request.body.tea_id')
SELECT session_sequence, url, status_code,
       json_extract(payload_json, '$.request.body')  AS request_body,
       json_extract(payload_json, '$.response.body') AS response_body
FROM events
WHERE event_kind = 'api' AND status_code >= 500;

-- Aggregate: slowest endpoints in the latest session
SELECT url, COUNT(*) AS calls, AVG(duration_ms) AS avg_ms, MAX(duration_ms) AS max_ms
FROM events
WHERE event_kind = 'api' AND session_id = (
  SELECT session_id FROM events ORDER BY timestamp DESC LIMIT 1
)
GROUP BY url ORDER BY max_ms DESC;
```

## Version history

| user_version | Contents |
|---|---|
| 1 | Initial schema: single `events` table + 3 indexes, as defined above |

The SDK sets `PRAGMA user_version` at table creation and recreates the database from scratch on any mismatch (debug logs are disposable — there are no migrations). Bump the version on every schema or payload_json format change, in lockstep with the SDK's DDL and the CLI's expected version.
