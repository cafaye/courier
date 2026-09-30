defmodule CourierWeb.NotificationPreferencesController do
  @moduledoc """
  The JSON API over notification preferences:
  `GET` and `PUT /v1/notification_preferences/:user_id`.

  Two things are worth saying about the semantics, because both look like
  omissions and are not:

    * **An unknown user is a 200, not a 404.** identity owns the user table.
      courier is asked about a user id and answers with that user's preferences,
      which for a user who has never touched the settings is three types, all on.
      A 404 would be courier claiming to know something about the requester it
      does not know.
    * **A user id that is not a uuid is a 422 before the body is looked at.** It
      is the one thing courier can check about the request without consulting
      anybody, and there is no point validating a body for a user courier cannot
      address.

  Every error is core's problem+json (`CourierWeb.Problem`), with the field named
  as the *request* named it — `preferences[0].notification_type` — because the
  body is what the caller can fix.

  These requests are not authenticated in this packet: there is no JWT
  verification here yet, so what the tests cover is shape and semantics, not who
  is allowed to ask.
  """

  use CourierWeb, :controller

  alias Courier.NotificationPreferences
  alias CourierWeb.Problem

  @doc """
  Every notification type courier sends, with this user's stored answers.
  """
  def show(conn, %{"user_id" => user_id}) do
    case cast_user_id(user_id) do
      {:ok, user_id} -> json(conn, preferences(user_id, NotificationPreferences.list(user_id)))
      :error -> invalid_user_id(conn)
    end
  end

  @doc """
  Applies a batch of preferences and answers with the state the user now has.
  """
  def update(conn, %{"user_id" => user_id} = params) do
    case cast_user_id(user_id) do
      {:ok, user_id} -> store(conn, user_id, params)
      :error -> invalid_user_id(conn)
    end
  end

  defp store(conn, user_id, params) do
    case NotificationPreferences.update(user_id, params) do
      {:ok, stored} ->
        json(conn, preferences(user_id, stored))

      {:error, changeset} ->
        Problem.send(conn, 422, :validation_failed, detail(changeset), failed(changeset))
    end
  end

  defp preferences(user_id, preferences) do
    %{
      data: %{
        user_id: user_id,
        preferences: Enum.map(preferences, &preference/1)
      }
    }
  end

  # The three fields the API promises. `user_id` is in the path and answered at
  # the top of the body, and `id` is courier's row id, which the caller has no
  # use for.
  defp preference(preference) do
    %{
      notification_type: preference.notification_type,
      email_enabled: preference.email_enabled,
      push_enabled: preference.push_enabled
    }
  end

  defp cast_user_id(user_id) do
    case Ecto.UUID.cast(user_id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> :error
    end
  end

  defp invalid_user_id(conn) do
    Problem.send(conn, 422, :validation_failed, "The user id is not a uuid.", [
      %{"field" => "user_id", "code" => "invalid_format"}
    ])
  end

  # A changeset error is keyed by the field it is about and carries the index of
  # the entry it is in, which is how `preferences[0].notification_type` comes out
  # of a context that only knows about preference entries.
  defp failed(changeset) do
    Enum.map(changeset.errors, fn {field, {_message, opts}} ->
      %{"field" => field_path(field, opts), "code" => Keyword.get(opts, :code, "invalid_format")}
    end)
  end

  defp field_path(field, opts) do
    case Keyword.get(opts, :index) do
      nil -> to_string(field)
      index -> "preferences[#{index}].#{field}"
    end
  end

  defp detail(changeset) do
    "The preferences were not valid: " <>
      Enum.map_join(changeset.errors, ", ", fn {field, {message, _opts}} ->
        "#{field} #{message}"
      end)
  end
end
