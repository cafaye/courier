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
lib/courier/mailers.ex                compose the three transactional emails
lib/courier/mailers/templates/        the bodies, compiled at build time
lib/courier/deliver.ex                the send: preference, provider, outbox row
lib/courier/events.ex                 the CloudEvents envelope and the catalog
lib/courier/outbox_event.ex           one emission, and the envelope it publishes
lib/courier/notification_preference.ex         the row behind a user's answer
lib/courier/notification_preferences.ex       read and write those answers
lib/courier/nats_publisher.ex         the behaviour the relay publishes through
lib/courier/nats_publisher/noop.ex    the stand-in that hands envelopes back
lib/courier/principal.ex              the caller, the resolver behaviour, and the
                                      default resolver that authenticates nobody
lib/courier/secret_box.ex             sealing: a signing secret at rest, AES-GCM
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
lib/courier_web/plugs/problem_content_type.ex  a non-2xx is problem+json
lib/courier_web/controllers/health_controller.ex   GET /healthz, GET /readyz
lib/courier_web/controllers/notification_preferences_controller.ex  GET/PUT /v1
lib/courier_web/controllers/webhook_endpoints_controller.ex  the six /v1 actions
lib/courier_web/controllers/error_json.ex        the errors Phoenix renders
lib/courier_web/router.ex             probes at the root, /v1 for the API
test/courier/health_test.exs          the readiness check, on its own
test/courier/mailers_test.exs         what the platform hands in, per message
test/courier/mailers_config_test.exs  the sender and the subject are config
test/courier/deliver_test.exs         the three promises, in one transaction
test/courier/deliver_adapter_test.exs what happens when the provider says no
test/courier/notification_preferences_test.exs  defaults, writes, rejections
test/courier/events_test.exs          the envelope against core's schema
test/courier/nats_publisher_test.exs  the behaviour and the stand-in
test/courier/secret_box_test.exs      a secret is not readable from its column
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
test/support/recording_sender.ex      a sender that records instead of sending
test/support/header_resolver.ex       a principal that reads a header
test/support/test_dns.ex              a resolver that answers from a table
bin/prime                             the gate: deps, database, tests
bin/assert-suite                      refuses a run that skipped or excluded tests
bin/toolchain-pins                    reads mise.toml, checks CI has not drifted
.github/workflows/ci.yml              calls kit's workflow, plus gate and release
Dockerfile                            two-stage release build, slim final stage
docker-compose.yml                    postgres:17 plus the release image
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

**`mix precommit` before you commit.** It compiles with warnings-as-errors,
drops unused deps from the lockfile, formats, and runs the suite. `bin/prime`
is the gate for a clean checkout; `mix precommit` is what a change must pass.

**The CI gate is `bin/prime`, the same command, not a CI variant of it.** If the
two can disagree, one of them is lying. The workflow adds a database, the tier
counts and the lockfile guard *around* that command; it does not reimplement it.

**A tier that CI cannot name is a tier nobody ran.** The suite partitions
exactly, by the case template: 194 tests in the 10 files that never touch
`Courier.Repo`, 294 in the 16 that do, and `mix test` is aliased to
`ecto.create` first, so a runner with no database executes *zero* of the 488 —
SSRF table included. Both counts are asserted in CI by `bin/assert-suite`, and
the SSRF table gets its own 62-test run so the log carries a line that can only
exist if that harness ran. **When you add or delete a test, raise the floor in
`.github/workflows/ci.yml` in the same commit.** Deleting a test to make CI green
is caught by the floor; adding one is caught because CI goes red until you raise
it. Both are one-line diffs, and only one of them changes what courier verifies.

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

## Toolchain

mise, from `mise.toml`: `mise install`, then `mise run prime` for the gate.
For container work: `docker compose up --build` starts postgres:17 and the
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