# AGENTS.md

Conventions for `courier`, the cafaye notification service. Read this before
changing anything. The house rules in `moon/PLAN.md` §1 and §3 apply on top of
it: tests first, every packet ends in a green suite and a commit, never push
from a worker branch.

## What this repository is

`courier`, Elixir 1.20 / OTP 29, Phoenix 1.8, **API only**: no HTML, no
LiveView, no assets, no dashboard, no gettext. It owns transactional email,
notification preferences, and every outbound webhook. The contracts and the
manifest schema are owned by `cafaye/core`; `cafaye.yml` here is a draft
validated against `core/schemas/cafaye.manifest.schema.json` and is regenerated
by `caf init` when core freezes the format. Nothing is copied from
`moon/refs/jumpstart-pro` — it is a behavioral spec for later packets, and
PLAN.md §2 forbids copying from it.

## Layout

```
lib/courier/health.ex                 readiness check: does the database answer
lib/courier/release.ex                migrations from inside a release, no Mix
lib/courier/mailer.ex                 the Swoosh mailer: the adapter is config
lib/courier/mailer_adapter.ex         the provider adapter, read from the
                                      environment, and the refusal that stops
                                      courier booting into a silent one
lib/courier/mailers.ex                compose the three transactional emails
lib/courier/mailers/templates/        the bodies, compiled at build time
lib/courier/deliver.ex                the send: preference, provider, outbox row
lib/courier/events.ex                 the CloudEvents envelope and the catalog
lib/courier/outbox_event.ex           one emission, and the envelope it publishes
lib/courier/notification_preference.ex         the row behind a user's answer
lib/courier/notification_preferences.ex       read and write those answers
lib/courier/nats_publisher.ex         the behaviour the relay publishes through
lib/courier/nats_publisher/noop.ex    the stand-in that hands envelopes back
lib/courier/observability.ex          the span-attribute ALLOWLIST, and the one
                                      record/2 every span in courier goes through
lib/courier/span_collector.ex         the on-end processor, installed by hand
                                      because the SDK's own is silently dropped
lib/courier/telemetry.ex              the contract, the resource, and the SDK
                                      wiring the application controller reads
lib/courier/principal.ex              the caller, the resolver behaviour, and the
                                      default resolver that authenticates nobody
lib/courier/secret_box.ex             sealing: a signing secret at rest, AES-GCM
lib/courier/idempotency_key.ex        one (account, endpoint, key) claim, and its answer
lib/courier/idempotency.ex            claim a key, store the response, replay it
lib/courier/webhook_endpoint.ex       the row, its changesets, its status enum
lib/courier/webhook_endpoints.ex      the context: register, change, remove, trip
lib/courier/webhook_delivery.ex       one delivery, and its retry state
lib/courier/webhook_deliveries.ex     the retry budget's arithmetic
lib/courier/webhooks/signature.ex     the Standard Webhooks signature, exactly
lib/courier/webhooks/verifier.ex      the consumer's half: tolerance, HMAC check
lib/courier/webhooks/url_guard.ex     the SSRF guard: resolve, check, return target
lib/courier/webhooks/dns.ex           the resolver seam, and its :inet impl
lib/courier/webhooks/payload.ex       the bytes signed, and the ping body
lib/courier/webhooks/sender.ex        the delivery behaviour and its policy
lib/courier/webhooks/sender/req.ex    the Req implementation that ships
lib/courier/workers/process_outbox_worker.ex  the relay itself
lib/courier/workers/dispatch_webhooks_worker.ex  outbox event -> delivery rows
lib/courier/workers/deliver_webhook_worker.ex    due delivery -> signed POST
lib/courier_web/problem.ex            core's problem+json envelope, built once
lib/courier_web/plugs/trace.ex        a trace id and the path, for every request
lib/courier_web/plugs/parse_body.ex   Plug.Parsers, with courier's 400
lib/courier_web/plugs/principal.ex    who is calling; 401 when nobody is
lib/courier_web/plugs/idempotency.ex  Idempotency-Key on a mutating POST, and its 409s
lib/courier_web/plugs/problem_content_type.ex  a non-2xx is problem+json
lib/courier_web/plugs/telemetry.ex     the request span: above the router, below
                                      the parsers, and route template not path
lib/courier_web/controllers/health_controller.ex   GET /healthz, GET /readyz
lib/courier_web/controllers/notification_preferences_controller.ex  GET/PUT /v1
lib/courier_web/controllers/webhook_endpoints_controller.ex  the six /v1 actions
lib/courier_web/controllers/error_json.ex        the errors Phoenix renders
lib/courier_web/router.ex             probes at the root, /v1 for the API
test/courier/health_test.exs          the readiness check, on its own
test/courier/mailers_test.exs         what the platform hands in, per message
test/courier/mailers_config_test.exs  the sender and the subject are config
test/courier/smtp_delivery_test.exs   THE PROOF: a real send through a real
                                      SMTP adapter to a real gen_smtp server on
                                      a real socket, and the failure paths
test/courier/mailer_adapter_test.exs  the adapter courier refuses to ship
                                      without, and the two boot gates
test/courier/mailer_adapter_credentials_test.exs  a password never reaches a log
test/courier/deliver_test.exs         the three promises, in one transaction
test/courier/deliver_adapter_test.exs what happens when the provider says no
test/courier/notification_preferences_test.exs  defaults, writes, rejections
test/courier/events_test.exs          the envelope against core's schema
test/courier/nats_publisher_test.exs  the behaviour and the stand-in
test/courier/observability_test.exs   the allowlist, asserted on directly
test/courier/telemetry_test.exs       the contract, the resource, the wiring
test/courier/telemetry_canary_test.exs  THE PROOF: a canary in every field a
                                           caller controls, in nothing exported
test/courier/secret_box_test.exs      a secret is not readable from its column
test/courier/idempotency_test.exs     the claim, the refusals, the retention, the expiry
test/courier/webhook_endpoints_test.exs        the rows and their promises
test/courier/webhook_endpoints_config_test.exs the guard, with a chosen resolver
test/courier/webhook_deliveries_test.exs       the budget, the backoff, the id
test/courier/webhooks/signature_test.exs       the spec's scheme, verified twice
test/courier/webhooks/url_guard_test.exs       every blocked address class
test/courier/webhooks/payload_test.exs         the bytes on the wire
test/courier/webhooks/sender_test.exs          the request and its classification
test/courier/workers/                 the relay, the fan-out, and the sender
test/courier_web/controllers/          the API, and the authorization matrix
test/courier_web/router_test.exs      which controller, which scope, which methods
test/courier_web/plugs/idempotency_test.exs  the header over real requests: one
                                           mutation, the replays, and the three 409s
test/courier_web/openapi_document_test.exs  openapi.yaml against the router, both
                                           directions, and why the probes are
                                           the only omission
test/courier_web/openapi_paths_test.exs     the reader, a test per normalisation,
                                           and the comparison with faults injected
test/support/openapi_paths.ex        the reader and the comparison the two above
                                    are built on; copy this file, not a shared kit
test/support/recording_sender.ex      a sender that records instead of sending
test/support/header_resolver.ex       a principal that reads a header
test/support/test_dns.ex              a resolver that answers from a table
test/support/test_span_exporter.ex    the exporter that records instead of sending
test/support/test_spans.ex            reading those spans, and RAISING on empty
test/support/smtp_server.ex           a real SMTP server for the round-trip test:
                                      :gen_smtp_server on a kernel-assigned
                                      loopback port
gate.yml                              the gate, DECLARED: command, proof, what it needs
kit.ref                               the pinned kit commit the stack comes from
bin/prime                             the gate: deps, database, tests
bin/assert-suite                      refuses a run that skipped or excluded tests
bin/gate-self-test                    proves gate.yml is able to fail
bin/gate-db                           the postgres the gate needs, when the machine
                                      has none at the address config/test.exs names
bin/toolchain-pins                    reads mise.toml, checks CI has not drifted
bin/dev                               kit's, verbatim: fetch kit.ref, merge, up
.github/workflows/ci.yml              calls kit's workflow, plus gate and release
Dockerfile                            two-stage release build, slim final stage
docker-compose.yml                    an OVERRIDE on kit's stack: the courier
                                      service, its database, and the crash layer
rel/overlays/bin/server               the release entrypoint the image runs
rel/overlays/bin/migrate              the release's migration entrypoint
```

## Rules

**Tests first, and show the red.** Write the test, run it, watch it fail for the
reason you expect, then implement (PLAN.md §3). A probe test that passes
without the route is worse than no test.

**The probes are production infrastructure.** `mix test` must cover both, and
the DB-down path must be a real one: `health_controller_test.exs` stops
`Courier.Repo` under the application supervisor rather than mocking the check.
Keep the failure response terse and log the reason instead — probe responses
are read by orchestrators, and this repository is public.

**A readiness check never raises.** Anything that can go wrong with the database
comes back as `{:error, reason}` from `Courier.Health.ready?/1`. Delivery here
is at-least-once, and a probe that takes down the endpoint is a self-inflicted
outage.

**Versions live in two places, not three.** `mise.toml` and the `ARG`s at the
top of the `Dockerfile` (Elixir 1.20.4, OTP 29.1.1). `mix.exs` keeps the `~>`
floor for library consumers; do not pin an exact version there.

**No dependency without approval.** The generated Phoenix 1.8 app is the whole
dependency list. Swoosh, Oban, Broadway, and the HTTP clients for the webhook
pipeline are Phase 3 packets — not this one, not "just to prepare".

**A mailer with no adapter that can reach a provider is a silent default, and
that is worse than a crash.** courier ships `{:swoosh, "~> 1.28"}` and
`{:gen_smtp, "~> 1.0"}`, and the second one is the load-bearing half: swoosh
declares `gen_smtp` OPTIONAL and `Swoosh.Adapters.SMTP` declares it REQUIRED, so
naming swoosh alone compiles a courier whose only shipped adapter is
`Swoosh.Adapters.Local` — which renders into memory, returns a provider-shaped id
and opens no socket. That is the state this repository was in: a paid product
that accepted every send, wrote an outbox row for each, published a `delivered`
event, and mailed nobody. No error, no warning. Three rules came out of it:

  * **The adapter has no default, and prod will not boot without one.** Not
    "warned about" — refused. A running courier that cannot send is worse than
    one that will not start, because the damage is outbox rows and events
    claiming delivery, for mail that was never delivered, and nothing in a
    dashboard shows it. `Courier.MailerAdapter.adapter!/1` raises in
    `config/runtime.exs`; `Courier.Application` re-checks the EFFECTIVE adapter
    as a second, independent gate — the same input twice would catch nothing, so
    the second one reads `Application.get_env` rather than the environment.
  * **`Swoosh.Adapters.Test` and `Swoosh.Adapters.Local` are named in
    `Courier.MailerAdapter.silent_adapters/0` and asserted as a set.** A third
    silent adapter has to be classified, or the set test fails. `none` is
    permitted in dev and refused in prod; the value is a NAME from a fixed set,
    never a module name, so the silent adapter cannot be named through the front
    door the refusal was built to close.
  * **An adapter no test can exercise is an adapter nobody has checked.** So
    `gen_smtp` is in EVERY environment, not `only: :prod`, and
    `test/courier/smtp_delivery_test.exs` drives real sends through the real
    adapter to a real `:gen_smtp_server` on a real kernel-assigned loopback port.
    Mocking the adapter would prove the mock works. The mutation is the proof:
    point those tests at `Local` or `Test` and five of the six fail.

**A credential is never in a log, and never in a committed file.** At SMTP a
"username" is usually an API key, so `Courier.MailerAdapter.describe/1` prints
the host, the port and whether auth is on, and omits *both* credentials — the
startup line an operator reads is not where a password belongs.
`test/courier/mailer_adapter_credentials_test.exs` captures real log output from
real sends and asserts the secret is ABSENT, which is the assertion worth more
than "it logged something": a boundary that deletes everything passes that. Two
tests in it are about the repository rather than about a call — no committed
`config/*.exs` may carry `username:`/`password:`/`relay:` inside a
`config :courier, Courier.Mailer` block — and they are scoped to the mailer's own
block because `config/test.exs` legitimately commits `password: "postgres"` for
the test database. A scan loosened until it goes green is a scan that has stopped
looking.

One packet has been approved since, and the two names it added are
`{:opentelemetry, "~> 1.7"}` and `{:opentelemetry_exporter, "~> 1.11"}`: the
trace SDK and the OTLP exporter, in **every** environment including test, because
without them courier cannot emit a span at all and kit's collector has nothing to
redact. They are the floor, not a choice among alternatives — the alternative was
courier exporting nothing and the whole redaction boundary being untested. What
was **not** added is as load-bearing: no `opentelemetry_metrics` (the Erlang SDK
has no metrics API — measured, `ls deps/opentelemetry/src | grep -c metric` is
`0`), no `opentelemetry_logger` (logs come from the collector's `syslog/crash`
receiver via compose `logging:`, which is a property of the container rather than
a per-language SDK), and no `opentelemetry_phoenix` (it would record
`url.path`, `url.query` and headers as its own attributes, and depending on the
engine to strip them would make courier's boundary one control where this
repository insists on two).

**`mix precommit` before you commit.** It compiles with warnings-as-errors,
drops unused deps from the lockfile, formats, and runs the suite. `bin/prime`
is the gate for a clean checkout; `mix precommit` is what a change must pass.

**The gate is declared in `gate.yml`, not discovered.** Written against
`cafaye/core`'s `schemas/gate.schema.json` and checked by its
`harness/bin/gate-check`, which reads `command`, `miseTask`, `entrypoint`, the
`external.requirements`, the `ci` block, and the `proof`. Two things follow.
First, the proof: `bin/prime` must print `Result: N passed` at or above the floor
in `gate.yml`, and that is what separates a gate from a command that exits zero —
`1/1 passed` and `3/3 passed` are the same claim without a floor. When the suite
grows, **raise `gate.proof[].minimum` in the same commit**, the same rule that
already applies to CI's `bin/assert-suite` floors. Second, the requirements: the
gate needs a migrated postgres, the pinned toolchain, and one hex fetch, and
`selfContained: false` with that list is the honest answer. **A gate that needs
something and does not say so is the defect this format exists to prevent**, so
add a requirement rather than letting the gate quietly assume one.
`bin/gate-self-test` breaks `gate.yml` nine ways and asserts core's checker
catches each; it is a CI step of its own, not part of `bin/prime`, because a
self-test inside every gate invocation is a second gate that can disagree with
the first.

**The CI gate is `bin/prime`, the same command, not a CI variant of it.** If the
two can disagree, one of them is lying. The workflow adds a database, the tier
counts and the lockfile guard *around* that command; it does not reimplement it.

**A tier that CI cannot name is a tier nobody ran.** The suite partitions
exactly, by the case template: 356 tests in the 18 files that never touch
`Courier.Repo`, 372 in the 19 that do, and `mix test` is aliased to
`ecto.create` first, so a runner with no database executes *zero* of the 728 —
SSRF table included. Both counts are asserted in CI by `bin/assert-suite`, and
the SSRF table gets its own 62-test run so the log carries a line that can only
exist if that harness ran. **When you add or delete a test, raise the floor in
`.github/workflows/ci.yml` in the same commit.** Deleting a test to make CI green
is caught by the floor; adding one is caught because CI goes red until you raise
it. Both are one-line diffs, and only one of them changes what courier verifies.

**A test asserts about its own rows, never about the table's.** A count over the
whole table — `Repo.aggregate(WebhookEndpoint, :count) == 0` — is a claim about
every other test in the repository as much as about the code under test: it is
green only while nothing else has ever written a row, and red the moment one is
visible. That is the *test-level* shape of the tenant-isolation weakness D18
tracks, and it failed in about one run in nine until courier-15 gave each of the
six affected tests its own tenancy key and counted only its own account's rows.
The rule generalises past those six: **mint an account per test that needs to
assert nothing was written, and count that account.** The same reasoning covers
reads: a `Repo.all/1` with no `order_by` returns rows in PostgreSQL's order, not
insertion order, so an assertion that compares two lists must sort both sides
before it is a claim about courier rather than about the server's whim.

**The toolchain is pinned in `mise.toml` and nowhere else.** `bin/toolchain-pins`
is how CI reads it, so the workflow cannot disagree with the worktree; the one
unavoidable duplicate is kit's `versions:` input, and `bin/toolchain-pins
--check` fails when that line and `mise.toml` stop matching. Bump both or neither.

**`mix.lock` must not move when the gate runs.** A prime that resolves
differently is a prime that lets two worktrees disagree about one commit, and the
suite cannot see it. CI runs `git diff --exit-code -- mix.lock` after `bin/prime`.

**`async: false` is a comment, not a shrug.** If your test stops or restarts a
process the suite shares — `Courier.Repo`, the endpoint, the Oban queue — it must
be `async: false` and say why in a comment above `use`. The same goes for a test
that changes application env, which the whole VM shares: those live in their own
`*ConfigTest` file, as `ProcessOutboxWorkerConfigTest`,
`WebhookEndpointsConfigTest` and `DeliverWebhookWorkerBudgetTest` do.

**`openapi.yaml` and the router are held to each other by a test, in both
directions.** `test/courier_web/openapi_document_test.exs` reads the document and
`CourierWeb.Router.__routes__/0` and fails if they disagree — an operation in the
document the router does not serve, *or* a route the router serves the document
does not describe. Both are failures, not warnings: a warning nobody acts on is a
note in a file nobody reads, and PLAN.md MD6 has the platform generating client
SDKs from this document, so an omission here is a method a generated client will
not have. The only omission is `/healthz` and `/readyz`, named in the document's
header and in the test's exclusion list with the reason, and the test fails if
that list stops naming a route the router serves.

It compares **paths**, never counts: a count comparison passes on a rename and
fails on an addition, which is backwards. The readers raise rather than
under-read, because a document reader that finds nothing and a router reader that
finds nothing agree with each other, and a green check over nothing is worse than
no check. **A route added to `router.ex` is not finished until it is in
`openapi.yaml`, and an operation added to `openapi.yaml` is not finished until
the router serves it.** The only omission is `/healthz` and `/readyz`, named in
the document's header and in the test's exclusion list with the reason, and the
test fails if that list stops naming a route the router serves.

Every operation in that document requires a bearer token, including the two
notification-preferences operations, which stopped being the exception in
courier-16. `openapi_error_responses_test.exs` works out which operations must
declare a 401 by **provoking** them rather than from a list, so it is the check
that noticed; a `security:` key or a status written down in the test would each
have kept asserting the old thing and gone green.

**A preference is the user's, and the account is who owns it.**
`notification_preferences.account_id` is written from the principal and never from
a request, and the unique index stays on `(user_id, notification_type)` — one
answer per person, not one per account, which is what lets `enabled?/3` (the
delivery path, and it takes no account) keep reading by user alone. Two
consequences are load-bearing and both are asserted:

  * **A 404 is the only cross-tenant answer, and it is narrow.** A user nobody
    has written preferences for is a 200 with the defaults, because courier holds
    no foreign key to identity's users and cannot tell that user from one that
    does not exist. The 404 appears only once a row exists and belongs to another
    account, and never a 403 — see the rule above on leaking existence.
  * **The first authenticated `PUT` for a user id claims it.** courier cannot ask
    identity which account a user belongs to, so whoever writes first records the
    owning account. An account that writes for an unwritten user id therefore
    gains the claim — no access to anything that existed, and the real owner then
    gets a 404. That is a real limitation rather than a design, and it is why the
    migration that added the column **deletes** every row written through the
    unauthenticated routes instead of backfilling a guess: an unattributable
    opt-out is either visible to every tenant or to none, and "to none" fails in
    the direction courier's own rule demands, *silence is not consent*.

**A retryable `POST` claims its `Idempotency-Key` before it does the work, and
only a 2xx is kept.** The ordering is the whole mechanism: a key recorded after
the action cannot prevent anything, so `Courier.Idempotency.claim/1` runs in the
plug and the response is stored in `before_send`, with the row sitting in
`in_flight` between the two. Two properties follow and both are load-bearing:
**a request that did not succeed releases its key** rather than storing the
failure — a stored 422 would pin a caller's typo for 24 hours, and a stored 500
would pin a courier blip for the same day — and **`endpoint` is the concrete
request path**, not the route pattern, so a client that reuses one key to test
four endpoints is not refused on the second.

Two Elixir traps sit under this and are written into `CourierWeb.Plugs.Idempotency`
and `Courier.Idempotency` rather than left in this file alone, because both fail
**silently**: `conn.resp_body` inside `before_send` is **iodata, not a binary**
(`Phoenix.Controller.json/2` encodes to iodata and `Plug.Conn` stores what it is
given), and Ecto's keyword `where/2` **does not apply the schema's field type**,
so a `DateTime` compared against a `utc_datetime_usec` column matches nothing.
Use the `where([k], ...)` macro form and `IO.iodata_to_binary/1`.

**A webhook signature is not courier's to invent.** PLAN.md §7 adopted [Standard
Webhooks](https://www.standardwebhooks.com) and said "No custom scheme", which
means the base string is `msg_id.timestamp.payload`, the headers are
`webhook-id` / `webhook-timestamp` / `webhook-signature`, and a consumer can
verify a delivery with an official library without learning anything about
courier. `moon/refs/standard-webhooks/spec/standard-webhooks.md` is the authority;
cite the section in the moduledoc when you touch any of it. Renaming a header or
"improving" the base string breaks every customer integration at once, and the
only way to find out is from them.

**The signed bytes are the sent bytes.** The spec is explicit that re-serializing
a payload between signing and sending invalidates the signature. Encode once,
sign that binary, send that binary.

**Every URL a customer gives courier passes `Courier.Webhooks.UrlGuard` before
it is stored, and the address the sender dials is the one the guard checked.**
courier will HMAC a request to an attacker-chosen URL, so this is the difference
between a webhook sender and an SSRF proxy. The guard resolves the host, refuses
the URL if *any* answer is a blocked address, and returns the resolved address —
not the name — so there is no second, unchecked lookup. If you add a way to set an
endpoint's URL anywhere else, run the guard there too; a table full of
`169.254.169.254` for whatever reads it first is the failure mode.

**A signing secret is never in the database in the clear.** `Courier.SecretBox`
seals it with AES-256-GCM under `COURIER_SECRET_BOX_KEY`, and the plaintext exists
in exactly two places: the single `201` that hands it to the customer, and the
process signing with it. The tests read the column as raw SQL for that reason.
A hash is not an option here — courier has to sign *with* the bytes.

**A retry budget is bounded and visible, and there are two of them.**
`config :courier, :webhooks` holds `max_attempts` (per delivery) and
`circuit_threshold` (per endpoint), plus the backoff base, cap and jitter
divisor. PLAN.md §7 forbids naive retries, which means the numbers live in
configuration an operator can read, not in a constant inside a worker.

**Nothing sleeps.** The backoff schedule is asserted on the recorded
`next_attempt_at` and on `backoff/1`'s return value. A test that waits for a
five-minute window is a test that takes five minutes, and one that lowers the
window to make it fast is a test that stopped checking the schedule.

**An authorization decision is a 404, not a 403, for anything the caller cannot
see.** Core's `docs/openapi-conventions.md` says 403 "leaks existence". The
account comes from `conn.assigns.current_account`, never from a request body —
`CourierWeb.Plugs.Principal` is a seam with a refusing default, so a courier
without identity's JWT verifier is locked rather than open.

**One span-attribute allowlist, in `Courier.Observability`, and it is a
choke point rather than a convention.** Every attribute courier records goes
through `Courier.Observability.record/2`, which drops anything not on the list;
the list is projected from `core/schemas/telemetry/*.schema.json`. That is the
whole defence, and its realistic failure is not an attacker — it is a
well-meaning engineer in six months adding `record(span, %{"courier.payload" =>
params})` because it would help debug a delivery, in the one service in the
fleet whose payloads are other customers' data. So:

  * **Do not call `span.set_attribute/3` directly.** There is one recorder and
    it filters. A `set_attribute` on a span courier owns bypasses the allowlist
    by exactly as much as the engine will later strip — which is to say it
    succeeds.
  * **`http.route` is the route TEMPLATE**, from `Phoenix.Router.route_info/4`,
    never `conn.request_path`. A template has one value per endpoint; a concrete
    path has one per request, and kit's collector derives metrics with a
    `spanmetrics` connector that mints a series per distinct value. A 404
    therefore carries **no** route at all: the path there is caller-controlled
    text, which is both the cardinality bomb and the content leak in one move.
  * **4xx is not an error span.** Only 5xx is. A 401 or a 404 is courier
    refusing, which is courier working; an error rate that counts it is a
    function of how much guessing the platform absorbs, and an alert on it pages
    somebody to switch off the protection doing its job.
  * **No `tenant_id` on a span.** It is a resource attribute, and
    `test/courier/telemetry_test.exs` holds the resource's own shape.

`test/courier/telemetry_canary_test.exs` is the proof and it is not optional: it
plants a canary in every field a caller controls — path, query, headers, body —
drives real requests through the real router, and raises
`THE REDACTION BOUNDARY LEAKED` if it finds one in anything exported. **Every
absence assertion in that file is paired with a presence one**, because a
redaction boundary that deletes everything passes "no canary" and is useless:
three separate bugs left this suite green with nothing exported at all (an
exporter implementing `export/3` where the callback is `export/4`; an `init/1`
returning `:ok` where `{:ok, state}` was required; a `record/2` guarded on
`is_map(span)` when a span is a record). `Courier.TestSpans.rendered!/0` raises
rather than returning an empty string so that shape cannot recur silently.

**Metrics come from the collector's `spanmetrics` connector, not from courier.**
`ls deps/opentelemetry/src | grep -c metric` is `0` — the Erlang SDK ships no
metrics API at all — so there is no second implementation to be inconsistent
with kit's, and no risk of two series with the same name and different
definitions. It also runs *after* redaction, which means a derived metric can
never carry a dimension the allowlist stripped. The cost is honest and worth
stating: courier cannot emit a gauge, so **a stalled outbox relay is invisible
on the metrics signal** and shows up only as a flat trace count.

## Environment

`DATABASE_URL`, `SECRET_KEY_BASE` and `PHX_HOST`, as any Phoenix release needs,
plus one this packet added:

- **`COURIER_SECRET_BOX_KEY`** — 32 bytes, base64, the key every webhook signing
  secret is sealed under (`openssl rand -base64 32`). Required in prod and
  never defaulted: a default would be a key in version control that every
  deployment which forgot to set one would seal its customers' credentials
  under. `config/test.exs` sets a fixed one; losing the production key means
  every stored secret has to be re-issued, because the plaintext cannot be
  recovered from the ciphertext.

And one this packet added for observability, which is optional everywhere:

- **`COURIER_OTEL_ENDPOINT`** — the OTLP endpoint, defaulted to
  `http://otel-collector:4318`, which is the collector that ships with kit's
  stack (core D16: this variable is the only contract, and the collector is
  just its default value). Point it at anything speaking OTLP and courier goes
  there instead; unset it and courier exports into a collector that is not
  running, which costs spans and nothing else — there is no queue, no retry loop
  and no dial at boot. `COURIER_TENANT_ID` and `DEPLOYMENT_ENVIRONMENT` are
  resource attributes, not measurements, and both are unset by default.
  `config/runtime.exs` guards the whole block with `config_env() != :test`: that
  guard is load-bearing, because `runtime.exs` runs *after* `test.exs` and an
  unguarded line would replace the suite's in-memory exporter with a real one —
  and every redaction test asserts the **absence** of a canary, so with nothing
  exporting they would all go green having proved nothing.

And eight from the provider adapter, all read from `config/runtime.exs` by
`Courier.MailerAdapter`, **required in every environment including test** and
never committed to a config file. Only the four with a correct default are
defaulted (`COURIER_SMTP_PORT` 587, `COURIER_SMTP_AUTH` and `COURIER_SMTP_TLS`
`always`, `COURIER_SMTP_SSL` `false`); the adapter itself is required, because an
adapter with a default is wrong for exactly the deployments nobody is watching.

- **`COURIER_MAIL_ADAPTER`** — `smtp`, the only adapter courier ships. `none` is
  `Swoosh.Adapters.Local` and is **refused in production**. Unset is a boot
  failure, not a fallback to `none`. A module name is not a value: the variable
  names a provider from a fixed set, so `Swoosh.Adapters.Local` cannot be spelled
  here even if somebody wants it to.
- **`COURIER_SMTP_HOST`** — required when the adapter is `smtp`.
- **`COURIER_SMTP_USERNAME`** / **`COURIER_SMTP_PASSWORD`** — required unless
  `COURIER_SMTP_AUTH=never`, because `gen_smtp` refuses `auth: :always` without
  both halves at the socket, and a per-send failure there is the same defect one
  layer out.
- **`COURIER_SMTP_AUTH`** — `always` (default), `never`, `if_available`.
- **`COURIER_SMTP_TLS`** — `always` (default), `never`, `if_available`.
- **`COURIER_SMTP_SSL`** — `false` by default; `true` for implicit TLS, usually
  on 465.

An empty string counts as **unset** for all of them: `SMTP_PASSWORD=` in a compose
file produces `""`, and an empty password sent to a provider comes back as a 535
the operator has no way to explain. Losing `COURIER_MAIL_ADAPTER` means courier
does not start, which is the point — it is the cheapest possible way to find out,
and it happens before the first customer mail rather than after a support ticket.

For templates, without a relay: `COURIER_MAIL_ADAPTER=none mix phx.server`.

## Toolchain

mise, from `mise.toml`: `mise install`, then `mise run prime` for the gate.
For container work: `docker compose up --build` starts postgres:17-alpine and the
release image, and `docker compose down -v` throws the volume away.

## Generated rules

Everything below this line is the Phoenix 1.8 generator's own guidance, kept
between its `usage-rules` markers so `mix phx.new` upgrades can replace it. The
HTML, LiveView, Tailwind, and icon rules are inert here — courier has no HTML
layer — but the Elixir, Mix, Test, and Ecto rules all apply.

This is a web application written using the Phoenix web framework.

## Project guidelines

- Use `mix precommit` alias when you are done with all changes and fix any pending issues
- Use the already included and available `:req` (`Req`) library for HTTP requests, **avoid** `:httpoison`, `:tesla`, and `:httpc`. Req is included by default and is the preferred HTTP client for Phoenix apps

### Phoenix v1.8 guidelines

- **Always** begin your LiveView templates with `<Layouts.app flash={@flash} ...>` which wraps all inner content
- The `MyAppWeb.Layouts` module is aliased in the `my_app_web.ex` file, so you can use it without needing to alias it again
- Anytime you run into errors with no `current_scope` assign:
  - You failed to follow the Authenticated Routes guidelines, or you failed to pass `current_scope` to `<Layouts.app>`
  - **Always** fix the `current_scope` error by moving your routes to the proper `live_session` and ensure you pass `current_scope` as needed
- Phoenix v1.8 moved the `<.flash_group>` component to the `Layouts` module. You are **forbidden** from calling `<.flash_group>` outside of the `layouts.ex` module
- Out of the box, `core_components.ex` imports an `<.icon name="hero-x-mark" class="w-5 h-5"/>` component for hero icons. **Always** use the `<.icon>` component for icons, **never** use `Heroicons` modules or similar
- **Always** use the imported `<.input>` component for form inputs from `core_components.ex` when available. `<.input>` is imported and using it will save steps and prevent errors
- If you override the default input classes (`<.input class="myclass px-2 py-1 rounded-lg">)`) class with your own values, no default classes are inherited, so your
custom classes must fully style the input


<!-- usage-rules-start -->

<!-- phoenix:elixir-start -->
## Elixir guidelines

- Elixir lists **do not support index based access via the access syntax**

  **Never do this (invalid)**:

      i = 0
      mylist = ["blue", "green"]
      mylist[i]

  Instead, **always** use `Enum.at`, pattern matching, or `List` for index based list access, ie:

      i = 0
      mylist = ["blue", "green"]
      Enum.at(mylist, i)

- Elixir variables are immutable, but can be rebound, so for block expressions like `if`, `case`, `cond`, etc
  you *must* bind the result of the expression to a variable if you want to use it and you CANNOT rebind the result inside the expression, ie:

      # INVALID: we are rebinding inside the `if` and the result never gets assigned
      if connected?(socket) do
        socket = assign(socket, :val, val)
      end

      # VALID: we rebind the result of the `if` to a new variable
      socket =
        if connected?(socket) do
          assign(socket, :val, val)
        end

- **Never** nest multiple modules in the same file as it can cause cyclic dependencies and compilation errors
- **Never** use map access syntax (`changeset[:field]`) on structs as they do not implement the Access behaviour by default. For regular structs, you **must** access the fields directly, such as `my_struct.field` or use higher level APIs that are available on the struct if they exist, `Ecto.Changeset.get_field/2` for changesets
- Elixir's standard library has everything necessary for date and time manipulation. Familiarize yourself with the common `Time`, `Date`, `DateTime`, and `Calendar` interfaces by accessing their documentation as necessary. **Never** install additional dependencies unless asked or for date/time parsing (which you can use the `date_time_parser` package)
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Predicate function names should not start with `is_` and should end in a question mark. Names like `is_thing` should be reserved for guards
- Elixir's builtin OTP primitives like `DynamicSupervisor` and `Registry`, require names in the child spec, such as `{DynamicSupervisor, name: MyApp.MyDynamicSup}`, then you can use `DynamicSupervisor.start_child(MyApp.MyDynamicSup, child_spec)`
- Use `Task.async_stream(collection, callback, options)` for concurrent enumeration with back-pressure. The majority of times you will want to pass `timeout: :infinity` as option

## Mix guidelines

- Read the docs and options before using tasks (by using `mix help task_name`)
- To debug test failures, run tests in a specific file with `mix test test/my_test.exs` or run all previously failed tests with `mix test --failed`
- `mix deps.clean --all` is **almost never needed**. **Avoid** using it unless you have good reason

## Test guidelines

- **Always use `start_supervised!/1`** to start processes in tests as it guarantees cleanup between tests
- **Avoid** `Process.sleep/1` and `Process.alive?/1` in tests
  - Instead of sleeping to wait for a process to finish, **always** use `Process.monitor/1` and assert on the DOWN message:

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

   - Instead of sleeping to synchronize before the next call, **always** use `_ = :sys.get_state/1` to ensure the process has handled prior messages
<!-- phoenix:elixir-end -->

<!-- phoenix:phoenix-start -->
## Phoenix guidelines

- Remember Phoenix router `scope` blocks include an optional alias which is prefixed for all routes within the scope. **Always** be mindful of this when creating routes within a scope to avoid duplicate module prefixes.

- You **never** need to create your own `alias` for route definitions! The `scope` provides the alias, ie:

      scope "/admin", AppWeb.Admin do
        pipe_through :browser

        live "/users", UserLive, :index
      end

  the UserLive route would point to the `AppWeb.Admin.UserLive` module

- `Phoenix.View` no longer is needed or included with Phoenix, don't use it
<!-- phoenix:phoenix-end -->

<!-- phoenix:ecto-start -->
## Ecto Guidelines

- **Always** preload Ecto associations in queries when they'll be accessed in templates, ie a message that needs to reference the `message.user.email`
- Remember `import Ecto.Query` and other supporting modules when you write `seeds.exs`
- `Ecto.Schema` fields always use the `:string` type, even for `:text`, columns, ie: `field :name, :string`
- `Ecto.Changeset.validate_number/2` **DOES NOT SUPPORT the `:allow_nil` option**. By default, Ecto validations only run if a change for the given field exists and the change value is not nil, so such as option is never needed
- You **must** use `Ecto.Changeset.get_field(changeset, :field)` to access changeset fields
- Fields which are set programmatically, such as `user_id`, must not be listed in `cast` calls or similar for security purposes. Instead they must be explicitly set when creating the struct
- **Always** invoke `mix ecto.gen.migration migration_name_using_underscores` when generating migration files, so the correct timestamp and conventions are applied
<!-- phoenix:ecto-end -->

<!-- usage-rules-end -->