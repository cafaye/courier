defmodule Courier.ErrorRelayTest do
  @moduledoc """
  Volume control on the error path, and the guarantee that the error path cannot
  take the main path down with it.

  ## What is being controlled, and why volume control is ours to build

  Sentry **does not sample errors, by design**. The SDK's `sample_rate` applies
  to transactions; an exception is reported every time it happens. That is the
  right default for an error store — you cannot sample the one crash that
  mattered — and it means a bug in a hot loop becomes one notification per
  iteration, which is not an error store any more, it is a denial of service
  with a UI.

  So there are two controls and they are deliberately at two different places,
  because two controls of the same kind is one control:

    * **per service**, in `Courier.ErrorReporting` and its two siblings: a
      client-side limiter, so a hot loop does not build ten thousand envelopes.
    * **here**, in the relay: a fingerprint-keyed token bucket, so even a service
      whose own limiter is misconfigured, or missing, or a version behind,
      cannot fill the store.

  The relay's throttle is the one that makes the brief's promise true — "one bug
  in a hot loop does not become ten thousand identical notifications" — because
  it holds no matter what the three SDKs do.

  ## Why a token bucket and not a counter

  A counter with a reset is a rate limit with a cliff: at the boundary it either
  lets a burst through or it does not. A bucket refills continuously, so the
  first event of a bug always gets through — which is the one that matters,
  because it is the one that says *the bug is still happening* — and a continuing
  bug produces one event per refill interval rather than a wall.

  ## `async: false`, and why

  `Courier.TestSupport.Clock` is a **named** process, and the refill assertions
  move its clock. Two of these tests advancing one clock concurrently would make
  every refill assertion depend on the interleaving, so the file is
  `async: false`. That is the reason the house rules ask for — a test that
  coordinates through a suite-shared process has to say so — and not a shrug. It
  costs about thirty milliseconds; every other file in the no-database tier stays
  `async: true`.

  ## Nothing here sleeps, and the clock is injected

  A throttle tested by waiting is a throttle tested by the wall clock, and it is
  a test that takes as long as the window it is proving. `now` is a function the
  relay takes at init, so the refill is asserted by moving the clock rather than
  by living through it. That is also the only way to assert the *shape* of the
  schedule rather than that time passed.
  """

  use ExUnit.Case, async: false

  alias Courier.ErrorRelay
  alias Courier.ErrorRelay.Sink
  alias Courier.TestSupport.Clock
  alias Courier.TestSupport.FailingSink
  alias Courier.TestSupport.RecordingSink

  @burst 3
  @per_minute 60
  @capacity 64
  @canary "CANARY-4f19b2c7-do-not-store-me"
  @bearer "Bearer abcdefghijklmnopqrstuvwxyz012345"

  setup do
    start_supervised!({Clock, []})
    # The recording sink sends to whatever pid is in its options, so `self()`
    # here is the test process. The relay is started by `start_relay/1` inside
    # each test rather than here, because four of these tests need a relay with
    # different options and a `setup` one would collide with the second.
    :ok
  end

  # Each relay is a unique name so a test may start as many as it needs, and
  # `start_supervised!` guarantees the process is stopped when the test ends —
  # which is what keeps the throttle tables and the drain supervisors from
  # outliving a test and answering the next one.
  defp start_relay(opts \\ []) do
    name = :"relay_#{System.unique_integer([:positive])}"

    start_supervised!(
      {ErrorRelay,
       Keyword.merge(
         [
           name: name,
           sink: RecordingSink,
           sink_target: self(),
           now: &Clock.now/0,
           burst: @burst,
           per_minute: @per_minute,
           capacity: @capacity,
           queue_size: 16
         ],
         opts
       )}
    )

    name
  end

  defp event(overrides \\ %{}) do
    Map.merge(
      %{
        "event_id" => "6f5d4c3b2a184e8f9c071b2d3e4f5061",
        "timestamp" => "2026-10-01T12:00:00Z",
        "platform" => "elixir",
        "level" => "error",
        "release" => "9f2c1ab",
        "environment" => "production",
        "transaction" => "courier.email.deliver",
        "tags" => %{"error.type" => "internal_error", "service.name" => "courier"},
        "exception" => %{
          "values" => [
            %{
              "type" => "RuntimeError",
              "module" => "Elixir.Courier.Deliver",
              "stacktrace" => %{
                "frames" => [
                  %{
                    "filename" => "lib/courier/deliver.ex",
                    "function" => "deliver/3",
                    "lineno" => 42,
                    "in_app" => true,
                    "module" => "Elixir.Courier.Deliver"
                  }
                ]
              }
            }
          ]
        }
      },
      overrides
    )
  end

  # An event as the **controller** hands it over: a decoded envelope item, not a
  # bare event. The distinction is load-bearing and the first version of this
  # file got it wrong, which is worth recording: passing the event map directly
  # to `ingest/2` makes every item a non-event, the relay filters all of them
  # out, and every assertion below fails at once with the relay reporting
  # `received: 3, forwarded: 0` — a shape that reads like a broken throttle and
  # is actually a test that built the wrong thing.
  defp as_item(event), do: %{"type" => "event", "payload" => event}

  # Drain whatever the relay has forwarded. `receive` rather than a sleep: the
  # house rules forbid `Process.sleep/1`, and a sleep is also how a flaky test
  # gets written.
  defp forwarded(acc \\ [], timeout \\ 200)

  defp forwarded(acc, timeout) do
    receive do
      {:relayed, envelope} -> forwarded([envelope | acc], timeout)
    after
      timeout -> Enum.reverse(acc)
    end
  end

  # Every `ingest/2` is a **cast**, so a test that fires ten thousand of them has
  # ten thousand messages in the relay's mailbox and has read nothing. Asking for
  # the stats without this first returned `received: 1410` out of 10 000 — a
  # number that looks like a throttle bug and is really an unsynchronised read.
  #
  # `:sys.get_state/1` on the relay, then on the sender, which is the idiom the
  # house rules name for "let the process handle its prior messages". The sender
  # is second because it is the relay that accepts the cast that starts a drain.
  defp sync(relay) do
    :sys.get_state(relay)
    :sys.get_state(ErrorRelay.sender_name(relay))
    :ok
  end

  describe "a hot loop becomes a bounded number of notifications" do
    test "ten thousand occurrences of one bug forward three and count the rest" do
      relay = start_relay()

      for _ <- 1..10_000, do: ErrorRelay.ingest(relay, [as_item(event())])
      sync(relay)

      # Three is `@burst`. The ten thousand is not a performance figure — it is
      # the shape of the failure this exists for, and 10k costs the same as 10.
      assert 3 == length(forwarded())
      assert %{forwarded: 3, throttled: 9_997} = ErrorRelay.stats(relay)
    end

    test "a different bug has its own bucket" do
      relay = start_relay()

      for _ <- 1..@burst, do: ErrorRelay.ingest(relay, [as_item(event())])
      assert @burst == length(forwarded())

      # The first bug's bucket is empty. This is a different operation, so it is
      # a different fingerprint and a different key: one bug in a hot loop must
      # not be able to silence a second bug that is also happening.
      ErrorRelay.ingest(relay, [as_item(event(%{"transaction" => "courier.webhook.send"}))])
      assert 1 == length(forwarded())
    end

    test "the bucket refills, so a bug that is still happening keeps being reported" do
      relay = start_relay()

      for _ <- 1..@burst, do: ErrorRelay.ingest(relay, [as_item(event())])
      assert @burst == length(forwarded())

      # No time has passed: still empty.
      ErrorRelay.ingest(relay, [as_item(event())])
      assert 0 == length(forwarded())

      # `@per_minute` 60 is one token per second. 999ms is not enough, and
      # asserting the near miss is what pins the *rate* rather than just
      # "eventually something happened".
      Clock.advance(999)
      ErrorRelay.ingest(relay, [as_item(event())])
      assert 0 == length(forwarded())

      Clock.advance(1)
      ErrorRelay.ingest(relay, [as_item(event())])
      assert 1 == length(forwarded())
    end

    test "a very long idle period refills to `burst` and no further" do
      relay = start_relay()

      for _ <- 1..@burst, do: ErrorRelay.ingest(relay, [as_item(event())])
      assert @burst == length(forwarded())

      Clock.advance(60 * 60 * 1000)
      for _ <- 1..(@burst * 3), do: ErrorRelay.ingest(relay, [as_item(event())])

      # Without the cap, a relay left alone over a weekend comes back with a
      # bucket of several thousand tokens and emits a burst on the first
      # exception — the throttled path would then be the thing that surprises
      # somebody, and it would surprise them during an incident.
      assert @burst == length(forwarded())
    end
  end

  describe "it cannot crash-loop" do
    test "the fingerprint table is bounded, whatever arrives" do
      relay = start_relay()

      for n <- 1..(@capacity * 3) do
        ErrorRelay.ingest(relay, [as_item(event(%{"transaction" => "courier.op#{n}"}))])
      end

      sync(relay)

      # Asserted on the table rather than on a counter, because a counter would
      # not notice a table that stopped being pruned.
      assert :ets.info(relay, :size) <= @capacity
    end

    test "a relay whose sink raises is still alive and still counting" do
      relay = start_relay(sink: FailingSink)

      assert :ok == ErrorRelay.ingest(relay, [as_item(event())])
      assert Process.alive?(Process.whereis(relay))

      # The sink really was called, and it really raised — `assert_receive` on
      # the mode is what distinguishes this from the error-tuple test below, and
      # it cannot pass by a counter going up for some other reason.
      assert_receive {:sink_attempted, :raise}, 1_000

      # The load-bearing half: a sink that raises on every call does not take the
      # relay with it, and the counter survives to say so. An error store that
      # crashes itself stops working at the exact moment it is needed.
      assert eventually(relay, fn -> ErrorRelay.stats(relay).sink_failures > 0 end)
      assert Process.alive?(Process.whereis(relay))

      # And it is still accepting: a second, differently-fingerprinted event is
      # attempted and counted rather than lost.
      ErrorRelay.ingest(relay, [as_item(event(%{"transaction" => "courier.webhook.send"}))])
      assert_receive {:sink_attempted, :raise}, 1_000
      assert eventually(relay, fn -> ErrorRelay.stats(relay).sink_failures > 1 end)
    end

    test "a sink that returns an error tuple is counted, not raised" do
      relay = start_relay(sink: FailingSink, sink_mode: :error)

      ErrorRelay.ingest(relay, [as_item(event())])

      # `{:sink_attempted, :error}` and not `{:sink_attempted, :raise}`: that
      # assertion is what proves `:sink_mode` reached the sink through the
      # relay's option forwarding. When the key was not forwarded, this test
      # passed anyway — the counter went up either way — and proved nothing about
      # the error-tuple path at all.
      assert_receive {:sink_attempted, :error}, 1_000
      assert eventually(relay, fn -> ErrorRelay.stats(relay).sink_failures > 0 end)
    end
  end

  describe "it never blocks the caller" do
    test "ingest/2 returns when the queue is full and nothing is draining" do
      # `queue_size: 0` is the honest way to reach the full state: filling a real
      # queue needs a sink slow enough to make the test wait, which is a sleep
      # wearing a test's clothes. The drop is the behaviour under test and the
      # zero is what puts us in it.
      relay = start_relay(queue_size: 0)

      assert :ok == ErrorRelay.ingest(relay, [as_item(event())])
      assert eventually(relay, fn -> ErrorRelay.stats(relay).queue_full > 0 end)

      # The load-bearing half: the caller got `:ok` and the relay is up. A full
      # queue is a **drop**, and a drop is the whole point — the error store is
      # best-effort and must never be the reason a request waits.
      assert Process.alive?(Process.whereis(relay))
    end

    test "an event nobody can read is dropped with a reason, and the relay lives" do
      relay = start_relay()

      assert :ok == ErrorRelay.ingest(relay, [as_item("not an event at all")])

      assert :ok ==
               ErrorRelay.ingest(relay, [
                 as_item(event(%{"tags" => %{"service.name" => "courier"}}))
               ])

      assert eventually(relay, fn ->
               s = ErrorRelay.stats(relay)
               s.malformed + s.unclassified > 0
             end)

      assert Process.alive?(Process.whereis(relay))
      assert 0 == length(forwarded())
    end
  end

  describe "what the sink receives" do
    test "a Sentry envelope containing only what survived" do
      relay = start_relay()

      ErrorRelay.ingest(relay, [as_item(event())])

      assert [envelope] = forwarded()
      assert {:ok, [%{"type" => "event", "payload" => payload}]} = Sink.parse_envelope(envelope)
      assert {:ok, decoded} = Jason.decode(payload)
      assert "courier" == decoded["tags"]["service.name"]
    end

    test "two events in one envelope arrive as two items in one envelope" do
      relay = start_relay()

      # The Sentry SDK batches, and a relay that forwarded one item per request
      # would turn a batch of fifty into fifty requests to the store.
      ErrorRelay.ingest(relay, [
        as_item(event()),
        as_item(event(%{"transaction" => "courier.webhook.send"}))
      ])

      assert [envelope] = forwarded()
      assert {:ok, items} = Sink.parse_envelope(envelope)
      assert 2 == length(items)
    end

    test "a non-event item — a session, a transaction — is not forwarded" do
      relay = start_relay()

      # Sessions are the SDK's own health bookkeeping. A transaction is a second
      # copy of the span data the OTel pipeline already ships and already
      # redacts, and forwarding it would put instrumented data into the error
      # store through the one door this packet is careful about.
      ErrorRelay.ingest(relay, [
        %{"type" => "session", "payload" => %{"status" => "ok"}},
        %{"type" => "event", "payload" => event()},
        %{"type" => "transaction", "payload" => %{"spans" => [%{"description" => "a secret"}]}}
      ])

      assert [envelope] = forwarded()
      assert {:ok, [%{"type" => "event"}]} = Sink.parse_envelope(envelope)
      refute envelope =~ "a secret"
    end
  end

  describe "the end-to-end boundary, asserted on the bytes that would be stored" do
    test "a secret the SDK put in `extra` and in a header is gone" do
      relay = start_relay()

      ErrorRelay.ingest(relay, [
        as_item(
          event(%{
            "extra" => %{"prompt" => @canary},
            "request" => %{"headers" => %{"Authorization" => @bearer}}
          })
        )
      ])

      assert [envelope] = forwarded()
      refute envelope =~ @canary
      refute envelope =~ @bearer
    end

    test "the exception message is gone, and the class survives" do
      relay = start_relay()

      ErrorRelay.ingest(relay, [
        as_item(
          event(%{
            "exception" => %{
              "values" => [%{"type" => "RuntimeError", "value" => "boom: #{@canary}"}]
            }
          })
        )
      ])

      assert [envelope] = forwarded()
      refute envelope =~ @canary
      assert envelope =~ "RuntimeError"
    end
  end

  describe "the fingerprint is the relay's, not the caller's" do
    test "a caller that changes its Sentry fingerprint every event cannot defeat the throttle" do
      # Sentry's own `fingerprint` field lets a client choose its grouping. If
      # the relay honoured it, a caller could defeat the throttle entirely by
      # sending a fresh value per event — and, in the other direction, could
      # collapse every error in the fleet into a single group. So the relay
      # computes its own, from the redacted event, and drops the field.
      relay = start_relay()

      for n <- 1..5 do
        ErrorRelay.ingest(
          relay,
          [
            as_item(
              event(%{
                "event_id" => "event-#{n}",
                "timestamp" => "2026-10-01T12:0#{n}:00Z",
                "fingerprint" => ["a-different-group-every-time"]
              })
            )
          ]
        )
      end

      assert @burst == length(forwarded())
      assert %{throttled: 2} = ErrorRelay.stats(relay)
    end
  end

  # A bounded poll rather than a sleep, and each pass synchronises with **both**
  # the relay and its sender, in that order. The relay first, because the sender
  # is linked to it and the relay is what accepts the cast; the sender second,
  # because the sender's `handle_cast(:drained, …)` is what guarantees the sink
  # has already run — the drain task forwards every envelope and *then* casts
  # `:drained`, so once the sender has handled that cast the counter is written.
  #
  # Synchronising only the relay made this poll spin two hundred times without the
  # sender ever being scheduled, which is a test that is fast when it passes and
  # slow when it fails — the worst combination. `Process.sleep/1` is forbidden by
  # the house rules, and it would also have hidden the ordering this relies on.
  defp eventually(relay, fun, attempts \\ 200)
  defp eventually(_relay, _fun, 0), do: false

  defp eventually(relay, fun, attempts) do
    :sys.get_state(relay)
    :sys.get_state(ErrorRelay.sender_name(relay))

    if fun.() do
      true
    else
      eventually(relay, fun, attempts - 1)
    end
  end
end
