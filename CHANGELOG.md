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
