# REPORT — courier-15: six tests that shared a table without owning it, and one more

Branch `worker/courier-15-flaky`. Base `14d5bd8`. Not pushed.

The brief: six intermittently-failing tests in two files depend on state left by
an earlier test; give each test ownership of its own data and prove the suite is
deterministic. Also in scope: the `ci.yml` tier label.

Both were true, and the second half of the finding is not in the brief.

---

## 1. The measurement, and one correction to it

**D25 is reproducible, but not as often as the brief says.** The brief and
DEBT.md D25 both record "about one run in nine". On this tree I measured **2
failures in 50 whole-suite runs**, and neither was one of the six:

| runs | what failed |
|---|---|
| 12 database-tier runs | none |
| 50 whole-suite runs | **2× `deliver_test.exs:115`** — a different test, see §4 |
| the six D25 tests | **0 times in 62 suite runs** |

So the six did not reproduce by repetition, which is not the same as saying they
are sound. §2 reproduces them **deterministically**, and the reason repetition
missed them is the interesting part.

## 2. Naming the shared state

**The shared state is the `webhook_endpoints` table, and the dependency is not on
rows — it is on the *absence* of rows.**

Six assertions, in two files, read:

```elixir
assert Repo.aggregate(WebhookEndpoint, :count) == 0
```

An aggregate count over an entire table is a claim about every other test in the
repository as much as about `Courier.WebhookEndpoints`. It is green exactly while
nothing else has ever written a row, and red the instant one is visible. The
three in `webhook_endpoints_test.exs` and the three in
`webhook_endpoints_config_test.exs` each meant *"this refused call wrote
nothing"*, and each asserted *"the table is empty"* instead — a strictly weaker
claim about the code, coupled to a strictly stronger claim about the world.

### The ordering dependency, made deterministic

Rather than loop for a 1-in-9 event, I injected the state D25 names — a row an
earlier test left behind — with a `setup` writing one endpoint for an unrelated
account and a url none of these tests uses. That is not a race; it is a
`setup`, so it is deterministic:

| | before | after |
|---|---|---|
| with the foreign row present | **6 failed** — `left: 1, right: 0` on all six | **58 passed** |

All six, no others. `psql` confirms the injected row was committed to the
transaction and then rolled back with the test, exactly as the Ecto sandbox is
supposed to work.

**Why repetition never caught it.** The sandbox is correct. Each test gets its
own transaction, so the leak has to be a row visible *inside* one test's
transaction — a concurrent test sharing the connection, or a mode flip. The
mechanism that makes this possible is in `data_case.ex:39`:

```elixir
pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Courier.Repo, shared: not tags[:async])
```

For `async: false` modules the pool runs in `{:shared, pid}` mode, and per
Ecto's own documentation on that function, *"Whenever you change the mode to
`:manual` or `:auto`, all existing connections are checked in"* —
which can check a connection back in **while another test is using it**.
`health_controller_test.exs:76` does exactly that (`Sandbox.mode(Repo, :manual)`
after restarting the repo). That is the door; the six assertions were standing
in it. I did not fix the door — it is `health_controller_test.exs`'s documented
reason for being `async: false`, and closing it is a separate change with its
own blast radius. **The fix below makes those six immune to it without needing
it closed**, which is the property worth having.

## 3. The fix: each test owns the data it claims about

Each of the six now mints its own tenancy key and counts only that account's
rows. Three lines of setup, three one-line assertion changes:

```elixir
defp rows_for(account_id) do
  Repo.aggregate(from(e in WebhookEndpoint, where: e.account_id == ^account_id), :count)
end
```

Per the brief: **no sleeps, no ordering guarantees, no `async: false` as the
fix**, and no assertion weakened. Nothing is slower; nothing was made sequential.

### The scoped assertion is *stronger*, and that is checked, not asserted

A whole-table count catches a row written under *any* account; a scoped one
catches a row written under *this test's* account. Is anything lost? Only if a
bug could write a row under a different account than the one it was called with,
which is not a failure mode the codebase admits — but rather than reason about
it, I fault-injected one. I patched `create_validated/2` to insert **before**
`check_url/1` runs — the exact defect these tests exist to catch — and ran the
scoped assertions against it:

```
1) test a name that does not resolve is refused rather than stored
     code:  assert rows_for(account_id) == 0
     left:  1
     right: 0
```

Three of the four leak-detecting tests fired, one per file, with `left: 1`. The
scoped assertions bite exactly as hard as the ones they replaced. The injection
was reverted; `lib/` is untouched in the final diff.

## 4. A seventh test with the same defect, which the brief did not name

Hunting the six surfaced a real, reproducible order-dependence elsewhere:

```
1) test every type courier sends sends and records each one under its own
   notification type (Courier.DeliverTest)
   code:  assert Enum.map(outbox(), & &1.data["notification_type"]) == ~w(...)
   left:  ["password_reset", "welcome", "team_invitation"]
   right: ["welcome", "password_reset", "team_invitation"]
```

**2 of 50 whole-suite runs**, same test, same wrong order. The cause is the same
class of defect and the same anti-pattern: `outbox/0` is `Repo.all(OutboxEvent)`
with **no `order_by`**, so row order is PostgreSQL's choice, and the assertion
compared that order against a fixed sequence. It was testing the server's whim.

Both sides are sorted now. The assertion is unchanged in strength — all three
types present, each exactly once, nothing else — and no longer depends on an
ordering courier never promised. I left the other unordered reads alone after
auditing them: `idempotency_test.exs:145`, `dispatch_webhooks_worker_test.exs:177`
and `webhook_deliveries_test.exs:315` all match a single element or use
`Enum.uniq`, so none depends on row order.

## 5. The `ci.yml` label: measured, and the brief's figure was stale

The brief says the no-database tier is labelled "194 tests, 10 files" against a
grep matching "12 files and 241". **Measured on this tree, that is not the
current label** — `ci.yml` already says `258 tests, 12 files`. courier-13's
`194` was real when recorded and has since been raised. So there was no slack to
reclaim, and I am not going to report a fix I did not make.

What *was* wrong is the same drift one layer over, in four places, where prose
still quoted the superseded numbers:

| file | said | measured |
|---|---|---|
| `ci.yml:19` | `0 of 488 run` | **616** |
| `AGENTS.md:160-162` | `194 in 10 files`, `294 in 16`, `zero of the 488` | **258 in 12**, **358 in 19**, **616** |
| `bin/assert-suite:14,37` | `488 today; 487 is a deleted test` | **616** |
| `README.md:37` | `488 tests, 194 without, 294 with` | **616, 258, 358** |

All four corrected against measured runs, not against each other. The floors in
`ci.yml` (616 / 258 / 358) were already correct and are unchanged — this packet
added and removed no tests, so `Result: 616 passed` still holds exactly.

## 6. The proof: 20 consecutive whole-suite runs

Bounded loop, `mix test` with a fresh seed each run, no `--seed` pinned so the
suite genuinely re-shuffles:

| | |
|---|---|
| **20 / 20 runs** | `Result: 616 passed` |
| failures | **0** |

Same loop on the pre-fix tree failed twice in 50. `--repeat-until-fail` is not
available on ExUnit, so this is a shell loop over `mix test`; it is bounded at 20
and exits non-zero on any run whose summary is not exactly `Result: N passed`.

## 7. The gate

| gate | result |
|---|---|
| `bin/prime` (the declared gate) | **`Result: 616 passed`**, exit 0 |
| `bin/assert-suite` whole suite, floor 616 | 616 passed |
| tier — no database, 12 files | 258 passed, floor 258 |
| tier — database, 19 files | 358 passed, floor 358 |
| tier — SSRF table | 62 passed, floor 62 |
| lockfile guard | `mix.lock` unchanged |
| `bin/gate-self-test` | 11 passed, 0 failed |
| `mix precommit` | exit 0, 616 passed |

**Pass and skip, separately.** All four tiers report `Result: N passed` with no
skipped, excluded or invalid count — `bin/assert-suite` rejects any other shape
outright, so a skip could not have passed silently. **Zero skipped, zero
excluded, zero invalid across every run in this report, including the 20.**

One caveat worth stating: `bin/gate-self-test` needs Python ≥ 3.11 and the
default `python3` on this machine is 3.9.6, so it needs
`PATH="/opt/homebrew/bin:$PATH"`. It is green under that, and red-as-expected on
9 deliberate breakages of the declaration.

## 8. Scope respected

Untouched, as instructed: `cafaye.yml` and the core version pin (courier-14),
`openapi.yaml`, `docker-compose.yml`. Not pushed. No test was deleted, no
assertion weakened, no `async: false` added, no sleep introduced. No token, key
or JWT appears in this report or its logs.

## 9. Not done

- **`health_controller_test.exs`'s mid-suite `Sandbox.mode(:manual)` is left
  alone.** It is the mechanism that makes a connection check-in race possible at
  all (§2). The six no longer depend on it, but other tests sharing the pool
  still can. Worth its own packet; it needs the repo restart reworked, not
  guarded.
- **The wider census is recorded, not fixed.** `Repo.aggregate(T, :count)`
  appears in five files — `idempotency_test.exs` (`claims/0`, `endpoint_count/0`
  helpers), `webhook_deliveries_test.exs:315`, and
  `dispatch_webhooks_worker_test.exs` (8 sites). They assert exact counts and so
  carry the same whole-table shape as the six did. None reproduced in 62 runs,
  and D25 named six, so I fixed six and am flagging the rest rather than
  widening the packet unasked.
- **No new test pins this.** The fault injections were temporary and reverted.
  A regression test for "a test must not count the whole table" would be a lint
  over test source, not a test of courier.

## 10. Commits

One on `worker/courier-15-flaky`, not pushed:

1. Six tests own their data, `deliver_test.exs` stops depending on row order, the
   four stale tier labels are corrected against measured counts, and the rule is
   written into `AGENTS.md` and `CHANGELOG.md`.