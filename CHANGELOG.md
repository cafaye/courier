# Changelog

All notable changes to cafaye **courier** are recorded here. courier is a
service, so "notable" means *a change to the HTTP surface, the event contract,
or the way it is built and run* — not a refactor that a caller cannot see.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
the project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
once courier is past `0.1.0`. The manifest records the platform-facing contract
surface in [`cafaye.yml`](cafaye.yml); a change to the events or the API
document lands in both files in one commit, because core asserts the two agree.

## [Unreleased]

courier can send a transactional mail, honour what the user asked not to receive,
record every send as an event that its own relay publishes, and deliver those
events to customer HTTP endpoints with the Standard Webhooks signature scheme.

### Added

- **`openapi.yaml` now declares every error it can return, and a test proves the
  document and the code agree about them.** courier-12 was opened on a claim that
  the RFC 9457 envelope was defined in `components` and wired to nothing.
  Re-measured, that specific claim no longer reproduced — courier-05 had already
  attached the envelope to all four responses the document declared. What did
  reproduce, and what this closes, is the version of the same defect one level
  down: **every one of the eight operations could answer a `500` and a `406`, and
  none of them declared either.** A client generated from this document had no
  way to learn that. All eight now declare both, and `info.version` goes
  `1.2.0` → `1.3.0` — a minor bump, because no path changed, no operation was
  added or removed, and no request or response that already existed changed
  shape.
  - **`400` moved in both directions, because the parser's verb list is not the
    one it looks like.** `Plug.Parsers` reads a body for `POST`, `PUT`, `PATCH`
    **and `DELETE`**, so `DELETE /v1/webhook_endpoints/{id}` was reachable at
    400 and declared nothing — a client that sends a body with its delete gets a
    response no document described. The mirror of that was already wrong in the
    document: `GET /v1/notification_preferences/{user_id}` declared a 400, and
    `Plug.Parsers` **does not read a body on a `GET`**, so that 400 is
    unreachable and a client generated from it writes a branch that can never
    run. The 400 is removed there and added to the delete. The new check compares
    the document against the parser in **both** directions — declared ⇒ reachable
    and reachable ⇒ declared — for every operation, which is how both halves were
    found.
  - **`test/courier_web/openapi_error_responses_test.exs` is the new check**, and
    it is the language-specific half a neutral harness cannot be: it provokes
    each status against the running endpoint and asks the document whether it
    admits it. There is no table of statuses per operation written down in it,
    because a table is a check that can only fail for a case somebody remembered
    to type — the operations come from the document and the router, path
    parameters are filled in mechanically, and the statuses come from sending
    requests. `test/support/openapi_paths.ex` grew `document_responses!/1` and
    `component_responses!/1` to read what is declared, and a `$ref` to a
    component the document does not define is now a raised error rather than a
    response that looks wired and is not.
  - **The document's header now admits what courier does *not* return**, with the
    measured reason for each: `403`, `409`, `415`, `429` and `503` on `/v1`, and
    `Idempotency-Key`, which courier accepts and ignores. A test asserts both
    halves — that no operation declares one of those statuses, and that the
    header says why — so the omission is an admission rather than a silence. The
    two checks that already existed stay as they were; nothing was weakened.
- **`errors[].detail` is now declared.** courier has been sending it inside a
  422's `errors[]` — a bad `limit` reads "is not a positive integer" rather than
  only `invalid_format` — and the schema did not mention it. It is optional and
  says so, because only some entries carry one.

### Fixed

- **A `406` no longer reports itself as `internal`.**
  `CourierWeb.Problem.for_status/1` had no entry for 406, so it fell through to
  the `:internal` default and a client that asked for `text/html` was answered
  `{"status": 406, "code": "internal", "title": "Internal server error"}` — its
  own `Accept` header reported back to it as courier having failed, wearing the
  one code every generated client retries. `internal` is core's reserved slug
  for 500. Declaring a 406 in the document while it said that would have put the
  lie into the permanent contract, so the code was fixed first. Measured over a
  real socket, because `Phoenix.NotAcceptableError` carries no conn and
  `Phoenix.ConnTest` cannot see the response it produces.

- **`openapi.yaml` and the router are now held to each other by a test, in both
  directions.** `test/courier_web/openapi_document_test.exs` reads the document
  and `CourierWeb.Router.__routes__/0` and fails if either describes an operation
  the other does not. It compares **paths, never counts** — a count comparison
  passes on a rename and fails on a pure addition, which is backwards — and its
  readers raise rather than under-read, because two readers that both find
  nothing agree with each other and a green check over nothing is worse than no
  check. The route set comes from the router's own definitions rather than a
  list written out in a test, which is the shape that can only fail for a name
  somebody remembered. `/healthz` and `/readyz` are the only omission: they are
  named in the document's header and in the test's exclusion list with the
  reason, keyed by method *and* path so a carve-out cannot cover a second method
  on the same path, and the test fails if that list stops naming a route the
  router actually serves.
- **`GET` and `PUT /v1/notification_preferences/{user_id}` are now in
  `openapi.yaml`.** They were in the router with tests behind them and absent
  from the document, which courier-03 flagged rather than leaving quietly; that
  was the right call and this closes it. The document's operation count goes
  from 6 to 8 and `info.version` from `1.1.0` to `1.2.0` — a minor bump, since
  nothing that already existed changed shape. The document no longer describes
  itself as partial: it now covers every route except the two probes, and both
  it and `test/courier_web/openapi_document_test.exs` say so.
- **CI, and it calls `cafaye/kit` rather than copying it** —
  `.github/workflows/ci.yml` is a six-line `uses:` for kit's reusable workflow
  plus the two jobs kit cannot own. It is the first CI this repository has had:
  every "the gate is green" claim for courier so far rested on whoever ran the
  suite by hand, on that day, on that machine.
  - **The shared half** — `uses: cafaye/kit/.github/workflows/ci.reusable.yml@master`
    with `language: elixir`, the working directory, the toolchain pinned from
    `mise.toml`, a coverage floor, and telemetry off. The `.github/workflows/`
    in that path is load bearing: GitHub does not resolve subdirectories of the
    workflows directory, which is why the file kit shipped at
    `workflows/ci.reusable.yml` was unreachable from every caller in the fleet.
  - **The gate** — `bin/prime`, unmodified, against a `postgres:17` service
    container, then each test tier named and counted: 564 in the whole suite,
    252 without a database, 312 with it, 62 in the SSRF table on its own. Every
    count is asserted, so a tier cannot quietly stop running, and a deleted test
    cannot keep the badge green. The files in each tier are derived from the
    case templates, so a new test file cannot fall outside one.
  - **The lockfile guard** — `git diff --exit-code -- mix.lock` after the gate. A
    prime that resolves differently lets two worktrees disagree about one commit,
    and a green suite cannot see that.
  - **The release and its boot contract** — `mix release` on the pinned
  toolchain (the only thing here that compiles in `:prod`), then three
  assertions: the release refuses to boot without `COURIER_SECRET_BOX_KEY` and
  names it, accepts a test-only key and then refuses on `DATABASE_URL`, and
  with both set seals under the key it was given. The key used there is a
  test-only fixture; nothing in `config/runtime.exs` reads a default, and the
  first assertion is the proof.
- **`bin/assert-suite`** — asserts a `mix test` run executed everything it
  reports. It accepts exactly one shape of ExUnit's summary (`Result: N passed`)
  and fails on a fraction, on a skipped or excluded count, and on `0 tests`, so a
  run cannot satisfy itself by having verified less.
- **`bin/toolchain-pins`** — reads the `[tools]` pins out of `mise.toml` so CI
  builds with the toolchain `mise install` gives a developer, and checks kit's
  `versions:` input against the same file, so the one version literal GitHub
  cannot avoid cannot drift into a second toolchain.
- **Outbound webhooks, signed per [Standard Webhooks](https://www.standardwebhooks.com)**
  — PLAN.md §7 adopted the spec with "No custom scheme", so a consumer verifies a
  courier delivery with an official library (Svix's, Twilio's, Kong's,
  Supabase's) and learns nothing about courier. The implementation is exact:
  - **Base string** — `msg_id.timestamp.payload`, spec §Signature scheme ("the
    message's: ID, timestamp and body are concatenated (delimited by
    full-stops)").
  - **Algorithm** — HMAC-SHA256, symmetric, identifier `v1`, serialized
    `v1,<base64>`, per the spec's §Signature scheme table.
  - **Secret** — `whsec_` + base64 of 32 random bytes, the spec's serialization
    and inside its 24–64 byte range.
  - **Headers** — `webhook-id`, `webhook-timestamp`, `webhook-signature`, and no
    fourth header, per spec §Webhook headers.
  - **Replay protection** — a 300-second tolerance on `webhook-timestamp`, the
    number every reference implementation in `refs/standard-webhooks/libraries/`
    uses, enforced by `Courier.Webhooks.Verifier` and published to consumers so
    they are not left to guess the one value that decides whether a replay is a
    replay.
  - **Body** — the CloudEvents envelope, encoded once so the bytes signed are the
    bytes sent, which the spec calls "a very common failure mode" when it is not.
  The expected HMAC in `Courier.Webhooks.SignatureTest` is computed in the test
  from the spec's base string, not by calling the signer.
- **`Courier.Webhooks.UrlGuard`** — the SSRF guard, and the reason this packet
  could not have been written without one: courier signs requests to a URL a
  *customer* chose, which is an SSRF machine. It resolves the host, refuses the
  URL when **any** answer is a blocked address (a public name answering with
  `127.0.0.1` is the attack), and returns the resolved address for the sender to
  dial with the registered name as the `Host` header — so the address that was
  checked is the address that is connected to. Refused: non-http(s) schemes,
  loopback, `0.0.0.0`/`::`, link-local `169.254.0.0/16` and `fe80::/10`, RFC1918,
  `fc00::/7`, IPv4-mapped IPv6, multicast and reserved, `localhost` and `.local`,
  and a zone id. Sixty tests, one per blocked class.
- **`webhook_endpoints`** — uuid id, `account_id` with no foreign key (identity
  owns accounts and there is no table here to point at), url validated for shape
  and then run through the guard, description, `status` enum, `UNIQUE
  (account_id, url)` and a check constraint, both enforced by the database and not
  only by the changeset. The signing secret is generated by courier, sealed with
  AES-256-GCM (`Courier.SecretBox`) and returned exactly once in the 201; it is
  not a castable field, so a body naming its own secret is ignored.
- **`webhook_deliveries`** — one row per `(endpoint, event)` rather than per
  attempt, which is what makes the spec's "the same id on every retry" true by
  construction: there is only ever one `webhook_id` per delivery. Carries status
  (`pending`/`succeeded`/`failed`/`exhausted`), attempt, status code, duration,
  the reason, and `next_attempt_at`.
- **`POST`, `GET`, `GET /:id`, `PATCH /:id`, `DELETE /:id`, `POST /:id/test`** —
  `/v1/webhook_endpoints`, JSON, cursor-paginated per core's conventions. The
  create response carries the `whsec_` secret; no other action can produce it.
- **`Courier.Workers.DispatchWebhooksWorker`** — fans an outbox event out to the
  enabled endpoints of its account, idempotent three ways: the mark and the
  deliveries commit together, `(endpoint_id, event_id)` is unique, and the claim
  is `for update skip locked`. Events with no account are skipped: `Courier.Deliver`
  records `email.delivered` for a *person*, and fanning those out to every account
  would deliver one customer's mail events to another.
- **`Courier.Workers.DeliverWebhookWorker`** — sends what is due and records the
  answer. The classification is the spec's §Delivery success and failure table:
  `2xx` succeeds, `5xx`/`408`/`429`/no-response retry, `3xx` and other `4xx` are
  recorded and not retried, and `410 Gone` disables the endpoint immediately
  because the spec says a receiver answering it "should disable the webhook
  endpoint, and stop sending it messages".
- **`Courier.Principal` and `CourierWeb.Plugs.Principal`** — the shape of "who is
  calling", settled before the packet that fills it in. An anonymous request is a
  401 on every webhook action, the account comes from the principal and never
  from the body, and the default resolver authenticates *nobody* — so a deployed
  courier without identity's JWT verifier refuses every webhook request rather
  than serving them to whoever asks.
- **`webhooks_dispatched_at` and `account_id` on `outbox_events`** — courier's
  additions to core's table, the way `last_error` is. `account_id` is whose
  endpoints an event goes to; `webhooks_dispatched_at` is when it was fanned out,
  which is a different moment from `published_at`.
- **`:req`** — the one dependency this packet adds, and the one this repository's
  own generated rules name as preferred over `:httpoison`, `:tesla` and
  `:httpc`. `Courier.Webhooks.Sender.Req` sets `redirect: false`, because the spec
  says a `3xx` is a failure and following redirects wastes both ends' load — and
  because a redirect to `169.254.169.254` would be an SSRF hop the guard never saw.
- **`COURIER_SECRET_BOX_KEY`** — the 32-byte key signing secrets are sealed under,
  required at boot in prod and never defaulted. A default would be a key in
  version control that every deployment that forgot to set one would seal its
  customers' credentials under.

### Security

- **The two `notification_preferences` operations are documented as served
  without authentication** (`security: []`), because that is what the router
  does: they are in the `:api` pipeline only, and the gap is recorded in
  `CourierWeb.NotificationPreferencesController`'s moduledoc and pinned by
  `router_test.exs`. Core's `docs/openapi-conventions.md` asks for required
  scopes on every operation, so this is a disagreement with the contract rather
  than a settled fact, and it is a `> DECISION NEEDED (courier-05)` in the
  document's header. **It should be closed before a customer generates a client
  from this document**: a client built against `security: []` sends no token, so
  authenticating them later is a major `info.version` bump and a regenerated SDK
  for everyone who already did.
- **The retry budget is bounded, in two places** (PLAN.md §7). A delivery is
  attempted at most 8 times: 5 minutes apart at first, doubling, capped at 6 hours,
  with jitter drawn from the headroom *under* the cap. A full budget spans about
  sixteen hours. Separately, an endpoint is disabled after 5 consecutive failures,
  with the count and the last error recorded so "why did delivery stop" has an
  answer that is not in a log. `410 Gone` skips the count entirely.
- **A customer-disabled endpoint is not courier-disabled.** `disabled_reason` is
  what tells them apart: a success re-enables an endpoint courier tripped and
  leaves one the customer turned off alone, and re-enabling a tripped endpoint
  clears the count courier showed them.

### Tests

Three hundred and forty-one more, all written before the code they cover. The ones
worth naming:

- **`Courier.Webhooks.SignatureTest`** computes the expected HMAC from the spec's
  base string in the test file, by code that is not the signer. A test asserting
  the signer against itself passes even when the base string is wrong.
- **`Courier.Webhooks.UrlGuardTest`** asserts each blocked address class
  individually, and covers the three parser bugs the tests found:
  `URI.parse/1` truncates a bracketed IPv6 host to its first four characters,
  `Integer.parse/1` partial matches made a port stripper split IPv6 literals at
  their first colon, and `:inet` answers IPv6 as a tuple while `getaddrs` answers a
  list. Each one fails closed — blocking every public address — and each was
  found by a test, not by reading the code.
- **The authorization matrix** is every action × {anonymous, other account, own
  account}, asserted rather than described, plus a router test that every webhook
  route is behind the authenticated pipeline.
- **Nothing sleeps.** The backoff schedule is asserted on the recorded
  `next_attempt_at` and on `backoff/1`'s return value, never by waiting for a
  window to elapse. The one test that cares that a delivery is *not* picked up
  early is the one call in its file that does not move the clock.
- **The same `webhook_id` on every attempt**, asserted across a whole budget:
  delivery is at-least-once, so a consumer deduplicating on it must see one event
  however many times courier retried.

## [0.1.0] — courier-02

courier can send a transactional mail, honour what the user asked not to receive,
and record every send as an event that its own relay publishes.

### Added

- **Swoosh and Oban** — the two dependencies this packet needed, and nothing
  else. `Swoosh.Adapters.Test` in test, `Swoosh.Adapters.Local` in dev and prod:
  a released courier exercises the whole pipeline without mailing anyone.
- **`Courier.Mailers`** — `build/2` composes `welcome`, `password_reset` and
  `team_invitation` and returns a `Swoosh.Email`; `deliver/2` is that plus
  `Courier.Mailer`. Bodies are templates under
  `lib/courier/mailers/templates/`, compiled at build time and wrapped in one
  shared layout per format. The sender and the subject lines are configuration
  (`config :courier, :mailing`, address from `MAIL_FROM` at boot), because they
  are the two things an operator should reword without touching a module.
- **`Courier.Deliver`** — the three public sends, plus `email/2` for a type the
  caller has as data. Order of the checks is the contract: unknown type, then
  missing user, then an unrenderable payload (refused *before* the provider is
  asked), then the user's preference. What is left is one transaction that calls
  the provider and writes `outbox_events`, so a send nobody made and a row
  nobody can see cannot both be true. Returns the message id — also sent as a
  real `Message-ID` header — and the event's id.
- **`Courier.NotificationPreferences`** — one row per (user, notification type),
  defaults all-on, `list/1` never writes. A rejected batch stores nothing, an
  entry that names no channel leaves the stored value alone, and `push` is stored
  and returned without being a delivery decision anything acts on.
- **`GET` and `PUT /v1/notification_preferences/:user_id`** — JSON, under the
  `/v1` prefix core's conventions require. An unknown user is a 200 with three
  types on, not a 404: identity owns the user table, and a 404 would be courier
  claiming to know something about the requester it does not know.
- **The problem+json error envelope** — `CourierWeb.Problem` builds it, and
  every non-2xx response uses it: `application/problem+json` with a stable
  `https://errors.cafaye.com/<code>` `type`, a `code`, a `detail`, the `instance`
  path, a `trace_id` that matches the `X-Trace-Id` header, and per-field
  `errors[]` on a 422. `CourierWeb.Plugs.Trace` assigns both the id and the path
  before the router runs, so a request that matched no route is answered from the
  same id as everything else. Per-field names are the *request's*
  (`preferences[0].notification_type`), because the body is what a caller can fix.
- **`Courier.Events`** — the CloudEvents envelope, and the catalog of the types
  courier may emit, which `Courier.EventsTest` checks against this repository's
  `cafaye.yml` in both directions.
- **`outbox_events`, `notification_preferences`, `oban_jobs`** — the three
  migrations. `outbox_events` is core's table (see
  `core/docs/event-outbox.md`) with courier's column names and one addition,
  `last_error`, so a refused publish says why without reconstructing Oban's job
  history.
- **`Courier.Workers.ProcessOutboxWorker`** — the relay: claim a batch with
  `for update skip locked`, publish each through `Courier.NatsPublisher`, mark
  `published_at` from the acknowledgement and never before, record the attempt
  and the reason otherwise, leave a row alone once it has exhausted its
  attempts, and let one refusal stand between the rows behind it. Batch size,
  attempt cap and backoff are read from application env at runtime.
- **`Courier.NatsPublisher`** — the behaviour, and `Noop`, which hands each
  envelope to the process that published it. That hand-off is what lets the relay
  be tested end to end with no broker, and it means the Gnat publisher is a
  config change (`config :courier, :nats_publisher`) and not a rewrite.

### Changed

- **Event types are now three segments: `courier.email.delivered`, not
  `email.delivered`.** courier-01/02 shipped the two-segment spelling, and
  `caf contract lint` rejects it: core's frozen `eventType` grammar is
  `^[a-z][a-z0-9]*(-[a-z0-9]+)*\.[a-z][a-z0-9]*(_[a-z0-9]+)*\.[a-z][a-z0-9]*(_[a-z0-9]+)*$`
  and core's `docs/event-naming.md` §courier records the same drift ("courier's
  own manifest says `email.queued` and four siblings, which core v0.2's frozen
  grammar rejects"). `Courier.Events` and `cafaye.yml` now agree with it, and
  `Courier.EventsTest` checks the two against each other. **This changes the
  `type` on events already on the bus**, so any consumer that matches on
  `email.delivered` needs `courier.email.delivered`.
- **`exposes.api` now points at `openapi.yaml`**, courier's first documented HTTP
  surface. The document covers `/v1/webhook_endpoints`; the notification
  preferences routes exist and are tested but are not in it yet, which the file
  says in its own header rather than implying a completeness it does not have.
- **`CourierWeb.ErrorJSON`** no longer renders the Phoenix default body
  (`%{errors: %{detail: "Not Found"}}`) that `0.1.0` shipped. That shape is not a
  cafaye error body, and every client in this platform is written against
  `application/problem+json` with a stable `code`. `ErrorJSONTest` changed with it.

### Tests

A hundred and thirty, written before the code they cover, all written *first* in
this packet: the mailers, the deliver path, the preferences, the API, the
envelope, and the relay. What is worth naming:

- The provider is never mocked to make it fail — `Courier.TestSupport.FailingAdapter`
  is a real Swoosh adapter, because the Test adapter cannot fail and "the
  provider said no" has to be tested through the real path.
- Nothing sleeps. The relay is exercised in-process with `Oban.Testing.perform_job/3`,
  so a row is marked before the assertion reads it, and "one refusal does not
  hold up the rows behind it" is a publisher that refuses exactly one
  notification type.
- The tests that change application env are `async: false` and say why in a
  comment above `use`.
- Four assertions in the packet's own test files had to be corrected, because they
  could not pass as written: an envelope that omitted `specversion` while the
  next test asserted it, two `DateTime.from_iso8601/1` matches against a two-tuple
  the pinned Elixir has not returned since 1.4, a `Keyword.keys/1` on changeset
  errors keyed by request strings (which is what the AGENTS.md rule against
  `String.to_atom/1` on user input forces), and a relay fixture whose assertion
  asked for newest-first under a test named "publishes oldest first". Each edit
  says so in a comment at the line.

### Known gaps

- **No provider adapter.** `Swoosh.Adapters.Local` everywhere but test: a send
  succeeds and nothing is delivered. The provider packet replaces one line of
  configuration and needs credentials in `config/runtime.exs`.
- **No authentication on `/v1`.** There is no JWT verification here yet, so what
  the tests cover is shape and semantics, not who may ask. `consumes` is still
  empty and nothing subscribes courier to identity or billing events.
- **No NATS.** The relay publishes to a stand-in. Gnat is `config :courier,
  :nats_publisher` and a module that declares the behaviour.
- **No push, no inbound webhooks, no bounce or complaint handling.** The other
  four catalogued event types are declared and not emitted; `email.bounced` and
  `email.complained` need a provider webhook before they mean anything.
- **Templates are EEx, not HEEx.** This dependency set has no HEEx engine
  (`phoenix_template` 1.1, no LiveView, no `phoenix_component`) and the brief's
  "no dependency without approval" rule outranks the packet's wording. The one
  free-text field per message is escaped where it enters the template assigns.
- **No outbox retention, and no alert on `attempt_count` or on the age of the
  oldest unpublished row** — both are on core's checklist and both want the
  runtime numbers a running relay produces.
- **A readiness failure caused by a database that vanished under a running pool
  still takes about 4.4s** (from `0.1.0`; see `Courier.Health`).

## [0.1.0] — 2026-09-30

First cut: a deployable service with no notification logic in it. The point of
this release is that the next packets have a place to land and a gate to pass,
not that courier can send email.

### Added

- **Scaffold** — Phoenix 1.8.15 API-only application (`mix phx.new --no-html
  --no-assets --no-dashboard --no-gettext --no-mailer`), Elixir 1.20.4 on OTP
  29.1.1, Ecto with Postgres. No Swoosh, no Oban, no webhook delivery.
- **`GET /healthz`** — liveness. `200 {"status":"ok"}` whenever the endpoint can
  dispatch a request; it never touches the database, so a database outage cannot
  make an orchestrator restart a healthy container.
- **`GET /readyz`** — readiness. `200 {"status":"ok"}` when the database answers
  a query, `503 {"status":"error","checks":{"database":"unavailable"}}` when it
  does not. The underlying reason is logged, never returned.
- **`Courier.Health`** — the readiness check itself, as `ready?/0` and
  `ready?/1`. Every database failure mode (repo not started, pool gone,
  connection refused, timeout) comes back as `{:error, reason}`; a probe must
  never be able to take down the endpoint that serves it.
- **Probe SSL exemption** — `config/prod.exs` excludes `/healthz` and `/readyz`
  from `force_ssl`. Without it a released courier answers `301` to https on its
  own probes and an orchestrator reads that as a dead service.
- **`Dockerfile`** — two-stage build: a `hexpm/elixir` builder that compiles a
  `mix release` carrying its own ERTS, and a slim Debian final stage with no
  Erlang, no Elixir and no toolchain, running as `nobody`, with a `HEALTHCHECK`
  against `/readyz`.
- **Release scripts** — `rel/overlays/bin/server` (the image's entrypoint) and
  `rel/overlays/bin/migrate`, with `Courier.Release` for running migrations
  without Mix.
- **`docker-compose.yml`** — `postgres:17` plus that release image, with the app
  gated on `pg_isready`.
- **`bin/prime`** — the gate: `mix local.hex --force && mix deps.get && mix
  ecto.setup && mix test`.
- **`mise.toml`** — the Elixir and Erlang pins, and `mise run prime`.
- **`cafaye.yml`** — the manifest, validated against
  `core/schemas/cafaye.manifest.schema.json`. Declares the five event types in
  core's courier catalog; none is emitted yet.
- **`AGENTS.md`**, **`README.md`**, **`.gitignore`**, **`.dockerignore`**.

### Tests

Seventeen, all written before the code they cover.

- The probes, through `ConnCase`, including the database-down path — which stops
  `Courier.Repo` under the application supervisor rather than mocking the check,
  and asserts that `/healthz` still answers 200 while it is down.
- The routes: which controller and action each path resolves to, that the probes
  sit outside `/api`, and that they do not answer write methods.
- The production SSL exclusion, read back out of `config/prod.exs` the way a
  release would read it.
- `Courier.Health` on its own: `:ok` against a live repo, an error tuple — never
  an exception — against one that is not running.

### Known gaps

- No migrations, so `bin/migrate` (`Courier.Release.migrate/0`, from
  `mix phx.gen.release`) answers `Migrations already up`, and the compose stack
  does not run it. Whoever adds the first migration decides whether compose
  grows a migrate service or the deploy pipeline calls `bin/migrate` directly.
  `Courier.Release` is generator boilerplate and is not covered by a test of its
  own; `mix ecto.migrate`, which the `test` alias runs on every suite, exercises
  the same `Ecto.Migrator` calls underneath it.
- No OpenAPI document, so `exposes.api` is unset in `cafaye.yml`. `/healthz` and
  `/readyz` are probes, not contract surface.
- `consumes` is empty. Nothing subscribes courier to identity or billing events
  yet, and when it does, every consumer has to be idempotent and tested:
  delivery to courier is at-least-once (PLAN.md §3).
- A readiness failure caused by a database that vanished under a running pool
  takes about 4.4s to answer, from DBConnection's queue backpressure. The
  verdict is correct at any probe timeout, but the latency is worth knowing
  before an orchestrator is configured; `Courier.Health` explains why the probe
  cannot shorten it.

[Unreleased]: https://cafaye.com/changelog/courier
[0.1.0]: https://cafaye.com/changelog/courier/v0.1.0
