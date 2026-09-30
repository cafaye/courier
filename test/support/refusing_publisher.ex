defmodule Courier.TestSupport.RefusingPublisher do
  @moduledoc """
  A NATS publisher that refuses every envelope, standing in for a broker that is
  down or a subject nobody is subscribed to.

  Used by the relay's failure tests to prove the row is not marked published.
  """

  @behaviour Courier.NatsPublisher

  @impl Courier.NatsPublisher
  def publish(_envelope), do: {:error, :nats_unavailable}
end
