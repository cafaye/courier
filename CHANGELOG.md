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

Nothing yet.

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
