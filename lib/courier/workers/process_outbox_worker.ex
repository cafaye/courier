defmodule Courier.Workers.ProcessOutboxWorker do
  @moduledoc """
  courier's relay: it claims unpublished outbox rows in a batch, hands each to
  `Courier.NatsPublisher`, and marks what was published.

  This is the only consumer of courier's own database, and it runs in a job
  rather than on a request path — a request never waits for the bus.

  The loop is core's (`core/docs/event-outbox.md`) and every rule in it is here
  for a reason:

    * **`for update skip locked`** so N replicas can run this against one table.
      A row another relay has claimed is skipped, not blocked on, so a slow batch
      cannot stall the rest.
    * **Ack, then mark.** `published_at` is set from the publisher's answer and
      never before, so a publish nobody acknowledged stays unpublished and the
      next pass republishes it — same `id`, so a consumer that already saw it
      ignores the duplicate. A refused row records its attempt and its reason
      instead, and is never marked published.
    * **A batch, ordered oldest first**, so subscribers see sends in the order
      they happened.
    * **A row that has exhausted its attempts is left alone.** An event stuck
      for an hour is an incident to alert on, not something to retry forever or
      drop silently.
    * **One refusal does not hold up the rows behind it.** The batch is published
      in order, each row on its own answer; a failure is recorded and the loop
      continues.

  The batch size, the attempt cap, and the backoff are read from application env
  at runtime, so a deployment can retune the relay without a rebuild.
  """

  import Ecto.Query

  alias Courier.NatsPublisher
  alias Courier.OutboxEvent
  alias Courier.Repo

  # The relay's backoff ceiling, in seconds. Core asks for "a few minutes"; a
  # minute is short enough that a broker that comes back is picked up while
  # anyone is still watching, and long enough that an outage is not a hot loop.
  @backoff_cap 60

  # The attempt cap is read here, at compile time, because Oban reads a worker's
  # options when it builds a job — and it is the same number
  # `config :courier, :outbox` holds, so the queue and the relay agree on what
  # "past the cap" means. `claim/0` reads the same key at runtime.
  @max_attempts Application.compile_env(:courier, :outbox)[:max_attempts]

  use Oban.Worker, queue: :outbox, max_attempts: @max_attempts

  @doc """
  Claims a batch, publishes it, and marks what the publisher acknowledged.

  `{:ok, %{published: n}}` when everything in the batch went out (including when
  there was nothing to do), and `{:error, summary}` when something did not, with
  `published`, `failed`, and the first `reason` the publisher gave. The error
  return is what Oban retries with `backoff/1`; the row keeps its own attempt
  count and reason either way.
  """
  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    {:ok, summary} = Repo.transaction(&relay/0)

    if summary.failed == 0 do
      {:ok, %{published: summary.published}}
    else
      {:error, Map.take(summary, [:published, :failed, :reason])}
    end
  end

  @doc """
  How long to wait before the next attempt of `job`, in seconds.

  Exponential in the attempt, capped, and jittered: two relays that recovered
  from the same outage must not retry in lockstep, and an exact schedule would
  put them back on the broker together. The jitter is bounded by the base
  rather than added on top of it, so the wait still grows with the attempt and
  never reaches zero.
  """
  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    base =
      attempt
      |> max(1)
      |> min(8)
      |> Kernel.-(1)
      |> then(&(2 ** &1))

    min(@backoff_cap, base + :rand.uniform(base))
  end

  defp relay do
    publisher = NatsPublisher.impl()

    Enum.reduce(claim(), %{published: 0, failed: 0, reason: nil}, fn event, summary ->
      case publisher.publish(OutboxEvent.envelope(event)) do
        :ok ->
          mark_published(event)
          %{summary | published: summary.published + 1}

        {:error, reason} ->
          mark_refused(event, reason)
          %{summary | failed: summary.failed + 1, reason: summary.reason || reason}
      end
    end)
  end

  defp claim do
    OutboxEvent
    |> where([event], is_nil(event.published_at) and event.attempt_count < ^max_attempts())
    |> order_by([event], asc: event.occurred_at, asc: event.inserted_at)
    |> limit(^batch_size())
    |> lock("FOR UPDATE SKIP LOCKED")
    |> Repo.all()
  end

  # `published_at` is set here and nowhere else, and only from an acknowledgement.
  defp mark_published(event) do
    event
    |> Ecto.Changeset.change(published_at: DateTime.utc_now(), last_error: nil)
    |> Repo.update!()
  end

  defp mark_refused(event, reason) do
    event
    |> Ecto.Changeset.change(
      attempt_count: event.attempt_count + 1,
      last_error: to_string(reason)
    )
    |> Repo.update!()
  end

  defp batch_size, do: outbox()[:batch_size]
  defp max_attempts, do: outbox()[:max_attempts]

  defp outbox, do: Application.get_env(:courier, :outbox, [])
end
