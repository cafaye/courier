defmodule Courier.NotificationPreference do
  @moduledoc """
  One user's answer about one notification type: is this channel on for this
  person.

  `user_id` is a uuid from identity with no foreign key — courier does not own
  users, and a preference for a user it has never seen is its normal case
  (there is no `users` table here to point at).

  The absence of a row is also an answer: every channel is on unless the user
  turned it off. `Courier.NotificationPreferences.list/1` is what turns that
  default into rows, and it does not write them — a GET must not have a side
  effect.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Courier.Mailers

  @fields ~w(user_id notification_type email_enabled push_enabled)a

  @type t :: %__MODULE__{}

  @doc false
  def fields, do: @fields

  schema "notification_preferences" do
    field :user_id, Ecto.UUID
    field :notification_type, :string
    field :email_enabled, :boolean, default: true
    field :push_enabled, :boolean, default: true

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  The changeset for one entry of a `PUT /v1/notification_preferences` batch.

  `user_id` is set here rather than cast: it comes from the path, not the body,
  and a body that names a different user must not be able to write that user's
  preferences.
  """
  def changeset(preference, attrs) do
    cast(preference, attrs, @fields -- [:user_id])
    |> validate_required([:notification_type])
    |> validate_notification_type()
  end

  defp validate_notification_type(changeset) do
    validate_change(changeset, :notification_type, fn :notification_type, type ->
      if type in Mailers.types(), do: [], else: [notification_type: "is not a notification type"]
    end)
  end
end
