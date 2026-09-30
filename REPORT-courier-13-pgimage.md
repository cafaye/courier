# REPORT — courier-13-pgimage

**One postgres image across the platform: courier moves to `postgres:17-alpine`.**
Branch `worker/courier-13-pgimage`. Not pushed — that is not this packet's to do.

## The decision, as executed

The platform standardizes on `postgres:17-alpine`. courier named `postgres:17`
in the two places that actually pin an image. Both now carry the same string,
character for character:

| File | What it is | Before | After |
| --- | --- | --- | --- |
| `docker-compose.yml:17` | the `db` service | `postgres:17` | `postgres:17-alpine` |
| `.github/workflows/ci.yml:128` | the gate job's `services: postgres` | `postgres:17` | `postgres:17-alpine` |

`gate.yml` names the image twice in its `external.requirements` database entry —
prose that *asserts* what `docker-compose.yml` carries, so it would have become
false the moment the pin moved. Both updated. `AGENTS.md` and `README.md` carry
the image in five descriptive places; all five updated.

Six files, 58 insertions, 12 deletions. `config/` is **not** in the diff, and
neither is any `lib/` or `test/` file — see *Scope discipline* below.

## The interesting part: the two pins already agreed

The packet frames the risk as "a compose file and a CI workflow pinning
different images". They were not different. Both said `postgres:17`. The drift
was between courier and the *platform*, which is the same defect in a different
hat: a repo can be perfectly self-consistent and still be the only thing in the
fleet on an image nobody else uses.

That distinction changed what I verified. A CI/compose mismatch is provable by
diffing two strings. Platform drift is not provable that way, so I checked it
against the machine instead — and the machine agrees with the platform owner:

```
postgres:17-alpine     291MB
postgres:16.6-alpine   266MB          <- the only postgres images cached
postgres:17            (absent)       <- 477MB, deleted
```

and every database container currently running here — `muse-db`, `b11pg-db-1`,
`darkroom09-pg`, `identity-13-gate-postgres-1`,
`darkroom-worker-darkroom-09-isolation-postgres-1` — is `postgres:17-alpine`.
courier was the last holdout, which is exactly what the next `compose up` would
have paid for: a 477MB pull to run a 291MB-equivalent.

## It boots. Proof, not a comment

- **The image is alpine and musl**, verified from inside the running container,
  not inferred from the tag: `PostgreSQL 17.11 on aarch64-unknown-linux-musl`,
  `Alpine Linux 3.24.2`, `/lib/ld-musl-aarch64.so.1` present.
- **Compose's own healthcheck went green** — `pg_isready -U postgres -d
  courier_dev`, 18 health intervals, no `sleep` in the wait loop (it polls
  Docker's health state, which is the signal being asserted).
- **All six migrations applied to an empty database.** `mix ecto.drop` →
  `mix ecto.create` → `mix ecto.migrate` on the alpine server, and then again
  through `bin/prime`.
- **`bin/prime` was run unmodified**, as AGENTS.md requires ("the CI gate is
  `bin/prime`, the same command, not a CI variant of it"). It does not take a
  port argument and I did not add one.

### Test results, pass and skip reported separately

| Tier | Files | Passed | Floor | Skipped | Excluded | Gated on |
| --- | --- | --- | --- | --- | --- | --- |
| whole suite (`bin/prime`) | all | **535** | 488 | 0 | 0 | nothing |
| no database | 12 | **241** | 194 | 0 | 0 | nothing |
| database | 16 | **294** | 294 | 0 | 0 | nothing |
| SSRF table | 1 | **62** | 62 | 0 | 0 | nothing |

`bin/assert-suite` passed on all four. **No tier is gated on an environment
variable**, so there is no env var to name — the suite contains no `@tag`
conditional skips, and the only env var the DB config reads is
`MIX_TEST_PARTITION`, which selects a database *name* and is set nowhere in
courier's CI. Nothing was skipped, so no skip is hiding a green result.

No sleeps added, no retries raised, no assertion loosened. The DB tier landed
exactly on its floor of 294, which is the check working rather than slack: a
deleted test in that tier would have gone red.

Also verified: `mix.lock` unchanged by the gate (the CI lockfile guard), `mix
compile --warnings-as-errors` clean, `mix format --check-formatted` clean,
`mix deps.unlock --unused --check` clean, and core's `harness/bin/gate-check`
on the edited `gate.yml` reports **0 failures, 3 warnings** — all three the
documented `gate.requirement-unproven` kind, which the file itself explains is
the correct severity for "this machine did not run it".

## Finding: the musl collation difference is real, and courier does not depend on it

The packet asked me to check this rather than assume it. The difference is real
and larger than "can differ":

```
datlocprovider | datcollate  | datctype
c              | en_US.utf8  | en_US.utf8
```

`datlocprovider = c` means the `en_US.utf8` in `datcollate` is a *nominal* name
on musl, not glibc's Unicode-aware ordering. Measured on the running server, same
data, two collations:

```
musl en_US.utf8 (c) : Apple Banana Banana Zebra _underscore apple banana banana_split zebra
en-US-x-icu         : _underscore apple Apple banana Banana Banana banana_split zebra Zebra
```

Case-sensitivity, punctuation placement, and case-paired grouping all differ.
Worth knowing: **ICU is available** in this build (908 ICU collations, including
`en-US-x-icu` and `und-x-icu`), so this is fixable in-place if it ever matters
— it is a collation choice, not a missing capability.

**No test depends on collation order.** That is structural, not luck, and here is
the argument with its evidence:

1. **All eight `order_by` clauses in `lib/` sort on a timestamp or an id** —
   `inserted_at`, `occurred_at`, `next_attempt_at`, `id`. Never a
   customer-supplied string.
2. **Every text-ordering assertion in the suite is an `Enum.sort` in the BEAM**
   (13 call sites, incl. `openapi_paths.ex`). Erlang term order over binaries is
   byte order and never goes through libc, so musl cannot reach it.
3. **The one text column in a unique index is safe for a different reason.**
   `webhook_endpoints.url` is in `webhook_endpoints_account_id_url_index`, and
   uniqueness compares with `=`, which is byte equality — collation-independent.
   `notification_preferences.notification_type` is a `binary_id`-adjacent enum
   column, likewise compared by equality. Both tiers that assert
   `unique_violation` on these passed on alpine.
4. **No `LIKE`, no `ILIKE`, no `~` regex, no `DISTINCT ON`, no `ORDER BY` on
   text** anywhere in `lib/` or `priv/`. Nothing in the migration set declares a
   collation or `citext`.

There is also a **second, quieter musl risk class that courier is clear of**:
locale-dependent formatting. No `:float` and no `:decimal` column exists in any
migration, and no currency path is involved, so `lc_numeric`/`lc_monetary`
semantics cannot leak into a stored value or a signed payload.

**The floor, stated so the next reader knows where it is:** a future
`ORDER BY` or `DISTINCT ON` over a customer-supplied string is where this starts
to bite, and it would bite *silently* — an endpoint list ordered by `url` would
simply return in a different order. If that ever ships, the fix is an explicit
`COLLATE "en-US-x-icu"` on that column or that query, not reverting the image.

## Other references to the deleted image

Per work item 4 — every remaining mention of the old tag, and why it stands:

| Location | Why it was not changed |
| --- | --- |
| `CHANGELOG.md:54`, `CHANGELOG.md:365` | historical entries describing what those releases did. Rewriting a changelog to retroactively claim a different image is how a changelog stops being a record. I added a new `### Changed` entry instead. |
| `REPORT-core-10-courier.md:324`, `:342` | another worker's report. Its claim ("`postgres:17` that `docker-compose.yml` and CI both pin") was true of that commit and is a finding, not a config. Editing it would falsify the record. |
| `lib/courier/health.ex:16` | a moduledoc reporting a **measured** number: readiness failure latency "measured in the release image against `postgres:17`", about 4.4s of `DBConnection` queue backpressure. |

`lib/courier/health.ex` deserves a note rather than a silent skip. The
measurement is on the debian image, and a reader will reasonably ask whether it
still holds on alpine. The number is `DBConnection` pool backpressure — a
BEAM-side queueing behaviour, not a libc behaviour — and the database tier that
covers it passed unchanged. I left the sentence as written rather than editing a
measured claim I had not re-measured; **asserting a re-measurement I did not
perform is exactly the kind of comment-as-evidence this repository is written
against.** The honest form is the one already in the file. If someone wants the
4.4s re-measured on alpine, that is a real follow-up, and the SSRF/health
tiers are where the number would come from.

Two other `postgres:` hits are not image references at all: the three
`%Postgrex.Error{postgres: %{code: ...}}` assertions in
`webhook_deliveries_test.exs` and `webhook_endpoints_test.exs` are Postgrex
struct fields, and the `ecto://postgres:postgres@...` URLs are credentials. Both
are correct as they stand.

## Scope discipline

The packet said another worker is live in courier on a different surface, and to
keep the diff narrow. I read that as binding, so:

- `lib/` and `test/` are untouched.
- `config/` is untouched. This one is worth stating explicitly, because the
  verification *did* need a port override — see below.
- `AGENTS.md`'s rule "when you add or delete a test, raise the floor in
  `ci.yml` in the same commit" is **not triggered**: I added and deleted no
  tests, and all four CI floors are unchanged and all four still pass.

`git worktree list` shows the other worker on `worker/courier-12-contract`. I
did not read, edit, or run anything in that worktree.

### The port override, and why it is not in the diff

`config/test.exs` hard-codes `hostname: "localhost"` with no `port`, and
`DATABASE_URL` is honoured **only** under `if config_env() == :prod` in
`config/runtime.exs` — which carries its own warning that setting Repo config
outside that guard "would silently override test.exs". So the suite has no
supported way to be pointed at a different port, and the shipped default is 5432.

On this machine **host 5432 is already held by a live worker**:
`darkroom-worker-darkroom-09-isolation-postgres-1`, up and healthy. That is not
mine to stop, and running courier's suite against a *different service's*
database would have produced a meaningless green — it would not have tested my
image at all.

So I made the port a **temporary, uncommitted** change and reverted it:

- an untracked compose override outside the repo, remapping only the published
  host port to 15413 — same `image:` string, same `POSTGRES_*` credentials, same
  healthcheck, same volume, same project name;
- a temporary `port:` line in `config/test.exs` and `config/dev.exs`, both
  reverted with `git checkout` afterwards.

`git diff -- config/` is empty and `git status` shows only the six intended
files. The override and its logs are deleted. The other worker's container was
left running and healthy throughout, and `courier-db-1` plus its volume were
torn down with `compose down -v`, so nothing is left holding a port or a volume.

This is a real finding about the repository, not just about my afternoon:
**courier's isolation story is exactly one host port, and it is a port it does
not own.** Every worker on this box that needed a database picked a dedicated
port (`b11pg-db-1` 5545, `muse-db` 5544, `darkroom09-pg` 15543,
`identity-13` 5433); courier is the one that hard-codes 5432 and so cannot run
concurrently with anything else. Worth fixing, but it is a config-design change
with its own migration, not something to smuggle into an image-pin commit.

## One piece of pre-existing drift, reported not fixed

`.github/workflows/ci.yml` labels the no-database tier **"194 tests, 10
files"** and asserts a floor of 194. The same `grep` CI itself derives now
matches **12 files and 241 tests**. CI stays green — 241 clears the 194 floor —
but the comment and the floor are both stale, and the floor has 47 tests of
slack, which is slack in the one mechanism AGENTS.md calls load-bearing
("a tier that CI cannot name is a tier nobody ran"). I did not raise it: it is
unrelated to the image, I added and removed no tests, and the other live worker
is changing the test surface, so a one-line floor bump from me is exactly the
kind of collision the packet told me to avoid. **It needs raising by whoever
next touches those tiers.**

## Constraint compliance

- **No secrets logged.** No token, key or JWT appears in this report, the commit
  message, or any command output above. The two test-only fixtures in `ci.yml`
  and `config/test.exs` were left untouched; where I had to reason about the
  committed `SECRET_KEY_BASE` in `docker-compose.yml` I referred to it by
  location only.
- **No other repository, core, or kit edited.** I *ran* core's
  `harness/bin/gate-check` read-only, from outside the repo.
- **Not pushed.** Committed on `worker/courier-13-pgimage` only.
- **One suite at a time.** Every suite ran serially; the four tiers ran one after
  another, never concurrently.
