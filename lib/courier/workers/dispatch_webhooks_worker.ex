defmodule Courier.Workers.DispatchWebhooksWorker do
  @moduledoc """
  The fan-out: takes an event from courier's outbox and gives every enabled
  endpoint of that event's account a delivery to make.

  It is a *dispatcher*, not a sender. The two are separate jobs because they fail
  differently: a dispatch that cannot be made (a database is down) is worth
  retrying in seconds and never touches a customer's server, while a delivery
  that fails is a customer problem with a sixteen-hour budget and a circuit
  breaker. Folding them into one worker would mean every unreachable consumer
  retried the dispatch loop as fast as the database could answer.

  ## Idempotence

  This worker runs on a timer, so it runs again after a crash and may run
  concurrently on two replicas. Three things make a second run harmless:

    * `webhooks_dispatched_at` is set from the same transaction that created the
      deliveries, so a dispatch that half-happened is visible as not-happened and
      is redone rather than lost.
    * `webhook_deliveries` is unique on `(endpoint_id, event_id)`, so a repeated
      dispatch returns the row that already exists — with the *same* `webhook_id`.
      That matters: a second `webhook_id` would look like a second event to a
      consumer deduplicating on it, which is the one thing the spec's id exists
      to prevent.
    * the claim is `for update skip locked`, so two replicas do not dispatch the
      same event at the same time.

  ## Events with no account

  `Courier.Deliver` records `email.delivered` for a person, and courier does not
  know which account that person is in, so those events have no `account_id` and
  this worker skips them. Fanning them out to every account would deliver one
  customer's mail events to another — the payloads carry a recipient address.
  """

  import Ecto.Query

  alias Courier.OutboxEvent
  alias Courier.Repo
  alias Courier.WebhookDeliveries
  alias Courier.WebhookEndpoints

  # Read at compile time because Oban reads a worker's options when it builds a
  # job, and the same number is in `config :courier, :webhooks` for the runtime
  # read. The two agreeing is what "past the cap" means.
  @max_batch Application.compile_env(:courier, :webhooks)[:dispatch_batch_size]

  use Oban.Worker, queue: :webhooks, max_attempts: @max_batch

  @doc """
  Claims a batch of undispatched events and creates their deliveries.

  `{:ok, %{dispatched: n}}` where `n` is the number of delivery rows created. An
  event that had no endpoints still counts as dispatched: it was considered and
  found to have nowhere to go, and re-considering it every minute forever is not
  work.
  """
  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    {:ok, dispatched} = Repo.transaction(&dispatch/0)

    {:ok, %{dispatched: dispatched}}
  end

  defp dispatch do
    Enum.reduce(claim(), 0, fn event, dispatched ->
      # One transaction per event: the deliveries and the mark that says they were
      # made commit together or not at all. A dispatch recorded without its
      # deliveries is an event nobody will ever deliver again, silently.
      {:ok, created} = Repo.transaction(fn -> fan_out(event) end)

      {:ok, _event} = mark_dispatched(event)

      dispatched + created
    end)
  end

  defp fan_out(event) do
    WebhookEndpoints.enabled(event.account_id)
    |> Enum.count(fn endpoint ->
      WebhookDeliveries.insert!(endpoint, event.id)
      true
    end)
  end

  defp claim do
    OutboxEvent
    |> where(
      [event],
      not is_nil(event.account_id) and is_nil(event.webhooks_dispatched_at)
    )
    |> order_by([event], asc: event.inserted_at, asc: event.id)
    |> limit(^batch_size())
    |> lock("FOR UPDATE SKIP LOCKED")
    |> Repo.all()
  end

  defp mark_dispatched(event) do
    event
    |> Ecto.Changeset.change(webhooks_dispatched_at: DateTime.utc_now())
    |> Repo.update()
  end

  defp batch_size, do: config()[:dispatch_batch_size]

  defp config, do: Application.get_env(:courier, :webhooks, [])
end
