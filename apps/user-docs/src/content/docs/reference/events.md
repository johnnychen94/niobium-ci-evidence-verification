---
title: Events
description: The JSON progress events emitted by setup --json and the C ABI.
---

Canonical sources: the events section of [cli-v1](https://github.com/niobium-project/niobium/blob/main/docs/spec/cli-v1.md#events) and [event-v1.schema.json](https://github.com/niobium-project/niobium/blob/main/api/schema/event-v1.schema.json).

`setup --json` writes one JSON object per line to standard output. The C ABI delivers the same objects, without the newline, to the callback registered with `event_subscribe`.

```json
{"schema":1,"phase":"download","progress":0.37}
{"schema":1,"phase":"error","code":"trust.hash_mismatch","message":"...","exit_code":4}
```

## Fields

| Field | Presence | Meaning |
|---|---|---|
| `schema` | always | `1` |
| `phase` | always | The engine phase, see below |
| `progress` | optional | A number from 0 to 1 within the phase |
| `code` | optional | `<category>.<name>` of an error or notice ([exit codes](/reference/exit-codes/#event-error-codes)) |
| `message` | optional | Human-readable text |
| `exit_code` | optional | The exit code this event implies |

Ignore fields you do not know: new fields can be added, and existing fields never change meaning.

## Phases

`recover`, `discover`, `validate`, `resolve`, `plan`, `prepare`, `download`, `verify`, `execute`, `commit`, `bootstrap`, `verify_install`, `finalize`, `complete`, `error`.

The set is fixed; the order depends on the operation. A user-scope install from a local repository emits `recover`, `discover`, `resolve`, `validate`, `prepare`, `download`, `verify`, `plan`, `execute`, `commit`, `bootstrap`, `verify_install`, `finalize`, `complete`. A successful run includes `complete`; a failed one emits exactly one `error` event. When App Bootstrap fails after the commit, `setup` also emits a `bootstrap` event with code `bootstrap.pending` and `exit_code` 8.
