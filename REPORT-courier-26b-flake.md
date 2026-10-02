# courier-26b: a test that fails one time in three is not a test

`test/courier/error_relay_test.exs` failed intermittently. It was pre-existing:
three workers hit it on `master` and each correctly refused to blame their own
change, which is the symptom that matters. A 1-in-3 test trains everyone who
sees it go red to assume somebody else broke it, and each of those workers wrote
a paragraph into a merge message explaining that the failure was not theirs.
That is maintenance debt accumulating in prose instead of in a fix.

**The cause was one helper, and it is a defect this repository had already
half-diagnosed and half-fixed.** The fix is in this commit; the numbers below
are the measurement of it.

---

## 1. What was actually failing

One assertion, in two tests:

```elixir
assert eventually(relay, fn -> ErrorRelay.stats(relay).sink_failures > 0 end)
```

`eventually/3` was the only bounded poll in the file:

```elixir
defp eventually(relay, fun, attempts \\ 200)

defp eventually(relay, fun, attempts) do
  :sys.get_state(relay)
  :sys.get_state(ErrorRelay.sender_name(relay))

  if fun.() do
    true
  else
    eventually(relay, fun, attempts - 1)
  end
end
```

Observed failures, all on this assertion, all `Expected truthy, got false` at
`test/courier/error_relay_test.exs:270`:

```
1) test it cannot crash-loop a relay whose sink raises is still alive and still counting
2) test it cannot crash-loop a sink that returns an error tuple is counted, not raised
```

---

## 2. Why `eventually/3` cannot be right

**Two hundred is a count, not a duration.** It is a proxy for a duration, and the
proxy is only as good as the machine it ran on. Measured on this tree, this
machine, by timing the exact loop the helper performs:

| quantity | measured |
| --- | --- |
| 200 iterations of `sync/1` (two `:sys.get_state/1` round trips each) | **0.6 ms – 2.2 ms** of wall clock, varying run to run |
| one `sync/1` | ~3–11 µs |
| the sink's notification → the counter being visible in ETS | **0.4 ms – 36 ms**, varying run to run |

Whichever was bigger won. That is a coin flip, and the coin came up tails about
one time in three.

The 0.4 ms – 36 ms is **not** work the code does slowly. Instrumenting the drain
showed the *computation* is trivial — the exception plus two `Logger.error/1`
calls is 10–60 µs, and a `raise` inside a `Task.async` costs 3–8 µs. The rest is
**BEAM process wake-up latency**, and the machine this ran on was at
**load average 30–60 across 8 cores** (another session works these repositories
concurrently). A bounded poll cannot be made correct against an unbounded
scheduling delay, which is why raising the attempt count would have been the
wrong fix and not merely a lazy one.

### `test/support/failing_sink.ex` had already recorded half the answer

Its `notify/1` comment claimed the flake was fixed:

> *polling is what made this file flaky, because two hundred `:sys.get_state/1`
> calls complete in well under a millisecond and a drain task scheduled behind
> them may not have run at all. The test then failed roughly one run in three.*

The first two sentences were right. The claim that the flake was fixed was not:
`assert_receive {:sink_attempted, :raise}` was added, but **the counter read was
still a spin**. Half a fix, described as a whole one — which is why it survived
three workers. That comment is corrected in this commit and now says what the
message it sends can and cannot prove.

---

## 3. The fix

The rule that decides everything: **the wait is chosen by who writes the fact
being asserted.**

| counter | written by | the wait |
| --- | --- | --- |
| `received`, `forwarded`, `throttled`, `malformed`, `unclassified`, `undeclared` | the **relay**, in the `handle_cast` that decides | `:sys.get_state(relay)` — a barrier, because the cast is ahead of the system message |
| `queue_full` | the **sender**, in `handle_cast({:enqueue, …})` | `sync/1`, relay first then sender — the ordering *is* the argument |
| `sink_failures` | the **drain `Task`**, after the sink returns | `Process.monitor/1` + `assert_receive` on the `:DOWN` |

So `eventually/3` is **deleted**, not retuned. All five call sites are replaced:

* **`queue_full` and `malformed`/`unclassified`** → one `sync(relay)`. These were
  racy too, for the same reason, and are now single round trips.
* **`sink_failures`** → `await_drain/1`: `DynamicSupervisor.which_children/1` on
  the sender's `Task.Supervisor`, `Process.monitor/1` each pid, `assert_receive`
  the `:DOWN`. A drain writes every counter in its batch **before** it exits, so
  observing the exit observes the write. The pid is obtained after one
  `:sys.get_state/1` on the sender, which is a barrier for *the drain existing* —
  the sender starts it synchronously inside the `handle_cast` that accepted the
  envelope. An empty child list means it was already reaped, and a drain is
  reaped only after it has exited, so that is "finished" too. All three shapes
  (alive / already exited / already reaped) are sound.

`ErrorRelay.tasks_name/1` is a new `@doc false` accessor beside the existing
`sender_name/1`. It is in production rather than spelled out in the test on
purpose: a test that re-derives the string keeps *passing* if the sender ever
moves — the name stops matching, `which_children/1` answers `[]`, and a wait that
silently waits for nothing looks exactly like one that found nothing to do.

### The assertions got stronger

Every replacement is an **exact** figure where it was a `> 0`, and two
assertions that used to be about silence are now about the code:

| before | after |
| --- | --- |
| `eventually(... sink_failures > 0)` | `1 == sink_failures`, then `2 ==` after a second envelope |
| `eventually(... sink_failures > 1)` | folded into the same exact sequence |
| `eventually(... queue_full > 0)` | `1 == queue_full` |
| `eventually(... malformed + unclassified > 0)` | `%{malformed: 1, unclassified: 1, forwarded: 0}` |
| `assert 0 == length(forwarded())` (a 200 ms quiet window) | the relay's own `forwarded` counter after `sync/1` |
| `forwarded()` = "drain the mailbox until quiet for 200 ms" | `forwarded(n)` = wait for `n` envelopes **by message**, each an `assert_receive` |

`forwarded/1` deliberately has **no `0` clause**. `forwarded(0)` would return
`[]` and an assertion written on it would pass without the sink having been
consulted — a check over nothing. The deterministic form of "nothing was
forwarded" is the relay's own `forwarded` counter, and the counter and the
messages bound each other: the relay admitted exactly three, so the sink cannot
have been handed a fourth, so three envelopes arriving is *exactly* three.

No sleep was added. No retry count was raised. No assertion was loosened.

---

## 4. Numbers

Interleaved, same session, same machine, alternating between the file from
`master` and the file from this branch, so load drift hits both equally:

```
ofofofofOfofofofofofofofofofofofOfofofofofofofofofofofofofofofofofofof
ORIGINAL failures: 2 of 25
FIXED    failures: 0 of 25
```

Across every batch run in this session:

| file | runs | failures | rate |
| --- | --- | --- | --- |
| original (`master`) | **78** | **13** | ~1 in 6 |
| fixed (this branch) | **65** | **0** | 0 |

The packet's own measurement was 3 in 8 on a quieter machine. The rate tracks
machine load, which is what a race against scheduler latency should do.

Whole suite, three consecutive full runs, same machine:

```
Result: 1282 passed
Result: 1282 passed
Result: 1282 passed
```

Floors are unchanged and all three still hold exactly — no test was added or
removed, so no floor moves:

```
assert-suite: no database — 619 passed (floor 619)
assert-suite: database     — 663 passed (floor 663)
assert-suite: whole suite  — 1282 passed (floor 1282)
```

`mix precommit` exits 0 (warnings-as-errors, `deps.unlock --unused`, format,
suite). `mix.lock` did not move.

---

## 5. Proof the fix is load-bearing

Three controls, because a green suite does not distinguish "fixed" from "got
lucky".

**Mutation 1 — delete the counter.** Removing `ErrorRelay.count_stat(state.relay,
:sink_failures, 1)` from `Sender.forward/2`'s `other ->` clause:

```
Result: 14/15 passed   (3 runs in 3)
  code:  assert 1 == ErrorRelay.stats(relay).sink_failures
  left:  1
  right: 0
```

The assertion still bites, and it fails **deterministically** — which is itself
the evidence that `await_drain/1` is a barrier. If the wait were still a race,
this mutation would have been flaky rather than solid.

**Mutation 2 — remove the barrier.** Replacing `await_drain/1`'s body with
`sync/1` alone (i.e. `:sys.get_state` on the relay then the sender, no
`which_children`, no monitor, no `:DOWN`) passed **0 failures in 39 file runs**.
That is the result that needed explaining rather than accepting, so:

**Probe — is `sync/1` a barrier?** 60 rounds per run, in one test, each round
ingesting one envelope, waiting for the sink's notification, running a barrier,
and judging that round on its **own delta** of the cumulative counter:

| barrier | rounds where it returned before the drain had counted |
| --- | --- |
| `sync/1` (relay then sender) | **8/60, 11/60, 15/60** — 13%–25% |
| `which_children` + `monitor` + `:DOWN` | **0/60, 0/60, 0/60** — 0 of 180 |

That is the whole argument for the monitor in one table. `sync/1` is a coin flip
that happens to win often enough to pass 39 file runs; the `:DOWN` is a barrier.

(A first version of the probe judged each round against the *running total*
rather than its delta, and reported 16/60 and 37/60. After the first miss the
total stays one behind forever, so every later round is reported as a miss too.
Noted because it is the same failure mode as a test that asserts on silence: the
number looks like the thing being measured and is measuring the harness.)

---

## 6. Sibling risks in this suite — named, not fixed

The packet asks which other concurrency-shaped tests carry the same risk. Grepped
for `Process.sleep`, `:timer.tc`, bare `receive`/`after` timeouts, named ETS
tables and shared named processes across `test/`.

**Carrying the same risk, in descending order:**

1. **`test/courier/telemetry_canary_test.exs` — `request_spans/0` reads a table
   the whole VM shares.** The exporter is `:public` named ETS (`:courier_test_spans`)
   and `request_spans/0` filters it only by span name, so a span from a
   concurrently finishing `async: true` file is read as this file's. The
   "a 404 produced a span with a route" assertion is a loop over that whole
   table. **This one already failed and is already documented** — AGENTS.md and
   `REPORT-courier-24-unsubscribe.md` record it at 1 failure in 8 whole-suite
   `bin/prime` runs, 0 in 12 isolated runs of the file. It is the closest thing
   in this repository to the bug just fixed, and it is **not** fixed here. It is
   also the harder one: the two available fixes both weaken a presence assertion,
   which is the failure mode the file's own moduledoc is built against.

2. **`test/courier_web/error_reporting_test.exs` — the SDK's own flush.** It
   drives the real Sentry SDK and waits with `assert_receive {:sentry_envelope,
   …}, 2_000`, which is event-driven and therefore the right shape. But the SDK
   posts from a background task unless `send_result: :sync` is set, and the file
   sets it by hand after `Application.put_all_env`. Anything that changes the
   SDK's config or its flush path turns those into waits on a background task
   courier does not own. Low risk, one indirection from being the same bug.

3. **`test/courier/smtp_delivery_test.exs` — real sockets.** A round trip through
   a real `:gen_smtp_server` on a real loopback port. Not a race, but a
   `gen_smtp` timeout is a wall-clock deadline and the file's own moduledoc
   already records that `on_exit` runs after the test even when it fails. If it
   ever flakes, it will be a timeout rather than a counter.

**Checked and clean:**

* **`Process.sleep/1` appears exactly once in the whole suite**, at
  `telemetry_canary_test.exs:377`, and it is `Process.sleep(0)` — a yield, not a
  timed wait, and deliberately paired with `Courier.SpanCollector.flush()`.
* **No `:timer.tc` anywhere in `test/`.**
* **No bare `receive`/`after` timeout** outside `assert_receive`.
* **No named ETS tables are created in tests**; `TestSpanExporter` is the one
  exception and is item 1 above.
* **`Courier.TestSupport.Clock` is a named `Agent`, and `error_relay_test.exs` is
  its only user.** That file is `async: false` and says why. No other file
  coordinates through a suite-shared named process.
* **The webhook worker tests** (`process_outbox_worker_test.exs`,
  `dispatch_webhooks_worker_test.exs`, `deliver_webhook_worker_test.exs`) all
  wait with `assert_received {:nats_published, …}` against a Noop publisher that
  hands the envelope back to the calling process — event-driven, and the message
  is sent by the code under test rather than by a timer.
* **`webhook_deliveries_test.exs`** asserts the backoff on the *recorded*
  `next_attempt_at`, per the "nothing sleeps" rule above. No timing dependency.
* **The unsubscribes endpoint** (`courier-24`, concurrent in this repository) was
  left alone. It is in the database tier and its 404 depends on a row; it does
  not touch the relay or the sender.

---

## 7. Why a retry count would have been the wrong answer

The packet's boundary names raised retry counts as one of the three things that
turn a flake into a permanent property of the suite, and invites an argument if
a retry is genuinely right. Here it is not, and the measurements above are why:

* The quantity being waited for is **scheduler latency**, whose distribution has
  no upper bound. Every value of *n* is wrong somewhere.
* Raising *n* would have made the file pass, and it would still have been
  asserting a duration rather than a fact — so the next person to change the
  sender's shape would not have known there was a race under there.
* The fix **removes** a helper rather than retuning it, so the thing that was
  wrong is gone rather than quieter.

What was raised is a *deadline*, not a budget: `assert_receive`'s `@wait` of
2 s, against a slowest observed drain of 36 ms. No assertion's truth depends on
it being generous, because each wait is for a message — or a `:DOWN` — from a
named process. It is a failure deadline and nothing else, and `AGENTS.md` now
says so next to the rule it generalises.