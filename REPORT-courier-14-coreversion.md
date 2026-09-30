# REPORT — courier-14: the stale pin, and the checker made green

**Branch:** `worker/courier-14-coreversion` · **Not pushed. No tag, no remote.**

## Result

| Suite | Pass | Fail | **Skip** |
| --- | --- | --- | --- |
| `bin/prime` (the declared gate) | **616** | 0 | **0** |
| `bin/assert-suite` on that log, floor 616 | green | — | **0** |
| tier — no database, 12 files | **258** | 0 | **0** |
| tier — database, 19 files | **358** | 0 | **0** |
| `bin/gate-self-test` | **11** | 0 | **0** |
| core's contract checker, `harness/cafaye_contract.py` | conforms, exit 0 | — | — |

**Pass and skip reported separately, as the brief requires. There is no skip in
this packet and none was added.** `bin/assert-suite` exists to refuse a log that
says so, and it was run against every one of the three suite logs above rather
than taken on trust: the gate log contains exactly one `Result:` line and zero
occurrences of "skipped" or "excluded".

Floors were raised in the same commit as the tests, which is courier's rule and
not an afterthought: `gate.proof[].minimum` 560 → **610** against a measured 616,
and CI's three `bin/assert-suite` floors 564/252/312 → **616/258/358**. Leaving
them would have made the gate weaker than the suite it gates.

---

## 1. Re-measuring the brief before touching anything

The brief said courier declares a stale `core: ^0.1.0` and that core's enforcing
rule "will now fail against v0.2.0". Reproduced exactly, and it was the only one
of the brief's claims that was about *versions*:

```
$ cd core && python3 harness/cafaye_contract.py --core . ../courier
FAIL core.constraint-unmet cafaye.yml: core: core publishes 0.2.0 and this service
     declares `core: ^0.1.0`, which 0.2.0 is not in [0.1.0, 0.2.0).
FAIL openapi.idempotency-key … createWebhookEndpoint is a mutating POST that does
     not accept an `Idempotency-Key` header
FAIL openapi.idempotency-key … testWebhookEndpoint is a mutating POST that does
     not accept an `Idempotency-Key` header
3 violation(s) — exit 1
```

`core/VERSION` is `0.2.0`, and courier-12's work was on master as the brief said.

**What did not reproduce: courier-12's error envelope is not broken.** The brief
wrote that "the openapi rules … should now have something true to check; if they
still find violations, FIX them". Measured, courier-12 had already done that part:
`openapi.errors-are-problem` and `openapi.problem-code-matches-type` were **not
among the three findings**, and the 500/406 gaps courier-12 was measured against
were already closed. The only openapi rules that fired were the two idempotency
ones. So the work was narrower than the brief implied, and the two real
violations were both the *same* defect seen from two rules.

That is worth stating plainly because it is the difference between "the checker
found three problems" and "the checker found one problem twice".

---

## 2. The pin

`core: ^0.1.0` → `^0.2.0`, one line.

The manifest's own header had been carrying the guess as an open item — *"`core:
^0.1.0` assumes core's first release is 0.1.0. If it lands as 0.2.0 this line is
wrong and CI's pin will not resolve."* It is rewritten rather than deleted,
because the note was the only record in the file of which line is checked by
something outside this repository, and it now says what the line does.

---

## 3. `Idempotency-Key`: implemented, then declared

core's `docs/openapi-conventions.md` §Idempotency is six sentences, and the brief
was right that courier satisfied none of them. courier-12 had measured it and
chosen, correctly, **not to declare a header for behaviour that did not exist** —
it wrote the gap into the document's header and pinned the gap in a test so a
later packet would be caught. This is that later packet.

The split is storage (`Courier.Idempotency`, `Courier.IdempotencyKey`,
`idempotency_keys`) and wiring (`CourierWeb.Plugs.Idempotency`, behind a new
`:idempotent` pipeline on the two mutating POSTs only).

### The design decisions, and why

**The claim is taken before the controller runs.** A key recorded after the action
cannot prevent anything — two requests would both run and both mutate, and the
second store would be rejected after the damage. The row exists in an `in_flight`
state between claim and store, which is what a second request with the same key
finds. `unique (account_id, endpoint, idempotency_key)` decides the race.

**A request that did not succeed releases its key.** Only a 2xx is stored. A
stored 422 would pin the caller's own typo for 24 hours: they fix it, retry with
the same key, and get a 409 about a key they never reused. A stored 500 would pin
a transient courier failure for the same day. A retry of a failed request is
always safe because nothing was committed. Tested both ways — the row count after
a 422 is zero, and the fixed retry is not a replay.

**`endpoint` is the concrete request path, not the route pattern.** Core says
"the same key on a different endpoint is a different key". Keying on the pattern
would make a client that reuses one key to test four endpoints get a 409 on the
second — a key courier never lost.

**The in-flight case is 409 `conflict`, and core does not describe it.** Two
requests with one key arriving *simultaneously* is not a retry: the first has not
answered, so there is nothing to replay. It is not `idempotency_key_reused`,
which would say the bodies differed when they are identical. `conflict` is core's
own word for a request that collides with current state, and it is already
reserved at 409 — core's own reserved list has two codes at 409. The `detail`
says to retry. This is courier's answer to a case the convention does not reach,
and the document says so.

**The hash is over the decoded body, key-sorted.** Two bodies that mean the same
thing are the same request, so a client that reformats its JSON between a call and
its retry gets a replay rather than a conflict it did nothing to cause. The raw
bytes are not available: `CourierWeb.Plugs.ParseBody` is an *endpoint* plug, so
the body is parsed before any router pipeline runs. An empty map and no body at
all hash identically, because `POST /{id}/test` has no body and a client whose
HTTP library sends `{}` must not conflict with itself.

### What the tests assert about the world, not the status code

A create retried with one key leaves **one** endpoint and returns the first
response **byte for byte** — including the `whsec_` secret, which exists in
exactly one 201 and cannot be re-derived, so a replay that re-derived it would
hand out a secret the row never had. A ping retried with one key sends **nothing**
the second time, asserted by clearing the recording sender and finding nothing
recorded.

---

## 4. Two Elixir behaviours that made this silently not work

Both found by running the thing. Both fail **without raising anything**, which is
the reason they are written into the code rather than only into this report.

### 4.1 `conn.resp_body` inside `before_send` is iodata, not a binary

`Phoenix.Controller.json/2` encodes to iodata and `Plug.Conn` stores what it is
given, so the first draft — which required `is_binary(conn.resp_body)` — released
every single claim. Nothing raised. The request answered `201`, and the retry
created a second endpoint, which is precisely the failure the table exists to
prevent. `IO.iodata_to_binary/1` now, with the reason in
`CourierWeb.Plugs.Idempotency`.

Measured, for the record: `state: :set` inside the callback is *correct* —
`Plug.Conn.run_before_send/2` sets the state before running callbacks and raises
if a callback changes it. Only the body type was wrong.

### 4.2 Ecto's keyword `where/2` does not apply the schema's field type

A `DateTime` handed to `where(IdempotencyKey, expires_at: ^now)` reaches the
database uncast and matches **nothing** against a `utc_datetime_usec` column.
The retention sweep returned `{0, nil}` against a table that plainly held an
expired row:

```
raw SQL   SELECT count(*) … WHERE expires_at < $1   -> 1
keyword   where(IdempotencyKey, expires_at: ^now)   -> []
macro     where([k], k.expires_at < ^now)           -> the row
```

Every query in `Courier.Idempotency` now uses the macro form. This is the more
dangerous of the two, because a green test over an unexpired-only fixture would
have passed while the sweep did nothing at all.

### 4.3 One more, found the same way

`on_conflict: :nothing` cannot detect the losing insert against a schema whose
primary key is `@primary_key {:id, Ecto.UUID, autogenerate: true}`: **the id is
generated into the changeset before the query runs**, so on a real conflict Ecto
returns a struct with a fresh, well-formed uuid that was never inserted, and
`__meta__.state` is `:loaded` on it. Two inserts of one triple return two
different ids and leave one row. The claim takes the constraint error instead and
matches it on the index **by name** — `constraint_name` arrives as a string even
though `unique_constraint/3` was given an atom.

`claim/1` is deliberately **not** in a transaction, and that is a decision with a
reason: `Repo.transaction/1` replaces an error return with `{:error, :rollback}`,
so a `{:error, :taken}` would arrive as a bare rollback and the reason would have
to be smuggled out in a variable. The atomicity would buy nothing, because the
sweep only ever deletes rows that are already past their retention window.

---

## 5. Document and code, held to agreeing

The brief asked for this explicitly, "per courier-12's test". courier-12's
`openapi_error_responses_test.exs` already listed **409** among the statuses
courier could not return, with the measured reason that a duplicate `url` is a
422. That list is now wrong in exactly one entry, and the test's own failure
message says what to do about it: *"If courier has started returning one of these,
the fix is to implement it and then say so here — not to delete the line."*

So: implemented, and then said so. The 409 entries were replaced by the measured
reason that still holds (a duplicate url is a 422 `taken`), and **five** new
tests hold the two sides together:

- **a 409 courier can send is a 409 the document declares** — provoked, not
  written down: the first keyed request succeeds and is stored, the second
  presents the same key with a different body, and courier answers 409.
- **every operation the document gives the header to is behind the plug** — the
  direction a document-only check cannot see.
- **every operation behind the plug is one the document gives the header to** —
  a route courier guards but does not document is a behaviour no generated client
  has been told about.
- **each declares the 409, with `application/problem+json`.**
- **the document says the header is implemented, because it now is** — the exact
  inverse of the assertion courier-12 wrote, which was correct then and is a lie
  now. A header that quietly says the opposite of the code is the exact failure
  this file exists to prevent.

The last two directions need a reader for the document's half, so
`Courier.TestSupport.OpenAPIPaths` grew `document_idempotency_keys!/1` — and
because a reader that returns an empty set makes a comparison agree for the wrong
reason, it has **six** tests of its own in `openapi_paths_test.exs`, on synthetic
documents, with the fault that reader is most likely to have injected (one
operation inheriting another's `parameters`).

One non-obvious thing recorded there: **`pipe_through` is only on
`Phoenix.Router.route_info/4`.** Neither `__routes__/0` nor `routes/1` carries it
(the latter's route maps have keys `[:path, :metadata, :plug, :plug_opts, :verb,
:helper]` and nothing else). Reading it from the wrong one is not a crash — a
route guarded by nothing reads as one guarded by nothing, and the check goes green
on the absence of the thing it is checking for.

`openapi.yaml` goes 1.3.0 → **1.4.0**: `Idempotency-Key` on both POSTs, the two
409s, and the `Idempotency-Replayed` response header. Minor — no path changed, no
operation added or removed, nothing that existed changed shape, and a client that
sends no key is unaffected.

`CourierWeb.Problem` gained one code, `idempotency_key_reused` at 409, which
brings it to eleven — two of which now share 409, as core's own reserved list
does. `for_status/1` cannot recover which of the two a bare 409 meant, and that
is written down in the moduledoc: nothing in Phoenix raises a 409, so that
function is only ever the fallback for a status from outside a controller.

---

## 6. Ordering, stated honestly

PLAN.md §3 and this repository's `AGENTS.md` are both explicit: **tests first, and
show them red.** I did not, and the reason is worth recording rather than
glossing.

The brief framed the work as "run the checker, get it green or fix what it names",
which reads as implementation-first, and I followed that. The consequence is that
the *code* half of this packet has no demonstrated red: the new tests exercise new
modules, so they cannot pass before the modules exist, but I did not watch them
fail against an absent implementation. That is weaker than the house rule asks
for and it is a real gap in the evidence.

What I *can* show red, and did: the whole suite was **606 green while the document
was still a lie** — courier could answer 409 and `openapi.yaml` declared no 409 on
either POST, and courier-12's completeness check did not catch it, because it
provokes a list of statuses and 409 was not on it. The five new tests are what
close that, and their value is precisely that they would have failed on that
intermediate state. The document tripwire fired; the code tripwire did not get the
chance to.

---

## 7. What I did not do

- **The flaky-test files.** The brief excludes them and I touched none. Worth
  recording: `bin/gate-self-test`'s control **is** red on unmodified master
  (`d0363d1`, verified by running it in the untouched `cafaye/courier` worktree),
  and the script's own header names the cause — `deliver_test.exs:128` asserts the
  row order of a `Repo.all` with no `order_by`, measured red in 1 of 8 runs before
  this packet existed. Not mine, not retried, not slept past, not hidden.
- **`core`, and every other service.** `core`'s VERSION is a different question
  from courier's `core:` line, and the digest agrees across both runs, so nothing
  here depends on a core change.
- **Any push, tag, or remote.** The branch is committed and nothing else.
- **A `Retry-After` on the 409 `conflict`.** Tempting, and deliberately absent:
  core's reserved list has no header for it, and inventing one is a contract
  change rather than a worker's call. The `detail` says to retry instead.

## 8. Not fixed, and reported

- **`bin/gate-self-test` copies tracked files only** (`git ls-files | tar`), so a
  worker whose new files are uncommitted gets a control that cannot compile — and
  reports it as "the UNMODIFIED declaration is not green", which points at the
  gate rather than at the worktree. It cost me one confusing run before I staged
  the files. Not this packet's to change (`kit` owns the CI contract and
  `AGENTS.md` says copy, do not share), and the script's own comment acknowledges
  the untracked-declaration case only for `gate.yml`.
- **Idempotency is `POST`-only here because core's rule is.** `PUT
  /v1/notification_preferences/{user_id}` is idempotent in HTTP's definition and
  does not take the header. If a later core rule extends the header to `PUT`, the
  router pipeline is the one line to move.
