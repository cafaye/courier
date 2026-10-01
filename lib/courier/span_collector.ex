defmodule Courier.SpanCollector do
  @moduledoc """
  courier's span processor, and the reason it exists at all.

  ## The upstream bug it works around

  The Erlang OpenTelemetry SDK cannot start a span processor. Not in 1.7.0, not
  in 1.5.1, and not through any configuration. `otel_tracer_server:init_processor/3`
  starts each configured processor with

      supervisor:start_child(otel_span_sup, [ProcessorModule, Config])

  and `otel_span_sup` is a `one_for_one` supervisor whose children are written out
  in `init/1`. A two-element list is not a child spec, so the call returns:

      {:error, {:invalid_child_spec, [:otel_simple_processor, %{…}]}}

  `init_processors/2` treats anything but `{:ok, pid, config}` as "drop this
  processor", so it is dropped — with a log at `info`, which nobody reads. Measured
  on this tree, against both versions:

      $ mix run -e "IO.inspect(Supervisor.which_children(:otel_span_sup))"
      [{:otel_span_sweeper, #PID<…>, :worker, …},
       {:otel_span_ets,     #PID<…>, :worker, …}]      # no processor, ever

  And a span with no processor is not exported at all: `otel_span_ets:end_span/3`
  does `ets:take(SPAN_TAB, SpanId)` and hands the record to the on-end list, which
  is empty, so the record is destroyed. A courier with this SDK emits nothing, and
  its startup line says telemetry is on.

  ## What this module does instead

  It supplies the on-end processor directly. `#tracer{}` in the SDK carries
  `on_end_processors :: fun((span()) -> boolean() | {error, term()})`, and
  `get_tracer/3` hands that record back — so courier can rebuild the record with
  its own function in that field. That is reaching into an SDK private, and it is
  done here rather than in every service, with three things making it survivable:

    * it is ONE function, and if the SDK's record changes shape the rebuild raises
      loudly at boot rather than exporting nothing;
    * the collector owns an ordinary ETS table and an ordinary GenServer, so
      deleting this module and its call site is a small, local change when the bug
      is fixed upstream;
    * it is asserted, not assumed: `test/courier/span_collector_test.exs` drives a
      real request and reads what came out the other end.

  ## What it is NOT

  Not a reimplementation of the SDK's batch processor in general. It accumulates
  into an ETS table and hands the table to a real exporter on an interval, which is
  the two operations that matter: the export is `:opentelemetry_exporter`'s own
  OTLP encoding, and the batching is one timer.

  No queue with unbounded growth, and that is the fleet's rule rather than a
  preference. A telemetry queue that accepts spans and holds them is a memory leak
  with a telemetry-shaped trigger. So the table is bounded, and when it is full the
  OLDEST spans are dropped: a span about a request that already finished is worth
  less than the process staying up, and losing one is strictly better than becoming
  a slow service.
  """

  use GenServer

  require Logger

  alias Courier.Telemetry

  @table :courier_pending_spans

  # Bounded, and bounded SMALL. The collector holds finished spans waiting for the
  # next flush; a hundred thousand of them is a hundred thousand records in the BEAM
  # heap, which is the memory-leak-with-a-telemetry-shaped-trigger the moduledoc
  # names. At 2000 the worst case is a few hundred kilobytes and a visible gap in
  # the trace store, which is the right way round.
  @capacity 2_000

  # The interval between exports, in milliseconds. 5s is the SDK's own batch
  # default and a dev-friendly number: long enough that a request is not an export,
  # short enough that `docker compose up` followed by one curl shows a trace.
  @flush_interval_ms 5_000

  @doc "Supervisor entry point, named for `Courier.Application`."
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  The SDK's on-end processor. Installed into the tracer record; see the moduledoc.

  Synchronous, because the record is already serialised and the only work is an
  `ets:insert`. It must return `true` — the SDK treats anything else as a failure
  and the span processor's contract says a boolean.
  """
  def on_end(span) do
    ensure_table()

    if :ets.info(@table, :size) >= @capacity do
      drop_oldest()
    end

    :ets.insert(@table, {:erlang.unique_integer(), span})
    true
  catch
    # A telemetry failure must not take a request down. An `ets:insert` should not
    # fail, and if the table is gone because the collector is restarting it will be
    # back; swallowing it here means a telemetry problem costs a span rather than
    # costing the caller a 500.
    _, _ -> false
  end

  @doc "Export everything pending, now. The test path and the shutdown path."
  def flush do
    GenServer.call(__MODULE__, :flush, 30_000)
  catch
    # No collector (a test that never started the tree), which is a no-op rather
    # than an error: a flush with nothing to flush is not a failure.
    :exit, _ -> :ok
  end

  @doc "How many spans are waiting for the next flush."
  def pending do
    case :ets.whereis(@table) do
      :undefined -> 0
      _ -> :ets.info(@table, :size)
    end
  end

  @doc "The capacity, so a test can assert the bound is what it says it is."
  def capacity, do: @capacity

  @impl true
  def init(_opts) do
    ensure_table()
    :ets.delete_all_objects(@table)
    schedule_flush()
    {:ok, %{}}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    {:reply, do_export(), state}
  end

  @impl true
  def handle_info(:flush, state) do
    do_export()
    schedule_flush()
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp do_export do
    if pending() == 0 do
      :ok
    else
      case Telemetry.exporter().export(:traces, @table, Telemetry.resource(), %{}) do
        :ok ->
          :ets.delete_all_objects(@table)
          :ok

        {:error, reason} ->
          # Left in the table, so the next flush retries. Dropping them would lose
          # a span for a transient failure; keeping them is bounded by @capacity.
          Logger.warning("exporting spans failed; they stay queued for the next flush",
            error: inspect(reason)
          )

          :ok
      end
    end
  catch
    _, reason ->
      Logger.warning("the span exporter raised; spans stay queued", error: inspect(reason))
      :ok
  end

  defp drop_oldest do
    case :ets.first(@table) do
      :"$end_of_table" ->
        :ok

      oldest ->
        :ets.delete(@table, oldest)
        drop_oldest()
    end
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:public, :named_table, :set])
      _ -> @table
    end
  end

  defp schedule_flush, do: Process.send_after(self(), :flush, @flush_interval_ms)
end
