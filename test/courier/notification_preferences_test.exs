defmodule Courier.NotificationPreferencesTest do
  @moduledoc """
  Notification preferences are courier's one piece of per-user state, and the
  only thing standing between a user and mail they asked not to receive. The
  cases that matter are the boring ones: what a user who has never touched this
  endpoint sees, whether turning something off sticks, and whether turning
  something on for one type quietly turns it on for another.
  """

  use Courier.DataCase, async: true

  alias Courier.NotificationPreferences

  @one "6f5d4c3b-2a19-4e8f-9c07-1b2d3e4f5061"
  @two "7a6e5d4c-3b20-4f90-8d18-2c3e4f506172"
  @types ~w(welcome password_reset team_invitation)

  defp types_of(preferences), do: Enum.map(preferences, & &1.notification_type)

  describe "list/1" do
    test "returns every notification type, on, for a user courier has never seen" do
      assert preferences = NotificationPreferences.list(@one)

      assert types_of(preferences) == @types
      assert Enum.all?(preferences, &(&1.email_enabled and &1.push_enabled))
    end

    test "returns the stored values where there are stored values" do
      {:ok, _} =
        NotificationPreferences.update(@one, %{"preferences" => [pref("welcome", false)]})

      assert [found] =
               NotificationPreferences.list(@one)
               |> Enum.filter(&(&1.notification_type == "welcome"))

      assert found.email_enabled == false
      assert found.push_enabled == true
    end

    test "never shows another user's rows" do
      {:ok, _} =
        NotificationPreferences.update(@one, %{"preferences" => [pref("welcome", false)]})

      refute Enum.any?(NotificationPreferences.list(@two), &(&1.email_enabled == false))
    end

    test "always returns the same types in the same order" do
      {:ok, _} =
        NotificationPreferences.update(@one, %{"preferences" => [pref("team_invitation", false)]})

      assert types_of(NotificationPreferences.list(@one)) == @types

      assert types_of(NotificationPreferences.list(@one)) ==
               types_of(NotificationPreferences.list(@one))
    end
  end

  describe "update/2" do
    test "turns one channel off for one type and leaves everything else on" do
      assert {:ok, preferences} =
               NotificationPreferences.update(@one, %{
                 "preferences" => [pref("password_reset", false)]
               })

      assert types_of(preferences) == @types

      by_type = Map.new(preferences, &{&1.notification_type, &1})
      assert by_type["password_reset"].email_enabled == false
      assert by_type["password_reset"].push_enabled == true
      assert by_type["welcome"].email_enabled == true
      assert by_type["team_invitation"].email_enabled == true
    end

    test "turns email back on" do
      {:ok, _} =
        NotificationPreferences.update(@one, %{"preferences" => [pref("welcome", false)]})

      {:ok, preferences} =
        NotificationPreferences.update(@one, %{"preferences" => [pref("welcome", true)]})

      assert %{email_enabled: true} = Enum.find(preferences, &(&1.notification_type == "welcome"))
    end

    test "push is stored even though nothing sends push yet" do
      {:ok, preferences} =
        NotificationPreferences.update(@one, %{
          "preferences" => [%{"notification_type" => "welcome", "push_enabled" => false}]
        })

      assert %{push_enabled: false} = Enum.find(preferences, &(&1.notification_type == "welcome"))
    end

    test "an entry that names no channel leaves the stored value alone" do
      {:ok, _} =
        NotificationPreferences.update(@one, %{"preferences" => [pref("welcome", false)]})

      {:ok, _} =
        NotificationPreferences.update(@one, %{
          "preferences" => [%{"notification_type" => "welcome"}]
        })

      assert %{notification_type: "welcome", email_enabled: false} =
               NotificationPreferences.list(@one)
               |> Enum.find(&(&1.notification_type == "welcome"))
    end

    test "applying the same update twice is the same state" do
      params = %{"preferences" => [pref("team_invitation", false)]}

      assert {:ok, first} = NotificationPreferences.update(@one, params)
      assert {:ok, second} = NotificationPreferences.update(@one, params)
      assert first == second
    end

    test "one row per user and type, however many times it is applied" do
      for _ <- 1..3 do
        {:ok, _} =
          NotificationPreferences.update(@one, %{"preferences" => [pref("welcome", false)]})
      end

      assert [%{notification_type: "welcome"}] =
               @one
               |> NotificationPreferences.list()
               |> Enum.filter(&(&1.email_enabled == false))
    end

    test "rejects a type courier does not send" do
      assert {:error, changeset} =
               NotificationPreferences.update(@one, %{
                 "preferences" => [
                   %{"notification_type" => "weekly_digest", "email_enabled" => false}
                 ]
               })

      assert %{notification_type: ["is not a notification type"]} = errors_on(changeset)
    end

    test "rejects a channel courier does not have" do
      assert {:error, changeset} =
               NotificationPreferences.update(@one, %{
                 "preferences" => [%{"notification_type" => "welcome", "sms_enabled" => false}]
               })

      assert error_on?(changeset, "sms_enabled")
    end

    test "rejects a body that is not a list of preferences" do
      assert {:error, changeset} = NotificationPreferences.update(@one, %{"preferences" => %{}})
      assert error_on?(changeset, "preferences")

      assert {:error, changeset} = NotificationPreferences.update(@one, %{})
      assert error_on?(changeset, "preferences")
    end

    test "rejects an entry with no notification type" do
      assert {:error, changeset} =
               NotificationPreferences.update(@one, %{
                 "preferences" => [%{"email_enabled" => false}]
               })

      assert %{notification_type: ["can't be blank"]} = errors_on(changeset)
    end

    test "changes nothing when any entry in the batch is rejected" do
      params = %{
        "preferences" => [pref("welcome", false), %{"notification_type" => "nope"}]
      }

      assert {:error, _changeset} = NotificationPreferences.update(@one, params)

      assert Enum.all?(NotificationPreferences.list(@one), & &1.email_enabled)
    end
  end

  describe "enabled?/3" do
    test "email is on for a user who has never been here" do
      assert NotificationPreferences.enabled?(@one, "welcome", :email)
    end

    test "email is off once the user turns it off" do
      {:ok, _} =
        NotificationPreferences.update(@one, %{"preferences" => [pref("welcome", false)]})

      refute NotificationPreferences.enabled?(@one, "welcome", :email)
    end

    test "turning one type off does not silence another" do
      {:ok, _} =
        NotificationPreferences.update(@one, %{"preferences" => [pref("welcome", false)]})

      assert NotificationPreferences.enabled?(@one, "password_reset", :email)
    end

    test "one user's choice does not silence another user" do
      {:ok, _} =
        NotificationPreferences.update(@one, %{"preferences" => [pref("welcome", false)]})

      assert NotificationPreferences.enabled?(@two, "welcome", :email)
    end

    test "a type courier does not send is never enabled" do
      refute NotificationPreferences.enabled?(@one, "weekly_digest", :email)
    end

    test "push is a stored answer, not a delivery decision courier can act on" do
      {:ok, _} =
        NotificationPreferences.update(@one, %{
          "preferences" => [%{"notification_type" => "welcome", "push_enabled" => false}]
        })

      refute NotificationPreferences.enabled?(@one, "welcome", :push)
    end
  end

  defp pref(type, email_enabled),
    do: %{"notification_type" => type, "email_enabled" => email_enabled}

  # An error on a field courier does not have a column for is keyed by the string
  # the request used, so `Keyword.keys/1` — which raises on a string key — cannot
  # be used to look at them. Making those keys atoms would mean `String.to_atom/1`
  # on a request body, which grows the atom table without bound.
  defp error_on?(changeset, field) do
    Enum.any?(changeset.errors, fn {key, _error} -> key == field end)
  end
end
