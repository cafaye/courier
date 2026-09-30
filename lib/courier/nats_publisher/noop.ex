defmodule Courier.NatsPublisher.Noop do
  @moduledoc """
  The stand-in publisher: it acknowledges every envelope and hands it to the
  process that published it.

  That hand-off is the point. "The relay published this" becomes an assertion
  rather than a hope, which is what lets the relay's tests cover claiming,
  marking, backoff, and failure isolation with no broker, no socket, and no
  waiting. It is configured in `config/test.exs`; the Gnat publisher is a later
  packet and a config change, because this module declares the behaviour the
  Gnat module will declare too.
  """

  @behaviour Courier.NatsPublisher

  @impl Courier.NatsPublisher
  def publish(envelope) do
    send(self(), {:nats_published, envelope})
    :ok
  end
end
