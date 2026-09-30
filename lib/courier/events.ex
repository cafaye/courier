defmodule Courier.Events do
  @moduledoc """
  The event envelope courier emits, and the catalog of the types it may emit.

  The envelope is core's contract, not courier's:
  `cafaye/core`'s `schemas/event-envelope.schema.json` is where the rules live,
  and `Courier.EventsTest` restates them here so drift shows up in courier's own
  suite instead of in core's.

  The catalog is the short list. `types/0` must agree, entry for entry, with
  `exposes.events` in this repository's `cafaye.yml` — the test says so — and
  both are courier's row in `core/docs/event-naming.md`. Registering a new type
  is a checklist in core, not a quiet addition here.

  Every type is **three** segments: `<service>.<entity>.<action>`, so
  `courier.email.delivered` and not `email.delivered`. courier-01/02 shipped the
  two-segment spelling, which core's frozen `eventType` grammar and
  `caf contract lint` both reject — core records the same drift in
  `docs/event-naming.md` §courier. The prefix is the service name, which is also
  the envelope's `source` and the manifest's `name`, so a type says who emitted
  it without a lookup.

  `delivered/1` is the only builder in this packet: courier emits
  `courier.email.delivered` and nothing else yet. The other four catalogued types
  are declared and not yet emitted — a catalog entry is a promise, not a claim.
  """

  @specversion "1.0"
  @source "courier"
  @delivered "courier.email.delivered"

  @types ~w(
    courier.email.queued
    courier.email.delivered
    courier.email.bounced
    courier.email.complained
    courier.notification.suppressed
  )

  @doc """
  Every event type courier is allowed to publish, in the order `cafaye.yml`
  declares them.
  """
  @spec types() :: [String.t()]
  def types, do: @types

  @doc """
  The type of the event courier records for a send — and, by core's rule, the
  NATS subject the row is published on: the `type` is the subject, with no
  mapping table between them.
  """
  @spec delivered_type() :: String.t()
  def delivered_type, do: @delivered

  @doc """
  The `email.delivered` envelope for one send.

  `subject` is the message the send is about — courier's own message id, not the
  user, so two sends to one person are two events about two entities. `data` is
  the send's own fields and nothing else: this envelope goes to every subscriber
  on the bus, and a verification token or an invitation id in there would be a
  credential leak into a fan-out.

  `time` is RFC3339 in UTC to the second: the envelope's timestamp, and a
  consumer that orders by it should not have to care about sub-second precision
  courier never promised.
  """
  @spec delivered(keyword()) :: map()
  def delivered(opts) when is_list(opts) do
    envelope(%{
      id: Ecto.UUID.generate(),
      type: @delivered,
      source: @source,
      subject: Keyword.fetch!(opts, :subject),
      time: DateTime.truncate(DateTime.utc_now(), :second),
      data: Keyword.get(opts, :data, %{})
    })
  end

  @doc """
  The envelope for an emission whose attributes are already known.

  One definition of the seven attributes, so the row `Courier.OutboxEvent`
  records and the message `Courier.Workers.ProcessOutboxWorker` publishes are
  the same shape by construction rather than by two modules agreeing.
  `additionalProperties: false` in core's schema: an extra attribute is a
  validation failure, not an extension point.
  """
  @spec envelope(map()) :: map()
  def envelope(%{id: id, type: type, source: source, subject: subject, time: time, data: data}) do
    %{
      "specversion" => @specversion,
      "id" => id,
      "type" => type,
      "source" => source,
      "subject" => subject,
      "time" => DateTime.to_iso8601(time),
      "data" => data
    }
  end
end
