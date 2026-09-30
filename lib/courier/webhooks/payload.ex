defmodule Courier.Webhooks.Payload do
  @moduledoc """
  The bytes courier signs and sends.

  Two rules from the spec drive this module, and both are about the *same* thing:

    * **§Payload**: the body goes in the HTTP body, JSON, with a `type` that
      indicates the schema and a `timestamp` of when the event occurred. For a
      real event courier sends the CloudEvents envelope unmodified — it is
      already `type` / `time` / `data`, and a consumer subscribed to courier's
      events on the bus gets the identical document over HTTP. One contract, not
      two, and nothing to keep in step.
    * **§Signature scheme**: "it's important to make sure that the payload sent
      is the same as the payload signed ... even a stray space can cause the
      signature to be invalid." So `body/1` encodes once and hands back that
      exact binary; the caller signs those bytes and sends those bytes, and
      nothing in between re-encodes them.

  The spec is also explicit that the payload's `timestamp` is the time of the
  *event*, not the time of the attempt, while the `webhook-timestamp` header
  carries the attempt. Both are present and they are different fields on purpose:
  a consumer retrying a failed delivery sees a fresh header and the original
  event time, exactly as §Webhook metadata describes.
  """

  alias Courier.OutboxEvent

  @doc """
  The request body for one event: its CloudEvents envelope, minified.
  """
  @spec body(OutboxEvent.t()) :: binary()
  def body(%OutboxEvent{} = event), do: Jason.encode!(OutboxEvent.envelope(event))

  @doc """
  The body for a `POST /v1/webhook_endpoints/:id/test`.

  A `ping`, not an event. The spec §Payload describes `type` / `timestamp` /
  `data`, and a ping fills all three, but it carries no envelope `id` and no
  `source`: it is courier checking that an endpoint works, and a consumer that
  treated it as a real event would be acting on something that is not one. The
  `webhook_id` is in the body instead, purely so someone reading a log of what
  arrived can match it to the request courier signed.
  """
  @spec ping(String.t(), String.t()) :: binary()
  def ping(webhook_id, url) do
    Jason.encode!(%{
      "type" => "ping",
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "data" => %{"url" => url},
      "webhook_id" => webhook_id
    })
  end
end
