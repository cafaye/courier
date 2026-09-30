defmodule Courier.Repo.Migrations.CreateWebhookEndpoints do
  use Ecto.Migration

  @moduledoc """
  The endpoints courier signs for: one row per account-chosen URL.

  Four decisions in here are the packet's, not the generator's:

    * **`account_id` is a uuid with no foreign key.** identity owns accounts, and
      there is no `accounts` table in courier's database to point at — a
      `references/2` here would be a constraint against another service's
      schema, which is how two services come to share one by accident. The same
      reasoning `Courier.NotificationPreference` records for `user_id`.

    * **The unique index is on `(account_id, url)`, not on `url`.** Two accounts
      may legitimately register the same URL — an agency running one receiver
      for several customers — and one account may not register the same URL
      twice, because the second row would be a second copy of an endpoint whose
      failures, circuit state and delivery history belong together.

    * **`status` has a check constraint.** The context validates it, and so does
      the database, because the row is also written by a migration and a
      `Repo.insert!/2` in a console; a column that can only hold two values in
      the context and five in the database is a column nobody can reason about.

    * **`consecutive_failures` and `disabled_reason` are the circuit breaker.**
      The counter is what the threshold is compared against and the reason is
      what the customer is shown when their endpoint stops receiving events, so
      that "why did delivery stop" has an answer that is not in a log courier
      keeps. `disabled_reason` is nullable precisely so a customer-disabled
      endpoint is distinguishable from a tripped one.
  """

  def change do
    # `primary_key: false` because the id is a uuid, not the bigserial Ecto adds
    # by default. It is a uuid for the same reason `outbox_events` is: the id
    # appears in a URL a customer pastes into a dashboard, and a sequential
    # integer there tells every other customer how many endpoints exist.
    create table(:webhook_endpoints, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :account_id, :uuid, null: false
      add :url, :text, null: false
      add :description, :text

      # The sealing key is 32 bytes; the sealed value is nonce + ciphertext +
      # tag, base64-encoded. It is opaque: nothing outside `Courier.SecretBox`
      # may read it, and there is no code path that prints it.
      add :secret, :text, null: false

      add :status, :string, null: false, default: "enabled"
      add :consecutive_failures, :integer, null: false, default: 0
      add :disabled_reason, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:webhook_endpoints, [:account_id, :url],
             name: :webhook_endpoints_account_id_url_index
           )

    create constraint(:webhook_endpoints, :webhook_endpoints_status_check,
             check: "status IN ('enabled', 'disabled')"
           )

    # The relay's query: the enabled endpoints of one account, in creation order.
    # Partial, because disabled endpoints are the small set and the scan is over
    # the whole account's list.
    create index(:webhook_endpoints, [:account_id, :inserted_at],
             where: "status = 'enabled'",
             name: :webhook_endpoints_enabled_idx
           )
  end
end
