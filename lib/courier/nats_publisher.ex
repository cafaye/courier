defmodule Courier.NatsPublisher do
  @moduledoc """
  The behaviour courier's outbox relay publishes through.

  A behaviour rather than a Gnat call, so this packet can be tested end to end
  without a broker and the NATS packet can arrive later without touching
  `Courier.Workers.ProcessOutboxWorker`: it configures
  `config :courier, :nats_publisher` and nothing else.

  A publisher is a module with a `publish/1` that answers `:ok` when the broker
  acknowledged the envelope, or `{:error, reason}` when it did not. The reason is
  what the row's `last_error` records and what the operator reads, so a publisher
  should say what went wrong rather than only that something did.
  """

  @typedoc "A CloudEvents envelope, as `Courier.OutboxEvent.envelope/1` builds it."
  @type envelope :: map()

  @doc """
  Publishes one envelope, or says why it could not.
  """
  @callback publish(envelope()) :: :ok | {:error, term()}

  @doc """
  The publisher the relay talks to.

  Defaults to `Courier.NatsPublisher.Noop` when nothing is configured: a relay
  that crashed mid-run because a config key was missing would turn a missing
  setting into unpublished events, and the stand-in makes the misconfiguration
  visible (nothing arrives) instead of fatal.
  """
  @spec impl() :: module()
  def impl, do: Application.get_env(:courier, :nats_publisher, Courier.NatsPublisher.Noop)
end
