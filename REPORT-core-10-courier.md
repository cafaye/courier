# REPORT — packet core-10, repository `courier`

**Branch** `worker/core-10-courier` · **base** `59247b6` (courier master) ·
**Deliverable** `gate.yml` + `bin/gate-self-test` + this report.

---

## The finding, first

**courier's gate is flaky, and it was flaky before this packet touched
anything.** Across **14 measured whole-suite runs on unmodified master, 13 were
green (`Result: 535 passed`) and 1 was red (`Result: 534/535 passed`, exit 2)** —
roughly a 1-in-14 failure rate, and it will fail a green run of the declaration
about that often too.

The cause is one order-dependent test, and it is a defect in the test rather than
in the environment:

- `test/courier/deliver_test.exs:37` — `defp outbox, do: Repo.all(OutboxEvent)`.
  **No `order_by`.** PostgreSQL does not guarantee row order without one.
- `test/courier/deliver_test.exs:128` — asserts that the result equals
  `~w(welcome password_reset team_invitation)`, i.e. asserts *insertion* order.
- Observed failure: `left: ["password_reset", "team_invitation", "welcome"]`.

Every other list query in `lib/` is consistent about this — `webhook_endpoints.ex`,
`webhook_deliveries.ex` and `dispatch_webhooks_worker.ex` all use
`order_by([x], asc: x.inserted_at, asc: x.id)`. This one query is the outlier.

The one-line fix is `Repo.all(OutboxEvent) |> order_by(asc: :occurred_at, asc: :id)`
(or asserting on a set instead of a list). **I have not applied it.** The brief is
explicit that a gate red for a reason unrelated to my packet is to be reported and
left red, and that the gate's behaviour is not to be modified to make it pass.
This is a separate defect in a separate file and belongs in its own packet. It
is named here precisely so the next packet does not have to re-derive it.

**Second, smaller finding:** courier's CI floors have drifted. The suite runs
**535** tests; `.github/workflows/ci.yml` asserts **488**. The no-database tier
runs **241** against a floor of **194**. Both are **47 tests of slack** — 47
deleted tests would not turn CI red. The database tier (294 against 294) and the
SSRF tier (62 against 62) are exact. The no-database step is also still named
"10 files" when the derived list now holds 12, and `AGENTS.md` repeats the stale
194/294/488/"10 files" figures. **Also not fixed here**, for the same reason —
raising a floor is a one-line diff in someone else's file and this packet's job
was to declare the gate, not to re-tune CI. It is tightening, not weakening, so
it is safe to do; it is just not this packet.

---

## What I added

| File | What it is |
| --- | --- |
| `gate.yml` | the declaration: `command`, `miseTask`, `entrypoint`, `timeoutSeconds`, a `proof`, the `external` block, the `ci` block |
| `bin/gate-self-test` | nine deliberate breakages in throwaway copies, each asserted to be caught by a *named* finding, behind a control that runs the real gate |

Nothing else changed. `git diff --stat` against master is two new files plus this
report. No test, no config, no workflow, no `mix.lock`.

---

## The declaration, and the judgement calls in it

Written against `cafaye/core`'s `schemas/gate.schema.json` and checked by its
`harness/bin/gate-check`. Everything below was measured by running courier's gate
and reading its output, not copied from core or from another repository.

### `command: [mise, run, prime]` — and not `[bin/prime]`

This is the one field where I had a real choice, so it is worth stating the
evidence. **`./bin/prime` does not work on its own.** Run with a PATH that has no
mise shims it dies at line 14:

```
$ env -i PATH=/opt/homebrew/bin:/usr/bin:/bin sh -c './bin/prime'
./bin/prime: line 14: mix: command not found
```

`mise run prime` in that same scrubbed environment runs the whole suite and
prints `Result: 535 passed`. Declaring `[bin/prime]` would be declaring a command
that only works inside a shell somebody has already set up — the same class of
defect as the cafaye-py task whose `run` named a file that does not exist. I also
verified that `mise run` propagates a failing exit code rather than swallowing it
(a task exiting 7 makes `mise run` exit 7), so `[mise, run, prime]` does not
reintroduce a false green through the wrapper.

`miseTask: prime` cross-checks clean: `mise.toml`'s `run = "./bin/prime"` resolves
to `entrypoint: bin/prime`, so the task and the declaration cannot drift into two
different gates.

### `proof` — measured, anchored at both ends, exactly one capture group

```yaml
match: '^Result: ([0-9]+) passed(?: \([^)]*\))?$'
minimum: 530
```

The shape came from eight real runs: exactly one `Result:` line per run, always
`Result: 535 passed`. ExUnit's other shapes are `Result: 0 tests` (nothing ran)
and `Result: P/T passed` (a failure), so the anchors are load-bearing — I
confirmed against the real red log that this pattern matches **nothing** in a
`534/535 passed` run. A fractional line must not satisfy a proof, because a
fractional line is how cafaye-rb's never-executed database tier reported itself.

The trailing `(?: … )?` tolerates the test-type breakdown ExUnit appends when
test types differ, matching the tolerance courier's own `bin/assert-suite`
already encodes. It is **non-capturing on purpose**: `minimum` is read from the
pattern's single capture group, and a second *capturing* group is
`gate.proof-invalid`. I got this wrong on the first draft — I wrote `( … )` — and
the checker caught it with exactly that finding. That is recorded in the file's
comment because it is the kind of mistake the next person will also make.

`minimum: 530` is the measured 535 less a small deliberate margin: courier is
growing and this floor is a ratchet meant to be raised as the suite grows, not a
target it must hit. It is 40 tighter than CI's 488. I did not lower anything to
make a run fit.

### `external: selfContained: false` with three requirements

The gate needs a database, a pinned toolchain, and one network fetch. Each
requirement states what "unmet" looks like, and I verified two of the three
outright:

1. **`database`** — PostgreSQL at `localhost:5432` as `postgres/postgres`.
   **Demonstrated unmet:** in a throwaway copy pointed at a dead port the gate
   exits 1, `Postgrex … tcp connect (localhost:5499): connection refused`, and
   **no `Result:` line appears at all** — `bin/assert-suite` fails on
   *"no 'Result:' line; the run did not reach a summary"*, and
   `gate-check --prove` reports `gate.nonzero` **and** `gate.proof-missing`.
   Worth noting for the identity defect: courier's `mix ecto.setup` is
   `ecto.create` + `ecto.migrate` + seeds, and `mix test` is aliased to
   `ecto.create` + `ecto.migrate`, so this repository *cannot* quietly run its
   suite against an empty schema the way identity could.
2. **`toolchain`** — mise plus the pinned Elixir 1.20.4 / Erlang 29.1.1.
   **Demonstrated unmet:** the `mix: command not found` failure above, quoted
   verbatim in the `unmet` field.
3. **`network`** — hex.pm, once, on a cold checkout only. (Reasoned from
   `bin/prime` lines 14–15 and `.gitignore`; see *could not verify*.)

**What I deliberately did not declare**, with reasons, so nobody goes hunting:

- **No credential.** `COURIER_SECRET_BOX_KEY` looks like the hole this format
  exists to close, and it is not: every `System.get_env` that reads it sits
  inside `if config_env() == :prod` in `config/runtime.exs`, and `config/test.exs`
  fixes a test-only value. **I proved it rather than asserting it** — the gate
  runs green under a scrubbed environment:
  `env -i HOME=… PATH=… TERM=dumb mise run prime` → exit 0, `Result: 535 passed`.
- **No service beyond the database.** Oban is in `:manual` testing mode and the
  NATS publisher is the `Noop` stand-in, both set in `config/test.exs`, so the
  gate dials nothing.
- **No external filesystem path.** `deps/` and `_build/` are inside the tree.

`selfContained: true` would have been a false claim, and the schema's
`maxItems: 0` / `minItems: 1` conditional means the over-claim is a hard failure
— breakage 7 proves it.

### `ci` — declared, and the local/CI split stated rather than hidden

`workflow: .github/workflows/ci.yml`, `invokes: [bin/prime]`.

Worth being explicit about, because it looks like a discrepancy: the **local**
command is `mise run prime` and **CI** runs `./bin/prime` directly, because CI
provisions the toolchain with `erlef/setup-beam` rather than mise. They are not
two gates — both resolve to the same `bin/prime`, which is exactly what
`entrypoint` plus the `miseTask` cross-check enforce. Declaring `ci.invokes` as
`[bin/prime]` is the truthful answer; declaring `[mise, run, prime]` would be
`gate.ci-disagrees`, because CI never runs that spelling.

I also checked for a competing fifth spelling, since that is this packet's whole
premise. There is none: `mise run prime` is what `README.md` and `AGENTS.md` tell
a developer, and `bin/prime` is what CI runs. `mix precommit` looks like a
second gate but is not — `AGENTS.md` is explicit that it is "what a change must
pass" where `bin/prime` is "the gate for a clean checkout". It is a second
*command*, deliberately, not a second spelling of one gate.

---

## The red proofs

`bin/gate-self-test`, in courier's house style (bash, `set -euo pipefail`, a
header that says what it is and is not, pass/fail/skip counted separately). It
is deliberately **not** part of `bin/prime`: a self-test inside every gate
invocation is a second gate that can disagree with the first, which is core's own
rule about `harness/tests/self_test.sh`. Wire it into CI as a step of its own.

**The control runs first** and is not optional — nine red runs against a
repository that was already red prove nothing. It runs the unmodified declaration
twice: statically, and then with `--prove`, which runs courier's real 535-test
gate. It was green both times.

Breakages, each one edit in its own copy, each asserted to go red **and to name
the finding it expects** — an exit code alone cannot tell you which check caught
it, and a check that decays silently is one nobody notices decaying:

| # | Breakage | Caught by |
| --- | --- | --- |
| 1 | `entrypoint` names a file that does not exist | `gate.entrypoint-missing` |
| 2 | `miseTask` resolves to a *different* file | `gate.task-unresolvable` |
| 3 | the `proof` regex matches nothing the gate prints | `gate.proof-missing` |
| 4 | `ci.workflow` names a workflow not in the repo | `gate.ci-missing` |
| 5 | `ci.workflow` exists but never invokes the gate | `gate.ci-disagrees` |
| 6 | **the gate exits 0 having run nothing** | `gate.proof-missing` |
| 7 | `selfContained: true` alongside requirements | `gate.schema` |
| 8 | a requirement satisfied by a missing repo file | `gate.requirement-path-missing` |
| 9 | `command[0]` names a missing repo file | `gate.command-missing` |

Nine breakages, eight distinct findings, **11 passed / 0 failed / 0 skipped**
(11 = 2 control phases + 9 breakages).

**Breakage 6 is the one worth reading twice.** In it the declaration is left
**byte-identical** — I verified this with `diff` — and only `bin/prime`'s
behaviour changes, to a stub that runs no test, exits 0, and prints
`Result: 534/535 passed`: the exact shape cafaye-rb printed for a database tier
that never executed once. The static half reports `OK, 0 failures` — the command
resolves, the entrypoint is executable, the mise task resolves to it, CI invokes
it, the schema is satisfied. Nothing in the declaration is wrong and the
repository is ungated. The proving half is the only thing that catches it, with
**exactly one** failure, `gate.proof-missing`, and **no** `gate.nonzero`.

Breakages 3 and 6 use a stub printing the summary line **captured from a real
run**, not invented, and symlink `deps/`+`_build/` rather than copying 46MB. That
keeps them deterministic and fast, and keeps the real 535-test suite to the one
run where it belongs — the control. A recipe that no longer applies raises rather
than silently passing, which is the lesson kit recorded when two of *its* recipes
went stale.

---

## Results

**The checker, static:**

```
$ core/harness/bin/gate-check .          # from courier's root
WARN gate.requirement-unproven  ×3   (docker, mise, mix — all bare PATH names)
OK …/courier-worker-core-10-courier: 0 failure(s), 3 warning(s)
exit 0
```

The three warnings are the designed ones: a bare `satisfy.command[0]` is a claim
about *this machine*, so the checker reports it and deliberately leaves the exit
code alone. Failing on them would be a checker that is red on a laptop and green
on CI. I am counting them as warnings, not as passes.

**The checker, proving:**

```
$ core/harness/bin/gate-check --prove .    exit 0
OK …: 0 failure(s), 3 warning(s)
   the gate's own log: Result: 535 passed
```

**Against core's real JSON Schema** (not only the checker's re-implementation of
it), with `jsonschema` Draft 2020-12: **0 errors.**

**The repository's own gate, with my change in place** — read under bash with
`set -o pipefail` and `${PIPESTATUS[0]}`, never `$?`:

```
$ bash -c 'set -o pipefail; mise run prime 2>&1 | tee … | tail -12; echo "GATE EXIT=${PIPESTATUS[0]}"'
…
Result: 535 passed
GATE EXIT=0
```

**535 passed, 0 skipped.** Not "535 passed" alone: `bin/assert-suite` — courier's
own stricter tool, which *refuses* a fraction or any skipped/excluded/invalid
count — passes at floor 488 (CI's number) **and** at floor 535 (the measured
number), and `grep -cE 'skipped|excluded|invalid'` over the whole log is **0**.
Nothing is hiding inside that green.

`mix precommit` also exits 0 (`Result: 535 passed`) and reformatted nothing of
mine. `git diff --exit-code -- mix.lock` is clean, per this repository's own rule
that the lockfile must not move when the gate runs.

**Two defects the checker caught in my own draft**, both now fixed and both
recorded in `gate.yml`'s comments: requirement `name` fields over the schema's
200-character cap (`gate.schema`), and a capturing group where a non-capturing
one was required (`gate.proof-invalid`). The declaration that declares the checks
is subject to them.

---

## What I could not verify

This section is the point of the report, not a disclaimer on it.

1. **The cold-checkout path was never run.** Every one of the ~14 gate runs was
   warm — `deps/` and `_build/` were already populated. So the `network`
   requirement ("hex.pm, ONCE, on a cold checkout") is *reasoned* from
   `bin/prime` lines 14–15 and `.gitignore`, and the **unmet side of it is
   unverified**: I never made a fetch fail. What I did try: `mise exec -- mix
   deps.get` from a scrubbed PATH, which reports "All dependencies have been
   fetched" on a warm tree, confirming a warm gate needs no network. I did not
   empty `deps/` to watch it fail, because that costs 46MB and a real re-fetch to
   restore, and I did not block the network on a machine other workers are using.
   **The requirement is plausible and specific, but its failure mode is
   unobserved.**

2. **`timeoutSeconds: 1800` is a judgement, not a measurement.** It comes from a
   ~37s warm run plus the observed cold compile in my very first run. I never
   timed a genuine end-to-end cold checkout, so 1800 is not measured against the
   thing it bounds. It is deliberately generous (core uses 900 for a comparable
   cold-start gate); if courier's true cold time is far below it, it is loose
   rather than wrong.

3. **CI agreement is textual, and courier's CI has never seen this file.** A
   green `gate.ci-disagrees` means only that some `run:` body in
   `.github/workflows/ci.yml` contains `bin/prime`. It does **not** show that the
   `gate` job runs on every push, runs in the right order, or passes. I have no
   GitHub Actions runner here and pushing is forbidden, so `gate.yml` has never
   executed on a runner. `docs/gate.md` names this limit itself; I am restating
   it because it is the one thing a reader could otherwise over-read.

4. **The three `gate.requirement-unproven` warnings cannot be closed by me.** I
   satisfied them by hand — postgres on 5432, mise installed, deps fetched — and
   the gate then passed, and I separately demonstrated the *unmet* side for the
   database. But the checker deliberately refuses to settle a PATH claim, so
   "this requirement is met" is my observation and not the checker's verdict. On
   a machine without `docker`, `mise` or `mix` on PATH those three stay warnings
   forever, by design.

5. **One machine, one PostgreSQL.** Everything was measured on a single macOS
   arm64 host, and the database was Homebrew **PostgreSQL 18.4** — *not* the
   `postgres:17` that `docker-compose.yml` and CI both pin. So the database
   requirement is demonstrated against 18.4 only; I could not verify the gate
   against the postgres version this repository actually ships against. Single
   platform, single Elixir/OTP build, no Linux runner, no CI.

6. **The flake rate is a small sample.** 1 red in 14 whole-suite runs. That is
   consistent with a plan-dependent seq-scan ordering but it is a small sample,
   and I did not run the suite 100 times to characterise it. The *root cause* is
   not a guess — the failing assertion and the unordered query are both quoted
   above — but the *rate* is.

7. **I did not fix either pre-existing defect**, by choice, and so have not
   proven the fixes work. The one-line `order_by` for `deliver_test.exs:37` and
   the four CI floor/step-name corrections are named but unapplied and untested;
   if either is wrong, my report is wrong with it.

8. **Nothing was verified about a second operating system, a cold `git clone`,
   or a real GitHub Actions run** — see 3 and 5. If courier's gate is expected to
   hold on a fresh Linux runner against `postgres:17`, that is untested here and
   is the first thing I would run next.
