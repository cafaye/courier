defmodule Courier.ErrorRelay.Sender do
  @moduledoc """
  The bounded queue between the relay's decision and the store's socket.

  ## Why this is a process and not a function call

  Because the two things the brief asks to be true are in tension, and a process
  boundary is what resolves them:

    * a failure in the error path must never **crash** the main request path;
    * a failure in the error path must never **block** it either.

  Calling the sink inline satisfies neither past the first `try`. A sink that
  takes thirty seconds to time out holds the relay for thirty seconds, the
  relay's mailbox grows behind it, and the HTTP endpoint that received the
  envelope — in *another* service — is meanwhile retrying. So the forward happens
  in a supervised `Task` with a deadline, and a sink that overruns it is
  `Task.shutdown(:brutal_kill)`ed and counted.

  A task that hangs forever is a thread that never comes back, and a supervisor
  whose child is killed is a supervisor that is still running. `brutal_kill` is
  the right violence here: the task holds a socket to a store that has already
  stopped answering, and there is nothing in it worth a graceful shutdown.

  ## What `size` actually bounds, stated precisely

  The queue holds envelopes that have been **accepted while a forward is already
  in flight**. One forward is in flight at a time, and everything accepted while
  it runs accumulates; when it finishes, the next drain takes the lot. So `size`
  is a bound on work the store has not yet been given, which is the only reading
  under which "full means drop" is a real state rather than a formality — and it
  is why `queue_size: 0` refuses everything, which is how the test that exercises
  the full path reaches it without a slow sink and a sleep.

  ## Both failure shapes are counted as one

  A sink that raises and a sink that returns `{:error, _}` both land in
  `sink_failures`. They are not the same problem, but they have the same response
  — the error path is not reaching the store, and nothing inside the request path
  can fix that — and a counter that distinguishes them is a counter somebody has
  to remember to look at. The distinction is in the log level: a raise is logged
  at `:error` with the exception, an error tuple at `:warning`.

  ## It never dies, which is the point

  Every clause is wrapped. An error store that crashes itself stops working at
  exactly the moment it is needed, and a sender that could be crashed by a
  malformed envelope would be a sender a service could switch off by sending one.
  """

  use GenServer

  require Logger

  alias Courier.ErrorRelay

  @doc false
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
  end

  @doc """
  Offer an envelope. A cast, so the relay is never waiting on the store.
  """
  @spec enqueue(GenServer.server(), binary()) :: :ok
  def enqueue(server, envelope) when is_binary(envelope) do
    GenServer.cast(server, {:enqueue, envelope})
  end

  @impl GenServer
  def init(opts) do
    name = Keyword.fetch!(opts, :name)

    # A `Task.Supervisor` per sender, so a drain that hangs holds nothing else up
    # and cannot be mistaken for the sender being busy. The **pid** is what goes
    # in the state, not the name: `start_link/1` returns a pid, and a later
    # `whereis/1` on a pid is a `FunctionClauseError` at run time.
    #
    # The name is registered as well, so a crash report names something a reader
    # can look up rather than printing a bare pid.
    {:ok, tasks} = Task.Supervisor.start_link(name: :"#{name}.tasks")

    {:ok,
     %{
       relay: Keyword.fetch!(opts, :relay),
       sink: Keyword.fetch!(opts, :sink),
       sink_opts: Keyword.get(opts, :sink_opts, []),
       size: Keyword.get(opts, :size, 256),
       timeout: Keyword.get(opts, :timeout, 5_000),
       queue: %{},
       in_flight: false,
       tasks: tasks
     }}
  end

  @impl GenServer
  def handle_cast({:enqueue, envelope}, state) when is_binary(envelope) do
    if map_size(state.queue) < state.size do
      state
      |> Map.update!(:queue, &Map.put(&1, System.unique_integer([:positive]), envelope))
      |> maybe_drain()
    else
      # Counted straight into the relay's table rather than by casting back to
      # it: a message behind a message is how a full queue becomes an unbounded
      # mailbox, which is the thing this queue exists to prevent.
      dropped = ErrorRelay.count_stat(state.relay, :queue_full, 1)

      # The **log line is throttled, the counter is not.** A full queue drops
      # every envelope it is offered, so a hot loop in one service produces one
      # warning per occurrence — and a log store filling with ten thousand
      # identical lines is a second denial of service, committed by the
      # component that exists to report the first one. The counter moves every
      # time, so nothing is lost; the first drop and then every hundredth are said
      # out loud.
      #
      # This is the brief's "alert on rate, not on every occurrence", met in the
      # one place a test can hold it: the log. GlitchTip's own alert rules are
      # configured in the store, not in this repository.
      if dropped == 1 or rem(dropped, 100) == 0 do
        Logger.warning(
          "[error-relay] queue full at #{state.size}, dropped #{dropped} so far. " <>
            "The store is not keeping up with the error path."
        )
      end

      {:noreply, state}
    end
  end

  # `maybe_drain/1` **already returns** `{:noreply, state}` — it is a complete
  # `handle_cast/2` result, because both call sites below need it to be one.
  # Wrapping it again here produced `{:noreply, {:noreply, state}}`, which is not
  # a valid `GenServer` return: the sender terminated on the first drain, and the
  # sender is *linked* to the relay, so the relay went down with it.
  #
  # The symptom was the most misleading one this component has. The first batch
  # was forwarded, `in_flight` was then stuck at `true`, and every later envelope
  # accumulated in the queue until it hit its bound and started dropping. And
  # because the supervisor restart gave a fresh sender with an empty queue, the
  # relay's `forwarded` counter went on counting while nothing was sent — so
  # `stats/1` agreed with itself and was wrong about the store.
  # `:drained` is a bare **atom**, not `{:drained}`.
  #
  # `GenServer.cast(server, :drained)` sends `{:"$gen_cast", :drained}` — the
  # second element is the term itself, so a clause written `handle_cast({:drained},
  # state)` never matches and the drain's "I have finished" message is swallowed
  # by the catch-all below. The consequence is silent and total: the first batch
  # is forwarded, `in_flight` stays `true` for the life of the process, and every
  # later envelope piles into the queue until it reaches its bound and starts
  # dropping. The relay's `forwarded` counter keeps climbing the whole time, so
  # the numbers look healthy and describe a store that received one event.
  #
  # That is also why the catch-all now **logs**. A clause that cannot match is
  # the most expensive kind of typo in a process whose whole job is to be
  # reliable, and the only reason this one survived as long as it did is that
  # there was a catch-all quietly absorbing it.
  def handle_cast(:drained, state) do
    maybe_drain(Map.put(state, :in_flight, false))
  end

  # Anything else is a cast courier does not recognise, which is a bug rather
  # than a crash: the sender is the process the error path depends on. Logged,
  # not ignored, for the reason in the clause above.
  def handle_cast(other, state) do
    Logger.error("[error-relay] the sender received an unrecognised cast: #{inspect(other)}")
    {:noreply, state}
  end

  # --- the drain -------------------------------------------------------------

  # `state.tasks` is a **pid**, not a name. `DynamicSupervisor.start_child/2`
  # takes either, but the two are not interchangeable here: this sender is
  # started by `Courier.ErrorRelay.init/1`, which stores the pid it got back from
  # `DynamicSupervisor.start_link/1`, and handing that pid to `start_child/2`
  # fails at run time with a `FunctionClauseError` in `GenServer.whereis/1`. The
  # first version of this file had the crash in a `:temporary` task, which the
  # supervisor then reported as a dying process — an error store failing in a
  # way that looks like a crash loop rather than a wiring mistake, and one that
  # only appears once something is actually forwarded.
  # `id` is unique per drain, and the child is a `Task` returned as `{:ok, pid}`.
  #
  # Both details are load-bearing and both were wrong in the first version:
  #
  #   * A **fixed** id is refused with `{:error, :already_present}` while a
  #     previous `:temporary` child is still being reaped, and the reaping is
  #     asynchronous. A second drain arriving in that window would lose its whole
  #     batch to the error clause below — which logs "the store refused" and
  #     counts the envelopes as queue-full, so the events are gone *and* the
  #     reason is wrong. That is the worst failure this component can have.
  #   * The child's start function **must return `{:ok, pid}`**. A start function
  #     that returns bare `:ok` looks like it worked — the drain body does run,
  #     the envelopes *are* forwarded — and then the supervisor reports
  #     `{:error, :ok}`, which the code below counted as a lost batch. So the
  #     symptom was a relay that appeared to drop every event while the store
  #     quietly received them. The `Task.Supervisor.async_nolink/1` is what
  #     makes the `{:ok, pid}` come from a process that is genuinely the drain.
  # Nothing to do: either a drain is already in flight, or the queue is empty.
  # Both are the same answer, and two guarded clauses would be two ways to be
  # wrong about one state.
  defp maybe_drain(%{in_flight: false, queue: queue} = state) when map_size(queue) > 0 do
    batch = queue

    case drain_async(state, batch, self()) do
      {:ok, _pid} ->
        {:noreply, %{state | queue: %{}, in_flight: true}}

      {:error, reason} ->
        # Nowhere to put the batch, so it is counted as queue-full — which is
        # what it is: work the error path accepted and then could not hand on.
        # Losing it is the correct outcome; raising would take down the sender,
        # and the counter is what tells an operator the store is not the problem.
        ErrorRelay.count_stat(state.relay, :queue_full, map_size(batch))

        Logger.error(
          "[error-relay] the drain supervisor refused a batch of #{map_size(batch)}: " <>
            inspect(reason)
        )

        {:noreply, %{state | queue: %{}, in_flight: true}}
    end
  end

  # Nothing to do: either a drain is already in flight, or the queue is empty.
  # Both are the same answer, and two guarded clauses would be two ways to be
  # wrong about one state. It sits directly under its sibling because Elixir
  # requires clauses of one name to be adjacent, and putting the helper between
  # them is a warning that reads like a style note and is actually a reordering
  # that changed which clause runs.
  defp maybe_drain(state), do: {:noreply, state}

  # A `Task.Supervisor`, not a `DynamicSupervisor` with a hand-built child spec,
  # and the reason is that `Task.start_link/2` — the MFA a hand-built spec would
  # name — **does not exist**. `Task` exposes `start/1` and `async/1`, neither of
  # which is a supervisor start function, so a spec naming it fails with
  # `{:error, {:undef, [{Task, :start_link, ...}]}}`.
  #
  # That is invisible in the ways that matter: `DynamicSupervisor.start_child/2`
  # returns an error rather than raising, the batch is counted as queue-full, and
  # the relay logs "the store refused" and reports dropping every event — while
  # the store receives none. An observability component that reports total data
  # loss truthfully is worse than one that is merely broken, because the counter
  # says the problem is downstream.
  #
  # `Task.Supervisor.start_child/2` returns `{:ok, pid}`, supervises the drain, and
  # is the tool the standard library provides for exactly this.
  defp drain_async(state, batch, owner) do
    Task.Supervisor.start_child(state.tasks, fn -> drain(state, batch, owner) end)
  end

  # `owner` is the sender, passed in rather than looked up: `self()` inside the
  # drain is the drain **task**, and casting `:drained` to the task would be a
  # message to a process that has already exited. That is why the cast at the
  # end of that function was previously a no-op and `in_flight` stayed `true`
  # forever — after which the sender accepted envelopes, never drained them, and
  # the queue silently grew to its bound and started dropping everything. The
  # symptom was a relay that looked alive and reported nothing.
  @doc false
  def drain(state, batch, owner) do
    # `Enum.each` rather than `Enum.map(&Task.async/1)`: one task per envelope
    # would be N supervisors and N sockets, and the store is a single Postgres
    # behind a single web container. Sequential inside the drain, parallel across
    # drains is not a trade worth making here.
    Enum.each(batch, fn {_key, envelope} -> forward(state, envelope) end)

    GenServer.cast(owner, :drained)
    :ok
  end

  defp forward(state, envelope) do
    task =
      Task.async(fn ->
        try do
          state.sink.forward(envelope, state.sink_opts)
        rescue
          exception ->
            Logger.error(
              "[error-relay] the sink raised and the envelope is lost: " <>
                Exception.message(exception)
            )

            :raised
        catch
          kind, reason ->
            Logger.error("[error-relay] the sink exited #{kind}: #{inspect(reason)}")
            :caught
        end
      end)

    case Task.yield(task, state.timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, :ok} ->
        :ok

      {:ok, {:error, reason}} ->
        # The ordinary case: GlitchTip said no, or the socket did. A warning,
        # because it is expected under an outage and is not courier's bug.
        Logger.warning("[error-relay] the store refused an envelope: #{inspect(reason)}")
        ErrorRelay.count_stat(state.relay, :sink_failures, 1)
        :ok

      {:exit, reason} ->
        Logger.error("[error-relay] the sink exited: #{inspect(reason)}")
        ErrorRelay.count_stat(state.relay, :sink_failures, 1)
        :ok

      other ->
        # `:raised`, `:caught`, and anything the sink returned that is neither
        # `:ok` nor an error tuple. Counted the same way, for the reason in the
        # moduledoc.
        Logger.error("[error-relay] the sink did not forward: #{inspect(other)}")
        ErrorRelay.count_stat(state.relay, :sink_failures, 1)
        :ok
    end
  end
end
