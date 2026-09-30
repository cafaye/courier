defmodule Courier.Repo.Migrations.CreateOutboxEvents do
  use Ecto.Migration

  @moduledoc """
  courier's outbox: one row per emission, written in the same transaction as
  the send that caused it, and moved to NATS by
  `Courier.Workers.ProcessOutboxWorker`.

  The shape is core's — see `core/docs/event-outbox.md` — and the correspondence
  with core's table is one to one:

  | core            | courier         |
  | --------------- | --------------- |
  | `id`            | `id`            |
  | `event_type`    | `type`          |
  | `source`        | `source`        |
  | `subject`       | `subject`       |
  | `time`          | `occurred_at`   |
  | `data`          | `data`          |
  | `created_at`    | `inserted_at`   |
  | `published_at`  | `published_at`  |
  | `attempts`      | `attempt_count` |

  The names differ so the schema reads like Elixir (`type` rather than
  `event_type`, which is Ecto's own vocabulary) — what the rest of the platform
  depends on is the *shape*: one row per emission with the envelope `id`
  generated before the insert, `published_at` as the only definition of
  published, and `attempt_count` as the backoff input and the alert signal.

  `last_error` is courier's addition to core's table: a refused publish records
  why, so a row that has been refused often enough can be read in one query
  instead of reconstructed from Oban's job history.

  `data` is `jsonb` and not `json` for core's reason: it is parsed, so a contract
  test or a query can reach inside the payload.
  """

  def change do
    # `primary_key: false` because the id is the envelope's id, a uuid generated
    # before the insert — not the bigserial Ecto would add by default.
    create table(:outbox_events, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :type, :string, null: false
      add :source, :string, null: false
      add :subject, :string, null: false
      add :occurred_at, :utc_datetime_usec, null: false
      add :data, :map, null: false
      add :published_at, :utc_datetime_usec
      add :attempt_count, :integer, null: false, default: 0
      add :last_error, :string

      timestamps(type: :utc_datetime_usec)
    end

    # The relay's only query. Without this it is a sequential scan of every
    # event courier has ever published, forever, and the partial predicate keeps
    # the index to the rows that still need work.
    create index(:outbox_events, [:occurred_at],
             where: "published_at IS NULL",
             name: :outbox_events_unpublished_idx
           )
  end
end
