defmodule Courier.Repo.Migrations.CreateEmailSuppressions do
  use Ecto.Migration

  @moduledoc """
  One row per address a provider has told courier not to write to again.

  ## Why a table and not a column on `notification_preferences`

  The obvious move is a `bounced` boolean on the preference row, and it does not
  work for a reason worth writing down: **`notification_preferences` is keyed by
  `(user_id, notification_type)` and a bounce carries neither.**

  A provider reports an **address**. courier holds no foreign key to identity's
  users, `notification_preferences` has no address column, and there is no table
  anywhere in this repository that maps an address to a `user_id`. So a bounce
  arriving at courier cannot be written into the preferences table at all — not
  "should not be", cannot: there is no `user_id` to write and no column to look it
  up by. Putting it there would mean inventing a synthetic user id, which is
  precisely the fabrication `Courier.NotificationPreferences` refuses everywhere
  else.

  The suppression is therefore keyed by the address, and the send path consults
  it **in addition to** the preference rather than instead of it. They answer two
  different questions about the same send:

      `notification_preferences`  "does this person want this type of mail?"
      `email_suppressions`        "can this mailbox still receive it?"

  A user who opted out is not mailed even if the address is perfect, and a user
  who wants the mail is not sent to a mailbox that hard-bounced an hour ago.
  `Courier.Deliver` asks both, in that order.

  ## `state`, and why it is NOT NULL

  The column is `NOT NULL` and constrained to courier's own two values, which is
  the decision the packet asks for: **a hard bounce marks the address
  `undeliverable`, a complaint marks it `suppressed`, and there is no third
  "suppressed: true" boolean that cannot say which.** An operator reading the
  table can tell a list-hygiene problem from a reputation problem without joining
  anything, and a boolean would make that a question about which row happened to
  be updated last.

  `undeliverable` is a fact about a mailbox (RFC 5321 §5.1.1, permanent failure).
  `suppressed` is an instruction from a person who received the mail and marked it
  as abuse (RFC 2142 §5). Both stop the send; they are kept apart because an
  operator's response to each is different, and because a complaint must never be
  downgraded to a bounce — see `Courier.Suppressions`.

  ## The unique index on `(provider, provider_event_id)` IS the idempotency

  Providers retry. Postmark retries on a timeout and on any 5xx, and a courier
  that is restarting while a batch is in flight will see the same batch again.
  Without a constraint, "the same event twice" is two rows and a state fold that
  counts twice; with one, the duplicate loses at the database and is answered
  from the row that won.

  The pair, not the id alone: a provider's event ids are its own namespace, and
  two providers both saying `"1"` are two facts rather than one retry. This is
  the same lesson as `webhook_deliveries_endpoint_id_event_id_index` and
  `idempotency_keys_account_id_endpoint_key_index` — the key is the tuple that
  the thing is actually unique over.

  ## Why `email` is indexed but not unique

  Two addresses are one address only if they are spelled the same, and courier
  normalises on write (`Courier.Suppressions.normalize/1`) — downcased and
  trimmed. A unique index would then be correct, and it is deliberately **not**
  declared: an address that hard-bounces twice is two real provider reports with
  two real ids, and a unique index on the address would make the second one
  un-recordable. `Courier.Suppressions.find/1` and `state/1` fold over the rows,
  so more than one is the shape the code expects rather than a condition it has to
  tolerate.

  The index is what makes the send path's question cheap, and it is the only one
  on the table for that reason: `suppressed?/1` is on the hot path of every send
  and must not be a sequential scan of a table that grows by one row per bounce.

  ## `email` is stored as given, lowercased

  A `citext` column or a Postgres expression index would push normalisation into
  the database and out of the code, and then the value a test asserts on is a
  value the database rewrote. Lowercasing in the changeset makes the stored bytes
  and the looked-up bytes the same bytes, which is what lets `suppressed?/1` be a
  plain equality and be asserted directly.
  """

  def up do
    # `primary_key: false` because the id is a uuid, not the bigserial Ecto adds
    # by default — the same reason every other table in this repository declares
    # its own, and `Courier.Suppression` declaring `@primary_key {:id, Ecto.UUID}`
    # has to be matched by a column that can actually hold one. Left as the
    # default, the table gets a `bigserial` and every insert fails in the
    # database driver rather than in a review.
    create table(:email_suppressions, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :email, :string, null: false
      add :state, :string, null: false
      add :provider, :string, null: false

      # `provider_event_id`, `reason` and `message_id` are `:text`, and the bound
      # lives in the changeset rather than in a `size:` here. Two reasons, and the
      # second is the one that bites:
      #
      #   1. It matches every other provider-supplied free-text column in this
      #      repository (`webhook_endpoints.url`, `idempotency_keys.endpoint`), so
      #      the bound is defined once and in one place.
      #   2. A bare `:string` is `varchar(255)`. A changeset that validates to 500
      #      against a 255 column compiles, passes every test that does not happen
      #      to write a 300-character reason, and then fails at runtime with
      #      `ERROR 22001 string_data_right_truncation` — a raw Postgrex error
      #      rather than a changeset error, so an HTTP caller gets a 500 instead of
      #      a 422. The two ends of a bound have to agree, and the cheapest way to
      #      keep them agreeing is for only one of them to exist.
      add :provider_event_id, :text, null: false
      add :reason, :text
      add :message_id, :text
      add :occurred_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    # THE IDEMPOTENCY ANCHOR. See the moduledoc: a duplicate delivery loses here
    # rather than in a check somebody has to remember to write.
    create unique_index(:email_suppressions, [:provider, :provider_event_id],
             name: :email_suppressions_provider_idempotency_index
           )

    # For the send path's `suppressed?/1`. The only index on the table besides
    # the uniqueness above, and it earns its place by being on the hot path.
    create index(:email_suppressions, [:email])

    # `state` is an Ecto.Enum resolved in the changeset, not by a database CHECK,
    # so a typo in a migration cannot be introduced and then live forever
    # unnoticed: Ecto's enum cast is the one place that knows the vocabulary, and
    # it is exercised by the suite on every insert.
  end

  def down do
    drop table(:email_suppressions)
  end
end
