defmodule Courier.TestSupport.FailingSink do
  @moduledoc """
  A `Courier.ErrorRelay.Sink` that fails in **both** of the ways a real one can,
  because they fail differently and the relay has to survive each.

    * `raise/1` — the bug. An exception out of the HTTP client, a bad TLS
      certificate, a `Req` call that raises rather than returning. This is the
      one that would take the relay down if the forwarding were not wrapped.
    * `{:error, reason}` — the ordinary case. A 503 from GlitchTip, a DNS
      failure, a refused connection. Nothing is exceptional about it and it must
      not be logged as though it were.

  Both are counted in the same `sink_failures` stat, deliberately: the counter is
  a health signal for the error path, and a health signal that distinguishes
  "GlitchTip said no" from "our own client has a bug" is a second counter
  somebody has to remember to look at. The distinction is in the log line's
  level, not in the metric's shape.
  """

  @behaviour Courier.ErrorRelay.Sink

  @impl Courier.ErrorRelay.Sink
  def forward(_envelope, opts) do
    notify(opts)
    fail(opts)
  end

  # Tell the test the sink was reached. The relay's counters are in ETS, so a
  # test can poll them — and polling is what made this file flaky, because two
  # hundred `:sys.get_state/1` calls complete in well under a millisecond and a
  # drain task scheduled behind them may not have run at all. The test then
  # failed roughly one run in three depending on the seed.
  #
  # `assert_receive` is the primitive the house rules name for waiting, it cannot
  # pass by accident, and it makes the assertion *stronger*: the counter going up
  # proves the accounting, this message proves the sink was actually called, and
  # a relay that counted a failure it never had would fail the second and pass
  # the first.
  defp notify(opts) do
    case Keyword.get(opts, :sink_target) do
      pid when is_pid(pid) -> send(pid, {:sink_attempted, mode(opts)})
      _absent -> :ok
    end
  end

  # The mode this sink fails in, read from the options the relay forwards.
  #
  # The relay passes `:sink_target`, `:sink_dsn`, `:sink_timeout` and
  # `:sink_mode` through to `forward/2` (`Courier.ErrorRelay.init/1`), so a mode
  # configured in a test's relay options arrives. The reason this is written down
  # is that the first version of the error-tuple test set `:sink_mode` on the
  # relay, watched the sink **raise** anyway, and passed for the wrong reason: the
  # counter went up either way, so the assertion could not tell which of the two
  # failures it was proving — and `notify/1` above now makes that mistake fail
  # loudly instead, because the message would say `:raise` where the test
  # expected `{:sink_attempted, :error}`.
  defp fail(opts) do
    case mode(opts) do
      :raise -> raise "the sink is unreachable"
      :error -> {:error, :econnrefused}
    end
  end

  defp mode(opts), do: Keyword.get(opts, :sink_mode, :raise)
end
