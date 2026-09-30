defmodule Courier.Repo.Migrations.CreateNotificationPreferences do
  use Ecto.Migration

  @moduledoc """
  One row per (user, notification type): the answer a user has given about a
  channel, or the absence of an answer, which means the default.

  `user_id` is a uuid from identity, not a foreign key. courier does not own
  users, so it cannot enforce that the user exists — a preference for an id it
  has never seen is courier's normal case, not an error (see
  `Courier.NotificationPreferences.list/1`).

  Defaults are all-on: a user who has never opened the settings page has not
  opted out of anything, and courier must not mistake silence for consent to
  stop mailing them.
  """

  def change do
    create table(:notification_preferences) do
      add :user_id, :uuid, null: false
      add :notification_type, :string, null: false
      add :email_enabled, :boolean, null: false, default: true
      add :push_enabled, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    # One row per user and type, however many times the same update is applied:
    # the uniqueness is what makes `PUT /v1/notification_preferences/:user_id`
    # idempotent instead of appending a second opinion.
    create unique_index(:notification_preferences, [:user_id, :notification_type])
  end
end
