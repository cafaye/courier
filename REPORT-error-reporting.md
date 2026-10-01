# error reporting in production — courier's half

Three services (`identity` Go, `courier` Elixir, `billing` Rails) now report
unhandled errors to a self-hosted GlitchTip through Sentry-family SDKs, behind the
redaction boundary the OTel collector already enforces. **This report covers
`courier` only.** The other two services have had no work started, and the
"failing-if-broken secret test per service" and "each service's gate is green"
requirements are therefore satisfied for one service of three. That is stated first
because it is the largest thing this packet has not done.

The design decisions, the licensing verification, and the OTel citations are in
[`docs/error-reporting.md`](docs/error-reporting.md). This file is about what was
built, what it cost, and — mostly — the five defects that a green suite did not
catch.

## Licensing: verified, from the artifact

The brief asked for this to be checked and to be **said loudly if it is not
clean**. It is clean, and it was verified from the shipped image rather than from
a repository page, because the image is the thing that would run:

| component | licence | how it was checked |
|---|---|---|
| **GlitchTip server** | **MIT** | `/code/LICENSE` inside the pinned image is the MIT text, `Copyright (c) 2019 GlitchTip` |
| GlitchTip's vendored Sentry code | **BSD-3-Clause** | `/code/NOTICE.md` attributes it to Sentry; `/code/sentry/LICENSE` is BSD-3-Clause, `Copyright (c) 2019 Sentry` |
| `sentry` Elixir SDK | **MIT** | `deps/sentry/mix.exs` |
| `sentry-go`, `sentry-ruby` | **MIT** | upstream, unchanged in those repos |

Two things worth saying plainly:

- **No FSL text appears anywhere in GlitchTip's tree.** It forked from Sentry
  *before* the relicensing, which is the whole reason the comparison came out
  differently. For contrast, the current `getsentry/sentry` server is
  FSL-1.1-Apache-2.0, whose "Competing Use" clause disqualifies the commercial
  hosted offering — verified verbatim, and the reason the brief's
  GlitchTip-over-Sentry decision is not merely a preference.
- **MIT grants no trademark rights.** The "GlitchTip" name is not licensed here.
  The image is used unmodified and unbranded; nothing in this repository presents
  itself as GlitchTip.

## Architecture: a relay, because the collector cannot reach the error path

GlitchTip has **no OTLP receiver for errors**, so the existing collector
chokepoint cannot see an SDK's error traffic at all — an OTel collector routes
spans and logs, and there is no error signal on that path to redact. A relay is
the *second* possible chokepoint, and it is the one that works.

So `courier` hosts it, as a second Phoenix endpoint on its own port
(`CourierWeb.ErrorEndpoint`), deliberately **not** on `CourierWeb.Router`. That
was the deciding consideration: a route on the public router would have needed a
third entry in `CourierWeb.OpenAPIDocumentTest`'s exclusion list, and the brief is
explicit that an existing check does not get relaxed to accommodate new code. The
bidirectional router↔document test is untouched.

The direct-SDK alternative was rejected on three counts: no redaction, three
different DSNs to configure and three different secrets to leak, and no single
place where volume is controlled. With the relay, all three services point at one
DSN shape, and `Courier.ErrorRelay.Policy` is the only place that decides what an
envelope may contain.

**Nothing in the error path touches `Courier.Repo`, and no migration was added.**
The error store is GlitchTip's own database on the same `postgres:17-alpine`
server, under a role that cannot read `courier_dev` — verified against a live
server, not asserted. The suite asserts the migration list is unchanged, because
"we added no table" is otherwise a claim that is only true by inspection.

## The five defects a green suite did not catch

This is the substance of the packet. `mix test` was **717 passing** across all of
them. Every one was found within about an hour of `docker compose -f
docker-compose.yml -f docker-compose.errors.yml up --build`, by posting envelopes
at a running release image and **counting rows in GlitchTip's database**.

| # | defect | why 717 tests could not see it | the test that now holds it |
|---|---|---|---|
| 1 | the relay served `POST /internal/v1/errors` | every test posted to the path by hand, so the tests and the route agreed by construction | derives the URL with `Sentry.DSN.parse/1` and asserts the router serves it |
| 2 | it read `x-cafaye-error-token` | **no Sentry SDK sends that header**; the test fixture had invented it | an SDK-shaped request with `X-Sentry-Auth: … sentry_key=…` |
| 3 | a miscounted payload `length` → `500` | the framing was always built by `build_envelope/2`, which agrees with the parser by construction | a hand-written envelope, correct and miscounted |
| 4 | `parse_dsn/1` dropped the DSN's **port** | the natural test fixture DSN has no port in it | a DSN with `:8000`, asserted on the URL dialled |
| 5 | the envelope header's `event_id` was a **fixed all-zero string** | see below | two envelopes from one event must have different header ids |

**#5 is the one that matters, and it is worth reading twice.** The relay stamped
`"00000000000000000000000000000000"` into every envelope header, on the correct
reading that the Sentry envelope spec asks for all-zero hex when no id is known.
GlitchTip falls back to the **header's** id when an event payload carries none of
its own (`apps/event_ingest/views.py`: `if item.event_id is None: item.event_id =
envelope_header_event_id or uuid.uuid4()`), then dedupes on
`cache.aadd("uuid" + item.event_id.hex)`. So every event courier forwarded without
its own id shared one dedupe key and **only the first was ever stored**.

Nothing in courier could see it. The relay counted each one as `forwarded`, the
store answered `200`, the sender saw no error, and the store held one row where
there should have been hundreds. I posted ten identical errors and got **six**
issues' worth of evidence for "stored" only by reading the database. The general
lesson is the one in `AGENTS.md`: **the only observation that distinguishes
"accepted" from "stored" is counting rows in the store**, and this packet has no
test that can do that for the other two services' relays.

Two more defects were **release-only** and are in the same family:

- `Courier.Application` listed `{Sentry, opts}` as a supervisor child. `Sentry` is
  an OTP application of its own with no `child_spec/1`, so the supervisor refused
  it and courier **crashed at boot**. In test the SDK has no DSN, so the clause
  is never reached — the whole suite was green over a tree that cannot boot a
  release.
- `config/runtime.exs` enabled `server:` on the customer endpoint and not on the
  error endpoint, so the relay's listener never bound. The only symptom was one
  log line reading like a notice, and port 4003 is not published, so there was no
  refused connection to notice either.

Both are asserted now — the first by reading the running supervision tree, the
second by evaluating `runtime.exs` with `target: :prod` and `PHX_SERVER` set. The
first assertion does **not** catch the original bug (it crashes before the first
test runs, so the assertion never executes); it names the invariant and fails
readably if the tree is rebuilt differently. That is stated in the test rather than
implied.

## What the numbers are

`bin/prime` → **`Result: 724 passed`**. Floors raised in the same commit:
`gate.yml` `minimum: 703 → 724`, CI whole-suite `709 → 724`, database tier
`406 → 421`. The **no-database tier stayed at 303**, which is the claim this
packet's redaction boundary makes: the relay holds no `Repo`, so the whole
boundary is testable with no database. The SSRF table is unchanged at 62.

## Judgement calls, and why

- **Relay over direct SDK.** The collector has no error path, above.
- **Two barriers, not one.** `before_send` on the SDK plus `Policy` on the way
  in. Core's `defenceInDepth`. It also makes a misconfigured DSN survivable: the
  SDK filter runs before the envelope exists, so pointing courier's own DSN at a
  third party still cannot ship an exception message.
- **The exception message is not stored.** Stated as the price of admission, not
  absorbed quietly: an error store is retained and widely readable, and the
  collector already deletes `exception.message` and `exception.stacktrace` for the
  same reason. `Policy` keeps the class, file, line and function, and the
  `error.type` vocabulary.
- **Which signals.** Unhandled exceptions only. Handled and retried errors are
  **not** recorded — core's rule, and the reason `capture_any/3` exists separately
  from `capture/3` so the choice is visible at the call site rather than implied
  by a config flag.
- **Throttled on rate, per fingerprint.** A token bucket with an injected clock in
  the relay and a client-side limiter in each SDK: two controls of different
  kinds, because Sentry does not sample errors by design and a sampling rate would
  silently discard the one crash that mattered. Measured against a live store: ten
  identical errors produced **one** issue and the relay counted four throttled.
- **Deploy-linked auto-resolution: on, via the release.** `COURIER_RELEASE` and
  `DEPLOYMENT_ENVIRONMENT` are read and stamped on the event, and GlitchTip
  resolves an issue when a release containing the fix ships. Without it an issue
  stays open for ever, which is the failure mode the store has no other way to
  detect. Verified: the store created a `releases_release` row from the probe.
- **Ingest auth is a shared secret, required.** Constant-time compare, refusing
  default, and read from `X-Sentry-Auth` — see defect #2. A shared secret is right
  because an SDK holds a DSN, not a JWT, and there is no identity service in that
  path to mint one.

## The one new dependency

`{:sentry, "~> 13.5"}`, MIT, declared in `mix.exs` with the licensing argument in
the comment rather than in a packet file. It is the only dependency added; nothing
else was. `sentry-go` and `sentry-ruby` will be the one each for `identity` and
`billing`, and each of those needs the same declaration in its own `go.mod` /
`Gemfile`.

## What is not here

- **No UI dashboard, no PagerDuty/Slack integration, no status page**, per the
  brief. GlitchTip's own UI exists because it is the store's, not a dashboard this
  packet built.
- **No `identity`, no `billing`.** The other two services need their own relay
  client, `error.type` vocabulary, client-side limiter and failing-if-broken
  secret test, and their own gate run. Nothing in this packet is reusable as-is
  across languages; what transfers is the *shape* and the two-barrier argument.
- **No alerting configuration.** The relay throttles, and the store groups, but
  this packet does not create GlitchTip alert rules. The brief asked for throttled
  rate-based alerting; what is built is the throttle those rules would sit on, and
  the alert rules themselves are a store-side decision nobody has made yet.
- **No per-service GlitchTip projects.** All three services report into one, named
  by `COURIER_ERROR_SINK_DSN`. The project id in the ingest path is the SDK's
  framing and is ignored; separation is by `error.type` and the `service.name`
  tag. Worth revisiting if a store per service is ever wanted — it would mean the
  relay honouring a caller-supplied project id, which is a larger change.