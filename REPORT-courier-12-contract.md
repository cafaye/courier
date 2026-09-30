# REPORT — courier-12: the error envelope, and everything the document did not say

Branch `worker/courier-12-contract`. Base `4711e54` (the `recover(...)` commit the
re-dispatch started from). Not pushed.

The brief: courier declares the RFC 9457 error envelope in `components` and wires
it to no response; six of the nine reserved codes never appear; two mutating POSTs
take no `Idempotency-Key`; prove the document and the code agree.

Most of that is measurably false, or measurably true in a different place than the
brief says. This report is what I measured, what I changed as a result, and what I
deliberately did **not** change.

---

## 1. Re-measurement: what reproduced and what did not

Everything below was measured against this repository's endpoint, not read off the
source. Requests went through `Phoenix.ConnTest` where a rendered response is
visible, and over a **real socket** for the statuses `ConnTest` cannot see — see
§5 for why that was necessary.

### Did not reproduce

| Brief's claim | Measured |
|---|---|
| `application/problem+json` referenced by ZERO responses | **False.** All four declared responses (`BadRequest`, `Unauthorized`, `NotFound`, `ValidationFailed`) name it and `#/components/schemas/Problem`. courier-05 had already attached the envelope; the 628-line document was not describing a component wired to nothing. |
| Only 400, 401, 404, 422 declared | **True, and it is the real finding** — see below. |
| Six of nine reserved codes never appear | **True.** `forbidden`, `conflict`, `idempotency_key_reused`, `rate_limited`, `internal`, `unavailable` appear zero times. |
| `Idempotency-Key` mentions: 0 | **True.** Zero. |

### Did reproduce, and is worse than the brief said

**Every one of the eight operations could return a `500` and a `406`, and none of
the eight declared either.** `CourierWeb.Endpoint` is configured
`render_errors: [formats: [json: CourierWeb.ErrorJSON]]`, so Phoenix renders a 500
for *any* raise on *any* route; and `plug :accepts, ["json"]` in the `:api` pipeline
raises `Phoenix.NotAcceptableError` → 406 on every request whose `Accept` excludes
`json`. Eight operations, two undeclared reachable responses each, sixteen total.

A generated client reading this document had no way to learn any of that. This is
the same defect as the brief's, one level down, and it is the part I closed.

### The brief's `Idempotency-Key` half: courier does not implement it

The brief asked for the header plus a documented 409 `idempotency_key_reused`, "only
where the service really implements it". It does not implement it. Measured, with
`Idempotency-Key: 11111111-1111-1111-1111-111111111111`:

```
three POSTs, same key, same body   -> 201, 422, 422   (the 422s are the unique
                                                            index on url, not the key)
rows created                        -> 1
Idempotency-Replayed header         -> absent on all three
same key, different body            -> 201, a further row
non-uuid key                        -> 201
5000-character key                  -> 201
```

So declaring the header or the 409 would have put a contract for behaviour that does
not exist into the permanent document, and a client generating a retry from it would
be retrying against a service that was never listening. **Neither is declared.**
The gap is written into the document's header, and a test asserts the header says
so — so a later packet that implements it is caught rather than silently
contradicting the document.

This is the honest reading of "a document that lies is worse than one that is
incomplete", and it is worth being blunt about the tension with the brief's own
framing: the brief argued idempotency matters because delivery is at-least-once and
because a live worker is fixing a duplicate-outbox-row bug in `billing`. That
argument is about **courier as a receiver**, and `createWebhookEndpoint` registers a
destination courier will *send* to. The duplication in `billing` is a bug in
whatever writes the outbox, not a missing header on courier's API. The document
cannot fix a bug in another service, and writing `Idempotency-Key` here would not
have prevented it.

### What courier genuinely returns, per operation

Read from the endpoint, one request per cell:

| Operation | Declares now | Actually reachable |
|---|---|---|
| `GET /v1/notification_preferences/{user_id}` | 200, 406, 422, 500 | 200, 406, 422, 500 |
| `PUT /v1/notification_preferences/{user_id}` | 200, 400, 406, 422, 500 | 200, 400, 406, 422, 500 |
| `GET /v1/webhook_endpoints` | 200, 401, 406, 422, 500 | 200, 401, 406, 422, 500 |
| `POST /v1/webhook_endpoints` | 201, 400, 401, 406, 422, 500 | 201, 400, 401, 406, 422, 500 |
| `GET /v1/webhook_endpoints/{id}` | 200, 401, 404, 406, 500 | 200, 401, 404, 406, 500 |
| `PATCH /v1/webhook_endpoints/{id}` | 200, 400, 401, 404, 406, 422, 500 | 200, 400, 401, 404, 406, 422, 500 |
| `DELETE /v1/webhook_endpoints/{id}` | 204, **400**, 401, 404, 406, 500 | 204, **400**, 401, 404, 406, 500 |
| `POST /v1/webhook_endpoints/{id}/test` | 200, 400, 401, 404, 406, 500 | 200, 400, 401, 404, 406, 500 |

**Pagination: verified correct, left alone.** Cursor params present, no offset
pagination, `next_cursor` and `has_more` present, `limit` defaults to 25 and caps at
100 (`?limit=99999` → 200 with 100 rows). The brief asked me to leave it alone if it
holds; it holds. Two related facts are in the header because a reader is owed them:
`?order=` and `?offset=` are accepted and **ignored** (measured — `order=desc`,
`order=asc`, `order=sideways` and `offset=2` all return byte-identical page 1), and
the `limit` cap is applied silently rather than as a 422.

---

## 2. Two errors the new test found in my own first draft

Worth stating plainly, because it is the argument for checking both directions.

`DELETE /v1/webhook_endpoints/{id}` **can** return 400 and the document did not
declare it. `CourierWeb.Plugs.ParseBody` wraps `Plug.Parsers`, whose `@methods` is
`POST PUT PATCH DELETE` — `DELETE` reads a body and refuses one it cannot parse. A
`DELETE` carries no body in any sensible client, so it looks bodyless, and a
document that omits its 400 looks right.

`GET /v1/notification_preferences/{user_id}` declared a 400 that is **unreachable**,
because the parser reads no body on a `GET`.

My first version of the test checked only "declares it" for `POST`/`PUT`/`PATCH`,
passed, and would have shipped both. It now checks the **agreement**, both
directions, by provoking every operation. Caught in the act:

```
GET /v1/notification_preferences/{} declares a 400 a client cannot receive
  — the parser reads no body on this verb, so the response is unreachable
DELETE /v1/webhook_endpoints/{} answers 400 and does not declare it
```

---

## 3. What changed

**`openapi.yaml`** — 767 lines, was 628.
- `406 NotAcceptable` and `500 Internal` added to all eight operations (the finding).
- `400` **removed** from `GET /v1/notification_preferences/{user_id}`; **added** to
  `DELETE /v1/webhook_endpoints/{id}` (measured, both ways).
- `errors[].detail` declared, optional. courier has been sending it: a bad `limit`
  reads "is not a positive integer" rather than only `invalid_format`.
- Header now **admits the five statuses courier does not return** — 403, 409, 415,
  429, 503 — each with its measured reason, and admits the `Idempotency-Key` gap.
  Each token is asserted by a test, so an omission cannot go quiet.
- `info.version` 1.2.0 → **1.3.0**. Minor: no path changed, no operation added or
  removed, nothing that existed changed shape. A client is not broken by learning
  a 500 was possible.

**`lib/courier_web/problem.ex`** — one code added: `not_acceptable: {406, "Not
acceptable"}`. See §4.

**`test/support/openapi_paths.ex`** — `document_responses!/1` and
`component_responses!/1`, which resolve a `$ref` into `components.responses`. A
`$ref` to a component the document does not define is now a **raised error** naming
the file and line, because a response wired to nothing is the exact shape this
packet is about.

**`test/courier_web/openapi_error_responses_test.exs`** — new, **18** tests (ExUnit's own
count). **The two existing tests stay exactly as they were**; nothing was weakened,
no assertion loosened, no sleep added, no retry raised. `openapi_paths_test.exs`
grew **11** reader tests — 40 to 51, 258 lines added and 0 removed — each on a
synthetic document.

---

## 4. One code fix, and why it was not optional

`CourierWeb.Problem.for_status/1` had no entry for 406, so it fell through to the
`:internal` default. A client that asked for `text/html` was answered:

```json
{"status": 406, "code": "internal", "title": "Internal server error"}
```

Its own `Accept` header, reported back to it as courier having failed — wearing the
one code every generated client retries. `internal` is core's reserved slug for 500.

I could have documented a 406 and left this. That would have put the lie into the
permanent contract, so the code was fixed first. `not_acceptable` is courier's own,
in the same way `bad_request` already was (core enumerates no slug for either), and
the moduledoc says so.

---

## 5. A note on method, because it changed a conclusion

`Phoenix.ConnTest` **cannot** see the response to a 406. `Phoenix.NotAcceptableError`
carries no conn: RenderErrors catches, renders, and re-raises, so the exception
escapes the test before the response lands anywhere. Anything I claimed about 406 or
500 from inside `ConnTest` would have been a guess dressed as a measurement.

So I booted the endpoint for real and asked over TCP. That is how the 406 body above
was observed, and it is why the committed test asserts `Problem.for_status(406)`
directly — the function the 406 is rendered from, which is the same one every other
status goes through. The committed test says in a comment that the rendered shape
was measured over a socket; it does not claim to re-measure it there.

---

## 6. Gaps recorded, not papered over

1. **No `Idempotency-Key`.** Measured in §1. In the header. Asserted by a test.
2. **No rate limiting.** Thirty rapid writes → thirty 201s; thirty rapid reads →
   thirty 200s. `rate_limited` is in `Problem`'s table and nothing sends it.
3. **No 409 on anything.** A duplicate `url` is a **422** with `errors[0].code`:
   `taken`, which is core's status convention ("semantically wrong is 422"), not a
   conflict. `conflict` is in the table and unreachable.
4. **No 403, and that is correct.** The Principal plug answers 401; an endpoint in
   another account is a 404, because core forbids a 403 that leaks existence.
5. **415 is unreachable** given `pass: ["*/*"]`: an unknown content type is passed
   through and the request is answered 422 for the field it did not carry.
6. **503 is reachable, but only from `GET /readyz`**, which is a declared omission
   and not a customer operation. So no `/v1` operation declares it.
7. **`?order=` and `?offset=` are ignored.** Not declared, because not honoured.
   Core's standard shape includes `order`; courier paginates oldest-first only.
8. **CI floor was below the gate floor.** Pre-existing, named in
   `REPORT-core-10-courier.md`: `gate.yml` said 530 against a measured 535 while CI
   asserted 488. Both are now raised to the measured numbers, so the two can no
   longer disagree about what the suite reports.

---

## 7. The gate

`mise run prime` → **`Result: 564 passed`**, exit 0.

**Pass count: 564. Skip count: 0.** Reported separately because a skip is a hole in
the claim. The gate output contains no `skipped`, no `excluded` and no `invalid`
line, and `git diff --exit-code -- mix.lock` is clean, so the gate did not move the
lockfile. Baseline was **535 passed, 0 skipped**, so this packet adds **29**
tests — every one a real assertion, none a probe.

| Tier | Measured | Floor | `bin/assert-suite` |
|---|---|---|---|
| whole suite (`bin/prime`) | **564** | 564 | pass |
| no database, 12 files | **252** | 252 | pass |
| database, 17 files | **312** | 312 | pass |
| SSRF table | 62 | 62 | unchanged |

Floors raised in `gate.yml` and `.github/workflows/ci.yml` **in this commit**,
because a floor that is not raised is a suite whose growth CI cannot see. The
database tier measured 312 where an earlier draft had written 306; the number on
disk is the measured one.

The five `test/probe_*_test.exs` files this packet used to take measurements are
**deleted**. They were scaffolding, and a probe that prints to stdout is not a test.

### The new check can actually fail

Five faults injected, each reverted:

| Injected | Caught by |
|---|---|
| drop `'500'` from one operation | 2 tests, naming the operation |
| unwire `NotFound` from `problem+json` — **the brief's original defect** | 2 tests, listing the file:line |
| invent a 429 and a `RateLimited` component | "declares a status courier cannot return" |
| revert `not_acceptable` in `Problem` | 2 tests |
| `$ref` to a component that does not exist | raised error naming file:line, 18 invalid |

---

## 8. Not done

- **`core` untouched**, as instructed. The neutral checker belongs to the packet
  building it there. What courier-12 found is that the *provocation* half needs a
  running service, so a neutral harness will have to keep a language-specific half
  for this — worth telling that packet.
- **Not pushed.** The manager pushes after the gate is green.
- **`AGENTS.md` not updated.** It describes the layout, and this packet adds one
  file under `test/courier_web/`. Flagging rather than silently editing a file I
  did not write; say the word and it is one line.
- No token, key or JWT appears in this report, the document, or any test. The one
  test-local account id is a fixed uuid, not a credential.

## 9. A note on this worktree, because a reviewer will notice the commit is not one worker's

**Another process was writing to this worktree while this packet ran.** The first
interrupted run left `test/probe_*_test.exs` committed in `4711e54`; a second
writer then modified `openapi.yaml`, `test/support/openapi_paths.ex`,
`test/courier_web/openapi_error_responses_test.exs` and this report *while I was
editing them*, and rewrote `openapi.yaml` three times inside a minute. Two of my
`git stash push`/`pop` pairs were lost to that churn and had to be reconstructed
from `git show stash@{0}:<path>` into a temp directory rather than through git
state operations.

What that means for a reviewer:

* **The document and the checks in `4b134ae` are the agreed result of two passes,
  not one.** That is why `400` is *removed* from `GET /v1/notification_preferences`
  and *added* to `DELETE /v1/webhook_endpoints` — the second pass measured
  `Plug.Parsers` instead of assuming its verb list (§2).
* **Every number in this report was re-measured after the last write**, by me, on
  the committed tree: whole suite 564, no-database tier 252, database tier 312,
  SSRF 62, `mix.lock` unchanged, and the two fault injections in §7 re-run and
  confirmed to fail 2 tests each. Where this report and an earlier draft of it
  disagree, this one is the one that was measured.
* One consequence was chased down rather than left: an **intermittent** six-test
  failure in `webhook_endpoints_test.exs` and `webhook_endpoints_config_test.exs`
  (`Repo.aggregate(WebhookEndpoint, :count) == 0` finding 1) that appeared in one
  run in nine and never again. Those same six fail on the **base commit** when the
  database tier runs in isolation, and `psql` confirms **0 rows committed** after
  every run, so it is a latent isolation weakness in those two files and not an
  escape by this packet. It is worth a packet of its own; it is not this one.

## 10. Commits

Three on `worker/courier-12-contract`, none pushed:

1. `4711e54` — recovery of work left uncommitted when the machine OOM'd. Probe
   scaffolding only; its conclusions were re-measured from scratch before anything
   was built on them.
2. `4b134ae` — the work: the document, the one code fix, the response reader, the
   new check, the raised floors, this report.
3. This commit — the CHANGELOG entry for the `400` correction and the three report
   figures that were re-measured on the committed tree (§9 explains why there was
   a third).
