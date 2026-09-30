# courier

cafaye **courier** — transactional email, notification preferences, and every
outbound webhook. Phoenix 1.8 API-only service, Elixir 1.20 / OTP 29, Postgres.

This repository is the v0 scaffold. It is a working, deployable service with
probes, a release image, and a local stack — and deliberately no notification
logic yet.

## The gate

```sh
mise install       # Elixir 1.20.4 / OTP 29.1.1, pinned in mise.toml
mise run prime     # hex, deps, database, tests
```

`bin/prime` is `mix local.hex --force && mix deps.get && mix ecto.setup && mix
test`. It needs a Postgres at `localhost:5432` as `postgres`/`postgres` —
`docker compose up -d db` if you do not have one.

Before committing a change, `mix precommit`: warnings-as-errors, unused deps
dropped from the lockfile, formatted, suite green.

## CI

`.github/workflows/ci.yml` calls `cafaye/kit`'s reusable workflow for the shared
half and adds the two jobs kit cannot own:

| Job       | What it is                                                                                                    | Why it is not in kit's workflow                                                                   |
| --------- | ------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| `ci`      | `uses: cafaye/kit/.github/workflows/ci.reusable.yml@master`, `language: elixir`, toolchain pinned from `mise.toml` | — that is kit's job, and it is the only copy                                                                 |
| `gate`    | `bin/prime` against a `postgres:17` service, each test tier named and counted, a `git diff --exit-code` guard on `mix.lock`, and a coverage floor | A caller cannot pass `services:` to a reusable workflow, and the floors are courier's numbers |
| `release` | `mix release` on the pinned toolchain, and the boot contract for `COURIER_SECRET_BOX_KEY`                          | kit builds no image, and only courier knows its release needs a key it must refuse to default        |

Two things a reader should know before trusting a green run:

- **The floors are decrease detectors, not targets.** 488 tests, 194 of them
  without a database, 294 with it, and 62 in the SSRF table. Delete one and CI
  goes red. Add one and CI goes red until the floor is raised, which is the
  intended direction.
- **The `ci` job is expected to be red today**, on `test` (kit runs a bare
  `mix test`, which is `ecto.create` first, in a job with no database) and on
  `coverage` (kit runs `mix coveralls --minimum-coverage N`; the task is in
  `excoveralls`, the flag does not exist, and the command needs an explicit
  `MIX_ENV=test`). Both are in kit's file. The floor is enforced in `gate`, where
  it can be. Delete the `ci` job when kit's Elixir job grows a `services`/`env`
  seam — and not before.

## Probes

| Endpoint  | Meaning   | 200                                    | 503                                            |
| --------- | --------- | -------------------------------------- | ---------------------------------------------- |
| `/healthz` | liveness  | `{"status":"ok"}`                      | never — it does not touch the database         |
| `/readyz`  | readiness | `{"status":"ok"}`                      | `{"status":"error","checks":{"database":"unavailable"}}` |

Liveness answers whenever the VM can dispatch, so a database outage never
restarts the container. Readiness answers 503 while courier cannot do work, so a
deploy holds traffic back instead of serving errors. The reason a readiness
check failed is logged, never returned — probe responses are public.

With a database that has gone away underneath a running pool, `/readyz` takes
about 4.4s to answer 503 (the pool's queue backpressure, not the query timeout).
An orchestrator with a shorter probe timeout will time out and read courier as
not ready, which is the same verdict. `Courier.Health` documents why the probe
cannot shorten it.

Both sit at the root, outside `/api`, and both are exempt from the production
SSL redirect in `config/prod.exs`: an orchestrator that gets a `301` to https
from `/healthz` reads courier as dead. `test/courier_web/router_test.exs` pins
that exclusion.

## Running it

```sh
mix phx.server                      # http://localhost:4000, dev config
docker compose up --build           # postgres:17 + the release image
curl localhost:4000/healthz
docker compose down -v              # stop and discard the volume
```

The compose stack runs the same release the platform will run. It has no
migration step yet, because this repository has no migrations: the release
ships the path — `bin/migrate`, which is `Courier.Release.migrate/0` — and it
answers `Migrations already up`. Whoever adds the first migration decides
whether compose grows a migrate service or the deploy pipeline calls
`bin/migrate` directly.

## Layout

```
lib/courier/health.ex                          readiness check, never raises
lib/courier_web/controllers/health_controller.ex  the two probes
lib/courier_web/router.ex                      probes at the root, /api reserved
test/courier/…                                  readiness check, unit
test/courier_web/…                              probes incl. the DB-down path, routes
.github/workflows/ci.yml                        calls kit, plus gate and release
bin/prime                                       the gate: deps, database, tests
bin/assert-suite                                refuses a run that skipped the hard part
bin/toolchain-pins                              the one toolchain pin, read from mise.toml
Dockerfile                                      two-stage release build, slim final
docker-compose.yml                              postgres:17 + the release image
cafaye.yml                                      the manifest (draft, see below)
```

## The manifest

`cafaye.yml` declares courier to the rest of the platform. It validates against
`cafaye/core`'s `schemas/cafaye.manifest.schema.json`; core owns that format, so
this file is regenerated by `caf init` rather than hand-maintained once core
freezes the version. The events courier will publish, the OpenAPI document for
its API, and the identity/billing events it will consume are all Phase 3
decisions and are listed as unresolved in the file's comments.

## Not here yet

Transactional email, Swoosh and its providers, notification preferences,
outbound webhooks, Oban, and the delivery pipeline. PLAN.md §3 requires every
courier consumer to be idempotent and tested, because delivery is
at-least-once — that is the next packets' job, and this scaffold deliberately
does not guess at it.

Conventions live in [AGENTS.md](AGENTS.md).
