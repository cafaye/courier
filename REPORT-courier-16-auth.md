# courier-16 — the authentication gap on notification preferences

`GET` and `PUT /v1/notification_preferences/{user_id}` were reachable with no
credential at all, so any caller could read or overwrite any other tenant's
notification preferences by guessing or enumerating a `user_id`. This packet
closes it, and the closing cost a schema change — because closing it properly
required courier to know which account owns a user's preferences, and it did not
know.

## What was wrong, measured

Three places described the gap as deliberate and each was wrong by the time this
packet landed, which is why it survived as long as it did:

| where | what it said |
|---|---|
| `lib/courier_web/router.ex` | the routes are in the `:api` pipeline "only", and "changing their authorization is not this packet's business" |
| `lib/courier_web/controllers/notification_preferences_controller.ex` | "these requests are not authenticated in this packet: there is no JWT verification here yet" |
| `openapi.yaml` | `security: []` on both operations, under a `> DECISION NEEDED (courier-05)` that recommended authenticating them "in a later packet, before a customer integrates against this document" |
| `cafaye.yml` | the same note, restated |
| `test/courier_web/router_test.exs` | an **assertion** that they were not behind `:authenticated` |

The router test is the one worth dwelling on. It was not a gap in coverage; it
was a *lock* on the gap, and it would have kept passing after the fix if the fix
had not touched it. A test that asserts a security hole is present is a test that
has to be deleted in the same commit as the fix, and the report of that delete is
the only record that the hole was ever there.

**Measured before the change**, on `cc0c532`: `mix test` → `Result: 616 passed`,
all green. The hole is not something a green suite was failing to see — it is
something the suite was asserting.

## The hard part: courier cannot ask who owns a user

`user_id` is a uuid from identity. courier holds **no foreign key to it** and has
no client to ask identity with, so there was nothing to compare a caller against.
Authentication alone would have closed the anonymous case and left
cross-tenant reads and writes wide open for anyone holding *any* token.

Three options, and only one of them is not a worse hole:

1. **Ask identity.** Right, and not available: no client, no claim to check
   against, and adding one is a dependency this packet's brief rules out and a
   packet of its own in substance.
2. **Scope the row by `(account_id, user_id, notification_type)`.** Rejected, and
   the reason is a correctness bug rather than a preference: `Courier.Deliver`
   calls `NotificationPreferences.enabled?(user_id, type, :email)` with **no
   account** — the payload carries a `user_id` and nothing else. Two accounts
   holding contradictory rows for one person would leave that read choosing
   between them, with no account in the call to choose by.
3. **Record the account on the row and keep the identity of the row as the
   user.** This is what landed. One row per `(user, notification_type)` as before,
   plus a NOT NULL `account_id` naming **who is entitled to it**. Delivery is
   unaffected because it reads by user and there is exactly one row to read.

## The migration deletes, and that is the interesting part

Every row that existed was written through an unauthenticated route, so no honest
account can be given it. The alternatives:

- **Backfill a placeholder account.** Puts every user's opt-outs under an account
  nobody owns, which is one missing predicate away from being readable by every
  tenant at once.
- **Leave `account_id` nullable and treat `NULL` as "nobody's".** Same answer,
  worse shape: a nullable tenancy column invites the next query that forgets to
  filter on it, which is precisely the bug this column exists to make impossible.
- **Keep them and show them to whoever asks.** The hole.

Deleted rows read as *no preference*, and *no preference* reads as **on** — courier's
own documented invariant, *silence is not consent*. So the loss falls toward a
user courier mails rather than toward a user's mail going to someone else, and
`mix ecto.rollback` is honestly asymmetric: it drops the column and does not
restore the rows.

## What the surface answers now

| caller | `GET` | `PUT` |
|---|---|---|
| anonymous | `401` (halted in the plug, `conn.assigns[:action]` is `nil`) | `401` |
| another account, user has rows | `404 not_found` | `404 not_found`, **and writes nothing** |
| another account, user has no rows | `200` with the defaults | the write claims the user — see below |
| owning account | `200` | `200` |

The 401 is asserted to be the *same* 401 the webhook endpoints answer, by
comparing the two decoded bodies with `instance` and `trace_id` dropped rather
than by a hand-written expectation — a copy of the envelope passes against a plug
that refuses for the wrong reason.

### The limitation this leaves, stated rather than glossed

**The first authenticated `PUT` for a user id claims it.** courier cannot resolve
ownership, so whoever writes first records the owning account. An account that
writes for a user id nobody has written for gains the claim: it gets no access to
anything that existed, and the account that actually owns the user then gets a
404 and a settings page that cannot save.

That is a real weakness. It is also the only rule available without identity's
answer, and the alternative is not a better answer but no answer at all — a
service that cannot resolve ownership can let the first writer claim the resource
or refuse every write forever. When membership is reachable on the hot path this
is the comparison to add, and it is a *comparison* rather than a second source
of truth, because the column is already where the claim is recorded.

## The checks that noticed

- **`openapi_error_responses_test.exs`** discovered that two more operations must
  declare a 401. It works out the set by **provoking** each operation rather than
  from a list, which is the only reason it noticed: the list would have said
  "these two are exempt" and stayed green. It then failed because the document
  did not declare it, which is the other half of the check doing its job.
- **`router_test.exs`** failed on `pipe_through: [:api]`, as it was written to.
- **`openapi.yaml` → 2.0.0.** The previous header's own arithmetic — "cost of
  flipping now: one scope name and the plug in a scope block; cost of flipping
  later: a major `info.version` and every generated client" — was right about the
  cost and wrong about the deadline. It was paid here because no 2.x client exists
  yet.

## Two test failures that were my tests being wrong

Both were the same mistake, and both are worth recording because the code was
right and the assertion was not:

- **"another account cannot write this one's preferences"** failed until the
  owner's write came first. Without it the user had *no rows*, so the write was
  allowed — which is the first-writer-claims rule, not a bug. The test was
  asserting a 404 for a user nobody owned.
- **"the account comes from the principal and never from the body"** put
  `account_id` at the *top level* of the body, where courier reads only
  `preferences`, and expected a 422. The body's unit of validation is the entry,
  so a top-level key is invisible and an entry key is the 422. Split into two
  tests: a top-level `account_id` cannot reach the row (asserted from the other
  account's side, because "ignored" and "honoured and it happened to match" are
  the same 200), and an entry `account_id` is a 422 naming
  `preferences[0].account_id`.

## Known defect found on the way, not fixed here

**`openapi_error_responses_test.exs`'s 404 check is passing for the wrong reason
on the two preferences operations.** Its `fill/2` substitutes an id into a
*normalised* path, where the parameter segment is `{}` — and its regex is
`~r/\{[^}]+\}/`, which needs at least one character between the braces and so does
not match. The provoked request therefore goes to the literal path
`/v1/notification_preferences/{}`, whose `user_id` segment is not a uuid, and is
answered **422** — which satisfies `status in [404, 422]` and the document's
declared 422. The test's claim, "answers 404 or 422 for an id courier has never
issued", was never actually checked for these two operations.

It is pre-existing and unchanged by this packet (a non-uuid was a 422 before and
after), and fixing it properly is not a one-character change: with the regex
corrected, a well-formed unknown `user_id` is a **200 with the defaults**, which
fails the check's premise that an operation addressing a resource by id must
answer 404 or 422. Teaching that check about "the unknown-id answer is a 200" is
a design change to a file whose subject is the document, not authorization, and
the behaviour it would be checking is already asserted directly in
`notification_preferences_controller_test.exs`.

## Numbers

| | before | after |
|---|---|---|
| whole suite | 616 | **630** |
| database tier (19 files) | 358 | **372** |
| no-database tier (12 files) | 258 | 258 |
| SSRF table | 62 | 62 |
| `openapi.yaml` `info.version` | 1.4.0 | **2.0.0** |

Floors moved in the same commit: `gate.yml` `minimum` 610 → **624** (measured 630,
the margin the repository has used), and CI's whole-suite / database tiers
616 → 630 and 358 → 372.

The 14 added tests are all in the database tier and none changed a file's tier
membership, which is why the no-database count is untouched.

## Verification

- `mix precommit` — compile with warnings-as-errors, format, 630 passed.
- `bin/prime` three times — `Result: 630 passed`, exit 0 each time.
- `core/harness/bin/cafaye-contract --core ../core .` — conforms.
- `core/harness/bin/gate-check .` — 0 failures, 3 warnings (the pre-existing
  unproven-requirement warnings that do not move the exit code).
- `bin/gate-self-test` — 11 passed, 0 failed.
- `git diff --exit-code -- mix.lock` — unchanged.

**One pre-existing flake, unrelated and not introduced here.** The first
`bin/prime` of this packet failed once with `Postgrex.Error 40P01
(deadlock_detected)` in `CourierWeb.Plugs.IdempotencyTest` ("a retry with the
same key and the same body", two concurrent `create` calls under the SQL
sandbox). It reproduced on the baseline commit before any of this work and did
not reproduce in any subsequent run — including the three `bin/prime` runs above
and the `mix precommit`. It is a real defect in that test's concurrency and it is
not this packet's business; it is recorded here so the next reader of a red
`bin/prime` is not sent looking at notification preferences.
