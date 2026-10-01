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
| `gate`    | `bin/prime` against a `postgres:17-alpine` service, each test tier named and counted, a `git diff --exit-code` guard on `mix.lock`, and a coverage floor | A caller cannot pass `services:` to a reusable workflow, and the floors are courier's numbers |
| `release` | `mix release` on the pinned toolchain, and the boot contract for `COURIER_SECRET_BOX_KEY`                          | kit builds no image, and only courier knows its release needs a key it must refuse to default        |

Two things a reader should know before trusting a green run:

- **The floors are decrease detectors, not targets.** 1134 tests, 561 of them
  without a database, 573 with it, and 62 in the SSRF table. Delete one and CI
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
docker compose up --build           # postgres:17-alpine + the release image
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
docker-compose.yml                              postgres:17-alpine + the release image
cafaye.yml                                      the manifest (draft, see below)
```

## The manifest

`cafaye.yml` declares courier to the rest of the platform. It validates against
`cafaye/core`'s `schemas/cafaye.manifest.schema.json`; core owns that format, so
this file is regenerated by `caf init` rather than hand-maintained once core
freezes the version. The events courier publishes and the OpenAPI document for
its API both exist now — `exposes.api` is `openapi.yaml`, which describes every
route the router serves except `/healthz` and `/readyz`, and a test holds the
two to each other. The identity/billing events courier will consume are still
unresolved and are listed as such in the manifest's comments, as is the fact
that the two `notification_preferences` operations are served without
authentication.

## The OpenAPI document

`openapi.yaml` is courier's contract, and `PLAN.md` MD6 has the platform
generating client SDKs from these documents — so what is missing from it is a
method a generated client will not have.

`test/courier_web/openapi_document_test.exs` reads the document *and*
`CourierWeb.Router.__routes__/0` and fails in **both** directions: an operation
the router does not serve, and a route the document does not describe. It
compares paths rather than counts, because a count passes on a rename and fails
on an addition. The two probes are the only omission and they are declared in
the document's header and in the test's exclusion list, with the reason.

A route added to `lib/courier_web/router.ex` is not finished until it is in
`openapi.yaml`, and an operation added to `openapi.yaml` is not finished until
the router serves it.

## Sending mail

courier delivers transactional email over SMTP. The provider is a deployment
decision, read from the environment at boot, and courier **refuses to start**
without one:

```sh
COURIER_MAIL_ADAPTER=smtp
COURIER_SMTP_HOST=smtp.your-provider.com
COURIER_SMTP_USERNAME=...          # required unless COURIER_SMTP_AUTH=never
COURIER_SMTP_PASSWORD=...
COURIER_SMTP_PORT=587              # the default
COURIER_SMTP_AUTH=always           # always | never | if_available
COURIER_SMTP_TLS=always            # always | never | if_available
COURIER_SMTP_SSL=false             # true for implicit TLS, usually on 465
```

`COURIER_MAIL_ADAPTER=none` renders mail into memory and opens no socket. It is
refused in production: a courier that reports a message id for mail it never sent
is the worst failure a paid product can have, because it looks like it works.

Credentials are read from the environment in every environment, are never
written to a committed config file, and never appear in a log line — including
the startup line, which names the host and port and deliberately omits the
username as well as the password, because at SMTP a username is usually an API
key.

## Hearing back from the provider

A submission protocol's whole reply is "accepted for delivery", so courier never
learns what happened to a message. The provider reports back by webhook, and
`POST /inbound/resend` is the surface that takes those reports:

```sh
COURIER_INBOUND_RESEND_SECRET=whsec_…    # required in prod; the provider's own secret
```

That secret is the one courier **verifies** with, copied from the provider's
dashboard (Resend: the webhook endpoint's Signing Secret). It is not the secret
courier signs outbound deliveries with — those are generated per endpoint,
sealed under `COURIER_SECRET_BOX_KEY` and stored in the database, and conflating
the two would mean a deployment that leaked a customer's outbound secret could
also forge inbound suppressions.

**Unset is a refusal to boot in production.** Every hard bounce and every
complaint would be *discarded*, silently enough that `email_suppressions` stays
empty, `POST /v1/messages` goes on mailing addresses that have permanently
refused, and a sending domain's reputation dies of a cause no dashboard names.
That is the failure `Courier.Suppressions` was written to prevent, arriving
through the door meant to prevent it.

Three things about the surface that are decisions rather than details, each
argued at length in the module that owns it:

- **It is authenticated by a signature, not a token, and it is outside `/v1`.** A
  provider is not a tenant: Resend signs with Svix and sends no bearer token, so
  a principal would `401` every delivery — and behind no plug at all it would be
  an unauthenticated `POST` that records suppressions, which is a denial of
  service on the whole product delivered by the feature meant to prevent it.
  `Courier.Inbound.Signature` verifies **before** the body is parsed, and the
  endpoint's `Plug.Parsers` is deliberately skipped for this route so the bytes
  that arrive are the bytes that were signed. It is the only operation in
  `openapi.yaml` that declares `webhookSignature` rather than `bearerAuth`.
- **A provider retry is a 200, and there is no `Idempotency-Key`.** Delivery is
  at-least-once, so a second delivery of the same report is normal; the
  deduplication is `email_suppressions`'s unique index on
  `(provider, provider_event_id)`, which the parser derives from the report's own
  **content** rather than from the `webhook-id` header — a stronger key, because
  one delivery can name many recipients and keying on the header would collapse a
  broadcast into one suppression.
- **No response on this operation carries an email address.** Not the counts, not
  a `422`'s `detail`. The suppression table has no `account_id` and is not
  exposed through any route, so an address in a response body is a way to query
  mailboxes courier holds. The address is in the logs, which is where the parser
  puts it.

Accepted reports publish `courier.email.bounced` and `courier.email.complained`,
in the same transaction as the suppression row, with the `user_id` and
`notification_type` **read back from the send that caused them** — a provider
report carries a `Message-ID` and a recipient, never a user, and an event with a
`null` user id is a payload core's own schema rejects on the bus. A report whose
`Message-ID` names no send courier made records its suppression and publishes no
event, with a log line: the row is the load-bearing half.

## Not here yet

`courier.notification.suppressed` has a builder and no caller: a send courier
refused writes no outbox row, because `Courier.Deliver`'s moduledoc promises "no
mail, no event, no record of a send that did not happen", and that promise is
`Courier.Events`' to argue with rather than to override. `courier.email.queued`
has no builder because courier has no queue — the send path is synchronous and
that type exists to make a *backlog* visible.

Conventions live in [AGENTS.md](AGENTS.md).
