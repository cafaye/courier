defmodule Courier.MailersConfigTest do
  @moduledoc """
  The sender and the subject lines are configuration, so the tests for them
  change configuration.

  `async: false` because `Application.put_env/3` is VM-global: while this
  module is substituting a mailing config, every other test in the suite that
  reads `config :courier, :mailing` would read the substituted one. The env is
  restored in `on_exit`, which runs before the next test starts.
  """

  use ExUnit.Case, async: false

  alias Courier.Mailers

  @payload %{
    user_id: "6f5d4c3b-2a19-4e8f-9c07-1b2d3e4f5061",
    email: "kaka@example.com",
    name: "Kaka"
  }

  setup do
    original = Application.get_env(:courier, :mailing)

    on_exit(fn -> Application.put_env(:courier, :mailing, original) end)

    %{original: original}
  end

  test "the sender and the subject come from configuration" do
    mailing_config(
      from: {"Mailer Test", "mailer-test@cafaye.com"},
      subjects: %{welcome: "Hi %{name}!"}
    )

    assert {:ok, email} = Mailers.build(:welcome, @payload)

    assert email.subject == "Hi Kaka!"
    assert email.from == {"Mailer Test", "mailer-test@cafaye.com"}
  end

  test "a subject template naming a key the payload lacks is a configuration error" do
    mailing_config(subjects: %{welcome: "Welcome to %{team_name}"})

    assert {:error, :subject_misconfigured} = Mailers.build(:welcome, @payload)
  end

  test "a subject missing for a type courier sends is a configuration error" do
    mailing_config(subjects: %{})

    assert {:error, :subject_misconfigured} = Mailers.build(:welcome, @payload)
  end

  test "a from address that is not configured is a configuration error, not a bounce" do
    mailing_config(from: {"", ""})

    assert {:error, :from_not_configured} = Mailers.build(:welcome, @payload)
  end

  defp mailing_config(overrides) do
    Application.put_env(
      :courier,
      :mailing,
      Application.get_env(:courier, :mailing, []) |> Keyword.merge(overrides)
    )
  end
end
