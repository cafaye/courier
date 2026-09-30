defmodule Courier.EventsTest do
  @moduledoc """
  The envelope is core's contract, not courier's: `cafaye/core`'s
  `schemas/event-envelope.schema.json` is where these rules live, and core's
  suite is what ultimately validates courier's output against it.

  This file restates the schema's constraints as assertions, so that drift shows
  up in courier's own suite instead of in core's. The patterns are transcribed
  from that schema — they are the contract, not courier's opinion of it. A new
  event type is not something courier gets to invent quietly: registering one is
  a checklist in core's docs/event-naming.md, and the catalog test below is the
  reminder that the list of types courier may emit is shorter than the list of
  types one could imagine.
  """

  use ExUnit.Case, async: true

  alias Courier.Events

  # schemas/event-envelope.schema.json: $defs.eventType
  @event_type ~r/^[a-z][a-z0-9]*(_[a-z0-9]+)*(\.[a-z][a-z0-9]*(_[a-z0-9]+)*){1,2}$/

  # schemas/event-envelope.schema.json: $defs.serviceName
  @service_name ~r/^[a-z][a-z0-9]*(-[a-z0-9]+)*$/

  # schemas/event-envelope.schema.json: properties.subject
  @subject ~r{^[A-Za-z0-9][A-Za-z0-9._:@/-]*$}

  @subject_id "courier-6f5d4c3b-2a19-4e8f-9c07-1b2d3e4f5061"

  @data %{
    "message_id" => @subject_id,
    "user_id" => "6f5d4c3b-2a19-4e8f-9c07-1b2d3e4f5061",
    "notification_type" => "welcome",
    "email" => "kaka@example.com",
    "provider_id" => nil
  }

  describe "delivered/1" do
    test "names a type courier is allowed to publish" do
      assert Events.delivered(subject: @subject_id, data: %{})["type"] in Events.types()
    end

    test "the catalog is exactly the events in courier's cafaye.yml" do
      # cafaye.yml `exposes.events` and core's docs/event-naming.md catalog are
      # asserted to agree by core's own suite. If `Courier.Events` gains a type,
      # one of those two needs the same row in the same commit.
      assert Events.types() == manifest_events()
    end

    test "carries every required attribute and nothing else" do
      # `additionalProperties: false` in the schema: an extra attribute is a
      # validation failure, not an extension point. `specversion` is one of the
      # seven — the schema's `required` list — and the next test says so; it is
      # spelled out here because the point of this test is the closed set, and a
      # closed set that quietly omits a required member is not closed.
      envelope = Events.delivered(subject: @subject_id, data: %{})

      assert envelope |> Map.keys() |> Enum.sort() ==
               ~w(data id source specversion subject time type)
    end

    test "pins the dialect version" do
      assert Events.delivered(subject: @subject_id, data: %{})["specversion"] == "1.0"
    end

    test "the id is a uuid, unique per emission" do
      one = Events.delivered(subject: @subject_id, data: %{})
      two = Events.delivered(subject: @subject_id, data: %{})

      assert {:ok, _uuid} = Ecto.UUID.cast(one["id"])
      refute one["id"] == two["id"]
    end

    test "the source is courier, which is `name` in courier's cafaye.yml" do
      assert Events.delivered(subject: @subject_id, data: %{})["source"] == "courier"
    end

    test "the time is RFC3339 in UTC, to the second" do
      assert %{"time" => time} = Events.delivered(subject: @subject_id, data: %{})

      assert String.ends_with?(time, "Z")

      # The third element is the parsed utc_offset (`0`), which `from_iso8601/1`
      # has returned alongside the DateTime since Elixir 1.4.
      assert {:ok, %DateTime{time_zone: "Etc/UTC", microsecond: {0, 0}}, 0} =
               DateTime.from_iso8601(time)
    end

    test "the subject is the entity the event is about, and matches the schema's pattern" do
      assert %{"subject" => subject} = Events.delivered(subject: @subject_id, data: %{})

      assert subject =~ @subject
    end

    test "the data is the publisher's payload, untouched" do
      assert Events.delivered(subject: @subject_id, data: @data)["data"] == @data
    end
  end

  describe "conformance" do
    test "the envelope a real delivery produces satisfies every schema constraint" do
      envelope = Events.delivered(subject: @subject_id, data: @data)

      assert envelope["specversion"] == "1.0"
      assert envelope["type"] =~ @event_type
      assert envelope["source"] =~ @service_name
      assert envelope["subject"] =~ @subject
      assert {:ok, _uuid} = Ecto.UUID.cast(envelope["id"])
      assert {:ok, _time, _offset} = DateTime.from_iso8601(envelope["time"])
      assert is_map(envelope["data"])
    end
  end

  # cafaye.yml is the service's own statement of what it publishes, and
  # `Courier.Events` is the same list in Elixir. Parsing YAML is not worth a
  # dependency to check a list of five plain strings, so this reads the block
  # directly: the `events:` key at two spaces, its list items at four.
  defp manifest_events do
    lines = File.read!(Path.join(File.cwd!(), "cafaye.yml")) |> String.split("\n")

    case Enum.find_index(lines, &(&1 =~ ~r/^\s{2}events:/)) do
      nil ->
        flunk(
          "cafaye.yml no longer declares `exposes.events`; `Courier.Events` cannot be checked against it"
        )

      index ->
        lines
        |> Enum.drop(index + 1)
        |> Enum.take_while(&(&1 =~ ~r/^\s{4}- /))
        |> Enum.map(&(&1 |> String.trim() |> String.trim_leading("- ") |> String.trim()))
    end
  end
end
