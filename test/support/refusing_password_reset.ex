defmodule Courier.TestSupport.RefusingPasswordReset do
  @moduledoc """
  A NATS publisher that refuses one notification type and accepts the rest,
  handing the accepted envelope to the publishing process like the stand-in does.

  One refusing row in a batch is the case that decides whether the relay isolates
  failures or lets one bad message hold up every message behind it, and a
  publisher that refuses everything cannot show the difference.
  """

  @behaviour Courier.NatsPublisher

  @impl Courier.NatsPublisher
  def publish(%{"data" => %{"notification_type" => "password_reset"}}),
    do: {:error, :nats_unavailable}

  def publish(envelope) do
    send(self(), {:nats_published, envelope})
    :ok
  end
end
