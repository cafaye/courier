defmodule Courier.TestSupport.FailingAdapter do
  @moduledoc """
  A Swoosh adapter that refuses every message.

  It exists so "the provider said no" can be tested through the real Swoosh path:
  the Test adapter always succeeds, so a test that wants a failed send has to
  substitute something that fails. Used by `Courier.DeliverAdapterTest`, which
  owns the config swap and therefore the `async: false`.
  """

  use Swoosh.Adapter, validate_config: false

  @impl Swoosh.Adapter
  def deliver(_email, _config), do: {:error, :provider_unavailable}

  @impl Swoosh.Adapter
  def deliver_many(emails, config), do: Enum.map(emails, &deliver(&1, config))
end
