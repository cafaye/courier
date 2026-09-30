defmodule Courier.Repo.Migrations.AddWebhookFanoutToOutboxEvents do
  use Ecto.Migration

  @moduledoc """
  Two columns so an outbox event can be fanned out to a customer's endpoints.

  Core's `outbox_events` table is unchanged in shape (`core/docs/event-outbox.md`
  fixes the column list, and this service implements it). These are courier's
  additions, the way `last_error` is, and each one exists because a question
  cannot be answered without it:

  | column | why |
  | ------ | --- |
  | `account_id` | whose endpoints this event goes to. Nullable: `Courier.Deliver` records `email.delivered` for a *user*, and courier does not know which account that user is in — an event with no account has no endpoints to go to, and fanning it out to everyone would be one customer's mail events delivered to another |
  | `webhooks_dispatched_at` | when the event was fanned out. Separate from `published_at`, which is when it went to NATS: an event can be on the bus and not yet fanned out, or fanned out and not yet on the bus, and one timestamp cannot say both |

  `account_id` has no foreign key for the same reason `webhook_endpoints` has
  none: identity owns accounts and there is no table here to point at.

  The index is partial on "not yet dispatched", so the dispatch worker's claim is
  an index scan of the rows it still has to do rather than of every event courier
  has ever written.
  """

  def up do
    alter table(:outbox_events) do
      add :account_id, :uuid
      add :webhooks_dispatched_at, :utc_datetime_usec
    end

    create index(:outbox_events, [:inserted_at],
             where: "account_id IS NOT NULL AND webhooks_dispatched_at IS NULL",
             name: :outbox_events_undispatched_idx
           )
  end

  def down do
    drop index(:outbox_events, :outbox_events_undispatched_idx)

    alter table(:outbox_events) do
      remove :account_id
      remove :webhooks_dispatched_at
    end
  end
end
