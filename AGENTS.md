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
lib/courier_web/controllers/health_controller.ex   GET /healthz, GET /readyz
lib/courier_web/router.ex             probes at the root, /api reserved
test/courier/health_test.exs          the readiness check, on its own
test/courier_web/controllers/health_controller_test.exs   probes, including DB-down
test/courier_web/router_test.exs      which controller, which scope, which methods
bin/prime                             the gate: deps, database, tests
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

**`async: false` is a comment, not a shrug.** If your test stops or restarts a
process the suite shares — `Courier.Repo`, the endpoint — it must be
`async: false` and say why in a comment above `use`.

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