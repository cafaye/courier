defmodule Courier.Repo.Migrations.CreateWebhookDeliveries do
  use Ecto.Migration

  @moduledoc """
  One row per (endpoint, event) delivery: the record of what courier sent, what
  came back, and when to try again.

  The shape is the brief's plus two columns that make the row answerable:

  | column | why |
  | ------ | --- |
  | `webhook_id` | the `webhook-id` header value, generated once and never changed. Delivery is at-least-once (PLAN.md §3), so this is the consumer's deduplication key and it has to survive every retry |
  | `status` | `pending` / `succeeded` / `failed` / `exhausted`, so "claim what is due" is one indexed query and an operator can see an endpoint's state without counting rows |
  | `error` | why the last attempt failed, for a connection refused rather than a 500 — the two need different responses and the status code cannot hold either |

  `unique (endpoint_id, event_id)` is the fan-out's idempotency. Re-dispatching
  an event must not produce a second delivery for an endpoint, and the unique
  constraint is what says so at the database rather than in a check the caller
  might forget.

  `endpoint_id` cascades: a deleted endpoint takes its delivery history with it,
  because a history belonging to no endpoint is a table that only ever grows.
  """

  def change do
    create table(:webhook_deliveries, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :endpoint_id, references(:webhook_endpoints, type: :uuid, on_delete: :delete_all),
        null: false

      add :event_id, :uuid, null: false
      add :webhook_id, :string, null: false

      add :status, :string, null: false, default: "pending"
      add :attempt, :integer, null: false, default: 0
      add :status_code, :integer
      add :duration_ms, :integer
      add :error, :text
      add :next_attempt_at, :utc_datetime_usec
      add :attempted_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:webhook_deliveries, [:endpoint_id, :event_id],
             name: :webhook_deliveries_endpoint_id_event_id_index
           )

    create constraint(:webhook_deliveries, :webhook_deliveries_status_check,
             check: "status IN ('pending', 'succeeded', 'failed', 'exhausted')"
           )

    # The claim query. Partial on the statuses that can still be worked, because
    # a delivery is attempted a handful of times and then stays in the table
    # forever as a record — a scan over all of them would be a scan over
    # courier's entire delivery history on every poll.
    create index(:webhook_deliveries, [:next_attempt_at],
             where: "status IN ('pending', 'failed')",
             name: :webhook_deliveries_due_idx
           )

    create index(:webhook_deliveries, [:event_id], name: :webhook_deliveries_event_id_idx)
  end
end
