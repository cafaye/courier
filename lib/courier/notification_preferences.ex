defmodule Courier.NotificationPreferences do
  @moduledoc """
  What a user has been asked to receive, per notification type.

  This is courier's one piece of per-user state, and the only thing standing
  between a user and mail they asked not to receive. Two rules make it safe to
  read:

    * **Silence is not consent.** A user courier has never seen, or a type a user
      has never mentioned, is on. courier does not own users, so "no row" is the
      normal case, not an error — `list/1` returns every type, on, for an id it
      has never been asked about.
    * **One type off is not every type off.** Preferences are per type and per
      channel, and `enabled?/3` reads exactly the one it was asked about.

  `push` is stored and returned because the API is the user's settings and a
  half-answer is worse than none, but it is not a delivery decision courier can
  act on: nothing sends push, so `enabled?(user, type, :push)` is always false.

  A rejected batch writes nothing. The entries are validated together before any
  of them is stored, so a typo in the third entry cannot leave the first two
  applied and the user looking at a half-saved settings page.
  """

  import Ecto.Query

  alias Courier.NotificationPreference
  alias Courier.Repo

  @channels [:email_enabled, :push_enabled]

  @doc """
  Every notification type courier sends, in order, with the user's stored
  answers filled in and the defaults used where there are none.

  Never writes: a GET is not a change.
  """
  @spec list(String.t()) :: [NotificationPreference.t()]
  def list(user_id) do
    stored =
      NotificationPreference
      |> where([preference], preference.user_id == ^user_id)
      |> Repo.all()
      |> Map.new(&{&1.notification_type, &1})

    Enum.map(types(), &Map.get_lazy(stored, &1, fn -> default(user_id, &1) end))
  end

  @doc """
  Applies a batch of preferences for one user.

  `params` is the request body: `%{"preferences" => [%{"notification_type" =>
  ..., "email_enabled" => ...}, ...]}`.

  Returns `{:ok, preferences}` — the same shape as `list/1`, so a caller can
  answer a `PUT` with the state the user now has — or `{:error, changeset}`,
  where the errors name the field that failed and, through
  `CourierWeb.NotificationPreferencesController`, the entry of the batch it was
  in. A rejected batch stores nothing.
  """
  @spec update(String.t(), map()) ::
          {:ok, [NotificationPreference.t()]} | {:error, Ecto.Changeset.t()}
  def update(user_id, params) do
    with {:ok, entries} <- entries(params),
         {:ok, changesets} <- validate_all(entries) do
      store_all(user_id, changesets)
      {:ok, list(user_id)}
    end
  end

  @doc """
  Whether one channel is on for one type, for one user.

  `false` for a type courier does not send: courier has no preference to honour
  and nothing to send, so the honest answer is that it is not enabled.
  """
  @spec enabled?(String.t() | nil, String.t(), :email | :push) :: boolean()
  def enabled?(user_id, notification_type, :email) do
    notification_type in types() and stored(user_id, notification_type, :email_enabled)
  end

  def enabled?(_user_id, _notification_type, _channel), do: false

  @doc """
  Every notification type courier sends — the same list `Courier.Mailers` builds
  mail for.
  """
  @spec types() :: [String.t()]
  def types, do: Courier.Mailers.types()

  # An empty list is a request that says nothing about anything, and answering it
  # with the user's current state would read as "here is what you just set". A
  # 422 says what actually happened.
  defp entries(%{"preferences" => []}) do
    {:error, invalid_body("preferences must name at least one preference", "blank")}
  end

  defp entries(%{"preferences" => entries}) when is_list(entries) do
    if Enum.all?(entries, &is_map/1) do
      {:ok, Enum.with_index(entries)}
    else
      {:error, invalid_body("preferences must be a list of preferences", "invalid_type")}
    end
  end

  defp entries(_params) do
    {:error, invalid_body("preferences must be a list of preferences", "invalid_type")}
  end

  defp invalid_body(message, code) do
    {%NotificationPreference{}, %{}}
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.add_error("preferences", message, code: code)
  end

  # Every entry is validated before any of them is stored, and the errors of all
  # of them come back together: a batch that names three bad types should say so
  # once, not one entry per request.
  defp validate_all(entries) do
    changesets = Enum.map(entries, &entry_changeset(elem(&1, 0), elem(&1, 1)))

    if Enum.all?(changesets, & &1.valid?) do
      {:ok, changesets}
    else
      {:error, merge_errors(changesets)}
    end
  end

  defp entry_changeset(entry, index) do
    {known, unknown} = Map.split(entry, Enum.map(NotificationPreference.fields(), &to_string(&1)))

    %NotificationPreference{}
    |> NotificationPreference.changeset(known)
    |> reject_unknown(unknown)
    |> at_index(index)
  end

  # An unknown key in an entry is a typo in a channel courier does not have
  # (`emai_enabled`) or a field it has not grown yet. Silently dropping it would
  # leave the user believing a setting was saved that was not, so it is an error
  # on the key itself.
  #
  # The key stays the string the request used. Making it an atom would mean
  # `String.to_atom/1` on a request body, which is how a caller grows the atom
  # table without bound — and a preference key courier knows nothing about is
  # exactly the input somebody would send a million of.
  defp reject_unknown(changeset, unknown) do
    Enum.reduce(unknown, changeset, fn {key, _value}, acc ->
      Ecto.Changeset.add_error(acc, key, "is not a notification preference",
        code: "unknown_field"
      )
    end)
  end

  # Every error in an entry carries the index of the entry it is in, so
  # `CourierWeb.NotificationPreferencesController` can name the field as the
  # request named it: `preferences[0].notification_type`.
  #
  # The errors are re-added onto the same changeset with its errors cleared
  # first: `Ecto.Changeset.add_error/4` *appends*, so adding to the errors that
  # are already there would report every one of them twice. Clearing first keeps
  # the changes, the types, and the params — the entry has to be storable
  # afterwards — and leaves exactly one error per field.
  defp at_index(changeset, index) do
    Enum.reduce(changeset.errors, %{changeset | errors: [], valid?: true}, fn
      {field, {message, opts}}, acc ->
        Ecto.Changeset.add_error(acc, field, message, Keyword.put_new(opts, :index, index))
    end)
  end

  # All the offending entries' errors in one changeset, so a caller gets one
  # answer. A field that is wrong in two entries is reported once, against the
  # last of them: the caller has to fix that field either way, and the path is
  # what tells them where to look first.
  defp merge_errors(changesets) do
    Enum.reduce(changesets, Ecto.Changeset.change(%NotificationPreference{}), fn changeset, acc ->
      Enum.reduce(changeset.errors, acc, fn {field, {message, opts}}, inner ->
        Ecto.Changeset.add_error(inner, field, message, opts)
      end)
    end)
  end

  # Only the channels the entry actually names are written. An entry that says
  # "welcome is off" and says nothing about push must not turn push back on, and
  # an entry that names no channel at all is a no-op rather than a write.
  defp store_all(user_id, changesets) do
    Enum.each(changesets, fn changeset ->
      replace = Enum.filter(@channels, &Map.has_key?(changeset.params, to_string(&1)))

      %NotificationPreference{}
      |> NotificationPreference.changeset(changeset.params)
      |> Ecto.Changeset.put_change(:user_id, user_id)
      |> Repo.insert(
        on_conflict: conflict(replace),
        conflict_target: [:user_id, :notification_type]
      )
    end)
  end

  defp conflict([]), do: :nothing
  defp conflict(replace), do: {:replace, replace}

  defp stored(user_id, notification_type, field) do
    case Repo.get_by(NotificationPreference,
           user_id: user_id,
           notification_type: notification_type
         ) do
      nil -> true
      preference -> Map.fetch!(preference, field)
    end
  end

  defp default(user_id, notification_type) do
    %NotificationPreference{
      user_id: user_id,
      notification_type: notification_type,
      email_enabled: true,
      push_enabled: true
    }
  end
end
