defmodule Courier.ErrorRelay do
  @moduledoc """
  The error path's chokepoint: classify, fingerprint, throttle, re-frame, hand on.

  ## What this process is for, in one sentence

  It is the one place in the fleet where a Sentry envelope is allowed to become
  a stored error, and the only place the redaction policy is applied — because
  core's `redaction.schema.json` says enforcement happens at **one** chokepoint,
  and the OTel collector cannot reach the error path (GlitchTip speaks the
  Sentry protocol; it has no OTLP receiver for errors).

  ## The shape, and why each piece is where it is

      SDK  ──envelope──▶  [ ingest/2, a cast ]  ──▶  Sender   ──bytes──▶  Sink
                             │                      (bounded queue,     (Req → GlitchTip)
                             │                       async drain)
                             └──▶ Policy.redact/1  ──▶ classify/1
                                  Policy.fingerprint/1
                                  token bucket, in ETS

  Three properties fall out of that shape and each is a requirement rather than
  a nicety:

    * **`ingest/2` is a cast.** It returns `:ok` immediately. The HTTP endpoint
      that receives an envelope answers `200` before anything is forwarded, so a
      GlitchTip that is down, slow, or absent cannot add latency to a request in
      another service. Losing an error is strictly better than becoming a slow
      service, and it is the same rule the collector's exporters follow with
      `sending_queue: {enabled: false}`.

    * **The queue is bounded and full means drop.** An unbounded queue in front
      of a slow sink is a memory leak with an observability-shaped trigger. A
      full queue is counted in `queue_full` and the envelope is discarded.

    * **The throttle table is bounded and prunes itself.** One bug in a hot loop
      must not become ten thousand stored errors, and ten thousand *distinct*
      errors must not become ten thousand table entries. Sentry does not sample
      errors by design, so this is the volume control the SDK deliberately does
      not provide.

  ## The throttle, and the fact that the fingerprint is ours

  Sentry's protocol lets a client choose its own grouping via a `fingerprint`
  field. The relay **ignores and drops** it. If it were honoured, a caller could
  defeat the throttle completely by sending a fresh value per event, and — in
  the other direction — could collapse every error in the whole fleet into one
  group. `Courier.ErrorRelay.Policy.fingerprint/1` computes the key from the
  *redacted* event instead: service, `error.type`, operation, exception classes,
  and the application frames' module/function/line. `release` is deliberately
  excluded, so a deploy does not open a second group for a bug that was never
  fixed.

  ## Stats are an ETS table, not the relay's state

  `stats/1` reads a table both this process and `Courier.ErrorRelay.Sender`
  write, because `sink_failures` and `queue_full` are the *sender's* facts and
  making the sender report them by casting to the relay would put a message
  behind a message. The table is `:public` so the sender can write it without
  either process being able to stop the other; nothing in it is a secret and it
  is bounded to a fixed set of keys.

  ## A restart is a reset, and that is the right failure

  The throttle lives in memory, so a relay restart empties every bucket and the
  first `@burst` occurrences of a hot bug get through again. The alternative —
  persisting buckets — would put the error path's state in a database, and the
  brief is explicit that the error store is separate from the application's
  primary database. An operator who sees a burst after a deploy has seen a
  restarted relay, which is a sentence they can act on.
  """

  use GenServer

  alias Courier.ErrorRelay.Policy
  alias Courier.ErrorRelay.Sender
  alias Courier.ErrorRelay.Sink

  # Every counter in `stats/1`. Written down rather than derived from a map's
  # keys, so a counter that is never incremented is a zero in the output instead
  # of a missing key, and so a reader of `stats/1` can see the whole shape
  # without reading this module.
  @counters ~w(received forwarded throttled malformed unclassified undeclared
               queue_full sink_failures)a

  @default_burst 5
  @default_per_minute 60
  @default_capacity 4_096
  @default_queue_size 256

  # --- client ----------------------------------------------------------------

  @doc """
  Hand a list of decoded envelope items to the relay. Returns `:ok`, always.

  A cast, deliberately. See the moduledoc: the caller is an HTTP endpoint in
  another service that must not wait on anything to do with error reporting, and
  the return value is `:ok` whether the event was forwarded, throttled, dropped
  or never readable.
  """
  @spec ingest(GenServer.server(), [map()]) :: :ok
  def ingest(server \\ __MODULE__, items) when is_list(items) do
    GenServer.cast(server, {:ingest, items})
  end

  @doc """
  Every counter, as a map with all of `#{inspect(@counters)}` present.

  Read from the **stats** table, which is a *different* table from `table/1`.
  Reading the throttle table here looks right — both are named after the relay
  and both are ETS — and returns zero for every counter forever, because the
  counters are never written to it. That is the failure this clause's comment
  exists to prevent: a `stats/1` that is uniformly zero is indistinguishable
  from a relay that is genuinely receiving nothing, which is exactly the state
  an operator most needs to tell apart.
  """
  @spec stats(GenServer.server()) :: %{atom() => non_neg_integer()}
  def stats(server \\ __MODULE__) do
    Map.new(@counters, fn key ->
      case :ets.lookup(stats_table(server), {:stat, key}) do
        [{_key, value}] -> {key, value}
        [] -> {key, 0}
      end
    end)
  end

  @doc "The throttle table, for `:ets.info/2` and for a test asserting the bound."
  @spec table(GenServer.server()) :: atom() | reference()
  def table(server \\ __MODULE__), do: server

  # --- server ----------------------------------------------------------------

  @doc false
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl GenServer
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    # `:protected`, not `:public`: only the relay reads or writes the throttle,
    # and a protected table is still readable by a test through `:ets.info/2`,
    # which is all the bound assertion needs.
    :ets.new(name, [:set, :protected, :named_table, read_concurrency: true])

    # `:public` because the sender writes `queue_full` and `sink_failures` into
    # it and neither process may stop the other. See the moduledoc.
    :ets.new(stats_table(name), [:set, :public, :named_table, write_concurrency: true])

    sender =
      Keyword.get_lazy(opts, :sender, fn ->
        {:ok, pid} =
          Sender.start_link(
            name: sender_name(name),
            relay: name,
            sink: Keyword.get(opts, :sink, Courier.ErrorRelay.Sink.Req),
            # `sink_mode` is a test-only key. It is in the list rather than
            # dropped so `Courier.TestSupport.FailingSink` can be told to return
            # an error tuple instead of raising — see that module's `mode/1`,
            # which documents what happens when a key is *not* forwarded here.
            sink_opts: Keyword.take(opts, [:sink_target, :sink_dsn, :sink_timeout, :sink_mode]),
            size: Keyword.get(opts, :queue_size, @default_queue_size),
            timeout: Keyword.get(opts, :sink_timeout, 5_000)
          )

        pid
      end)

    {:ok,
     %{
       name: name,
       sender: sender,
       burst: Keyword.get(opts, :burst, @default_burst),
       per_minute: Keyword.get(opts, :per_minute, @default_per_minute),
       capacity: Keyword.get(opts, :capacity, @default_capacity),
       now: Keyword.get(opts, :now, fn -> System.monotonic_time(:millisecond) end),
       dsn: Keyword.get(opts, :sink_dsn)
     }}
  end

  @impl GenServer
  def handle_cast({:ingest, items}, state) do
    state = count(state, :received, length(items))
    {state, admitted} = forward(state, items, [])

    # **One envelope per ingest, not one per event.** The Sentry SDKs batch —
    # fifty events in one request is normal — and re-framing each event
    # separately would turn a batch into fifty POSTs to a single Postgres behind
    # a single web container. `sink_failures` would then be fifty chances to lose
    # one crash instead of one.
    enqueue(state, admitted)

    {:noreply, state}
  end

  @impl GenServer
  def handle_cast({:count, key, by}, state) do
    {:noreply, count(state, key, by)}
  end

  # --- the pipeline ----------------------------------------------------------

  defp forward(state, items, admitted) do
    now = state.now.()

    Enum.reduce(items, {state, admitted}, fn item, {acc, kept} ->
      if event?(item) do
        {acc, event} = handle(acc, item["payload"], now)
        {acc, if(event, do: [event | kept], else: kept)}
      else
        {acc, kept}
      end
    end)
  end

  defp event?(%{"type" => "event"}), do: true
  defp event?(_other), do: false

  # The item's `payload` is **bytes**, not a map.
  #
  # `Courier.ErrorRelay.Sink.parse_envelope/1` deliberately does not decode: an
  # envelope's items are typed (`event`, `session`, `transaction`, `attachment`)
  # and only an `event` item's payload is JSON, so a reader that decoded
  # everything would reject an envelope for containing an attachment. So the
  # decoding happens here, once an `event` item has already been identified.
  #
  # This is the one place in the relay that parses, and the first version of the
  # relay did not parse at all — it passed the raw binary to `Policy.redact/1`,
  # which answered `{:error, :not_an_event}` and counted the event as
  # **malformed**. The relay reported `received: 1, forwarded: 0, malformed: 1`
  # and the caller got a `200`, so nothing anywhere was red and the store was
  # empty. It is caught by `CourierWeb.ErrorRelayEndpointTest`, which asserts on
  # the bytes the sink received over a real request rather than on a counter.
  defp handle(state, payload, now) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, decoded} when is_map(decoded) -> admit_or_discard(state, decoded, now)
      _not_json -> {count(state, :malformed, 1), nil}
    end
  end

  # An already-decoded payload, which is what a caller inside this repository
  # (a test, or `Courier.ErrorReporting` on a future in-process path) can hand
  # over. Both shapes are accepted so neither has to know about the other.
  defp handle(state, decoded, now) when is_map(decoded) do
    admit_or_discard(state, decoded, now)
  end

  defp handle(state, _neither, _now), do: {count(state, :malformed, 1), nil}

  defp admit_or_discard(state, decoded, now) do
    case Policy.redact(decoded) do
      {:error, :not_an_event} ->
        {count(state, :malformed, 1), nil}

      {:ok, redacted} ->
        admit(classify(state, redacted), redacted, now)
    end
  end

  # Classification is a **gate**, and the gate is here rather than folded into
  # `admit/3` because the first version piped the result of this `case` into
  # `admit/3` — which meant `admit/3` ran on all three branches and its return
  # value overwrote the `nil` that the unclassified branch had just produced. An
  # event with no `error.type` at all was therefore stored anyway, with no class
  # on it, and `stats/1` counted it as `unclassified` while the store received
  # it. The counter and the store disagreed, which is the one thing a counter is
  # for.
  defp classify(state, redacted) do
    case Policy.classify(redacted) do
      {:ok, _class} ->
        {state, redacted}

      {:error, :unclassified} ->
        {count(state, :unclassified, 1), nil}

      {:error, :undeclared} ->
        # Redaction already replaced the value with `_OTHER`; this counter is how
        # an operator learns that a service is reporting errors with a class that
        # is not in core's vocabulary, which is what an alert on `_OTHER` is for.
        {count(state, :undeclared, 1), redacted}
    end
  end

  # `nil` in, `nil` out: a dropped event is not throttled, because counting it as
  # throttled would report a volume problem where the real answer is a
  # classification one.
  defp admit({state, nil}, _redacted, _now), do: {state, nil}

  defp admit({state, redacted}, redacted, now) do
    if allow?(state, Policy.fingerprint(redacted), now) do
      {count(state, :forwarded, 1), redacted}
    else
      {count(state, :throttled, 1), nil}
    end
  end

  defp enqueue(state, []), do: state

  defp enqueue(state, admitted) do
    items = Enum.map(admitted, &%{"type" => "event", "payload" => &1})

    case Sink.build_envelope(items, state.dsn) do
      {:ok, envelope} ->
        Sender.enqueue(state.sender, envelope)
        state

      {:error, _reason} ->
        # Events that survived redaction and the throttle and then could not be
        # encoded is a bug here rather than in the caller. It is counted under
        # `malformed` because that is the counter an operator is already reading
        # for "events the relay did not store", and raising would take down the
        # process every other service's error reporting depends on.
        count(state, :malformed, length(admitted))
    end
  end

  # --- the throttle ----------------------------------------------------------

  # A token bucket, keyed by fingerprint, entirely in ETS.
  #
  # `{tokens, last_refill_ms, dropped}` per key. `tokens` is a float because a
  # refill of one token per second accumulates in milliseconds and rounding it
  # to an integer is how a bucket ends up either always empty or always full.
  defp allow?(state, fingerprint, now) do
    table = state.name

    case :ets.lookup(table, fingerprint) do
      [{^fingerprint, tokens, last, dropped}] ->
        refilled = min(state.burst, tokens + rate(state) * (now - last))
        available = floor(refilled)

        if available >= 1 do
          :ets.insert(table, {fingerprint, refilled - 1, now, dropped})
          true
        else
          :ets.insert(table, {fingerprint, refilled, last, dropped + 1})
          false
        end

      [] ->
        evict(table, state.capacity)
        # `burst - 1`, not `burst`. The first event of a bug **consumes** a
        # token, and storing a full bucket on the insert would hand out `burst +
        # 1` events before the bucket ran dry — one more than the configuration
        # says, and one more than every test in this file asserts. The off-by-one
        # is invisible in a reading of the code and obvious in a count.
        :ets.insert(table, {fingerprint, state.burst * 1.0 - 1, now, 0})
        true
    end
  end

  defp rate(%{per_minute: per_minute}), do: per_minute / 60_000

  # Prune the least recently seen fingerprint when the table is at its bound.
  #
  # The victim is chosen by `last_seen` rather than arbitrarily because the entry
  # most likely to be needed again is the one for a bug that is still happening,
  # and "still happening" is exactly what `last_refill_ms` records. A random or
  # first-found eviction would eventually evict a hot bug's bucket and let it
  # through again, which is the bug this table exists to prevent.
  defp evict(table, capacity) do
    if :ets.info(table, :size) >= capacity do
      case oldest(table) do
        nil -> :ok
        key -> :ets.delete(table, key)
      end
    end

    :ok
  end

  defp oldest(table) do
    # `foldl/3` rather than `select/2`, and the reason is a bug the bound test
    # caught. A match spec whose body is `[{{:"$2", :"$1"}}]` looks like it
    # returns a list of `{last, key}` tuples; the body of a match spec is a list
    # and `{{…}}` in that position constructs a tuple *containing* a tuple, so
    # `Enum.min/1` was picking a fingerprint out of a structure nobody meant to
    # build. The key it returned was not in the table, `evict/2` deleted nothing,
    # and the table grew to 192 entries against a bound of 64.
    {key, _last} =
      :ets.foldl(
        fn {fingerprint, _tokens, last, _dropped}, {_best, best_last} = acc ->
          if last < best_last, do: {fingerprint, last}, else: acc
        end,
        {nil, :infinity},
        table
      )

    key
  end

  # --- counters --------------------------------------------------------------

  defp count(state, key, by) do
    :ets.update_counter(stats_table(state.name), {:stat, key}, {2, by}, {{:stat, key}, 0})
    state
  end

  defp stats_table(name), do: :"#{name}.stats"

  @doc false
  def sender_name(name), do: :"#{name}.sender"

  # The `Task.Supervisor` the sender runs its drains under, which is where the
  # name `#{inspect(__MODULE__)}.Sender.init/1` builds it. It is exposed beside
  # `sender_name/1` rather than re-derived in a test because a test that spells
  # the string out would keep passing if the sender ever moved: the name would
  # stop matching anything, `which_children/1` would answer `[]`, and a wait that
  # silently waits for nothing looks exactly like a wait that found nothing to do.
  @doc false
  def tasks_name(name), do: :"#{sender_name(name)}.tasks"

  @doc false
  def count_stat(name, key, by) do
    :ets.update_counter(stats_table(name), {:stat, key}, {2, by}, {{:stat, key}, 0})
  end
end
