defmodule Courier.ErrorRelay.Sink do
  @moduledoc """
  Where a redacted envelope goes, and how one is framed.

  ## The behaviour is one function on purpose

  A sink takes **bytes** and returns `:ok | {:error, reason}`. It does not know
  about redaction, about fingerprints, or about the throttle, and it cannot
  redact: the whole claim of this packet is that the redaction happens in
  `Courier.ErrorRelay.Policy` at one chokepoint, and a sink that could reach an
  unredacted event would make that claim a matter of which implementation is
  configured.

  Three implementations ship:

    * `Courier.ErrorRelay.Sink.Req` — POSTs to GlitchTip. The shipped one.
    * `Courier.ErrorRelay.Sink.Noop` — discards. What a deployment with no
      sink DSN gets, so "the relay is on and there is nowhere to send" is a
      configuration that runs and says so rather than a boot failure.
    * `Courier.TestSupport.RecordingSink` — hands the bytes to a test.

  ## The envelope format, and why the relay re-frames rather than forwards

  A Sentry envelope is newline-delimited: one JSON **header** object, then a
  sequence of items, each an item-header JSON object on its own line followed by
  exactly `length` bytes of payload. It is not a JSON document and it is not
  `multipart/form-data`; a relay that treated it as either would parse
  something.

  The relay **rebuilds** the envelope rather than editing bytes in place, for
  three reasons that all come from the same place:

    1. The payload of an `event` item has to be decoded, redacted and re-encoded.
    2. Items that are not events — `session`, `transaction` — are dropped, and
       dropping an item from a length-prefixed stream means re-writing every
       subsequent length.
    3. The header's `dsn` is **replaced with the sink's DSN**. The DSN an SDK
       holds is the relay's, and the relay is not GlitchTip; forwarding it would
       either confuse the store or, in a configuration where a service is
       pointed straight at GlitchTip, mean a service's DSN is a GlitchTip
       credential. Rewriting it here is what makes "the SDKs only ever know the
       relay" true at the byte level.

  Every function here refuses rather than raises, for the reason that recurs
  through this module: the input is bytes off a socket that courier did not
  write, and a crash in the error path is the failure this packet exists to
  prevent.
  """

  @typedoc "A Sentry envelope item: its item-header plus the raw payload bytes."
  @type item :: %{optional(String.t()) => term()}

  @doc "Ship one envelope. `:ok`, or `{:error, reason}`. Never raises."
  @callback forward(binary(), keyword()) :: :ok | {:error, term()}

  @doc """
  Parse a Sentry envelope into its items.

  `{:ok, [%{"type" => ..., "payload" => binary}, ...]}` or
  `{:error, reason}`. The payload is returned as **bytes** rather than decoded,
  because an item's payload type is the item's business: an `event` item is JSON
  and a `attachment` item is not, and a reader that decoded everything would
  reject an envelope for containing an attachment.
  """
  @spec parse_envelope(binary()) :: {:ok, [item()]} | {:error, term()}
  def parse_envelope(binary) when is_binary(binary) do
    with {:ok, _header, rest} <- take_line(binary),
         {:ok, items} <- take_items(rest, []) do
      {:ok, Enum.reverse(items)}
    end
  end

  def parse_envelope(_other), do: {:error, :not_bytes}

  @doc """
  Build a Sentry envelope from items, with `dsn` as the header's DSN.

  `items` are `[%{"type" => binary, "payload" => binary}]` — **already-redacted
  payload bytes**. There is no path through this function that takes an
  unredacted event, and that is the point: the framing layer cannot be the thing
  that forgot.
  """
  @spec build_envelope([item()], String.t() | nil) :: {:ok, binary()} | {:error, term()}
  def build_envelope(items, dsn \\ nil)

  def build_envelope(items, dsn) when is_list(items) do
    header =
      %{
        "event_id" => fresh_event_id(),
        "sent_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> to_iso8601()
      }
      |> maybe_put_dsn(dsn)

    with {:ok, header_json} <- encode(header) do
      body =
        Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
          with {:ok, payload} <- payload_bytes(item),
               {:ok, item_json} <-
                 encode(%{"type" => item["type"], "length" => byte_size(payload)}) do
            {:cont, {:ok, [item_json, "\n", payload, "\n" | acc]}}
          else
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      with {:ok, parts} <- body, do: {:ok, IO.iodata_to_binary([header_json, "\n" | parts])}
    end
  end

  def build_envelope(_other, _dsn), do: {:error, :not_a_list}

  # --- the header ------------------------------------------------------------

  # The DSN goes in the header, which is where a Sentry envelope carries it. The
  # `event_id` is **not** set here — it is a fresh random one per envelope, from
  # `fresh_event_id/0`, and the reason is the single most expensive bug in this
  # module's history:
  #
  # It used to be the literal `"00000000000000000000000000000000"`, on the reading
  # that the envelope spec asks for all-zero hex when no id is known. It does, and
  # that is the problem. GlitchTip's ingest path falls back to the **header's** id
  # when an event payload carries none of its own
  # (`apps/event_ingest/views.py`: `if item.event_id is None: item.event_id =
  # envelope_header_event_id or uuid.uuid4()`) and then dedupes on
  # `cache.aadd("uuid" + item.event_id.hex)`. Every event courier forwarded that
  # lacked its own id therefore shared one dedupe key, and **only the first was
  # stored**.
  #
  # Nothing in courier could see it. The relay counted each one as `forwarded`, the
  # store answered `200`, the sender saw no failure, and the store held one event
  # where there should have been hundreds. It is found by counting rows in
  # GlitchTip's database after posting the same crash repeatedly — which is the
  # only observation in the whole system that distinguishes "stored" from "accepted".
  #
  # A random id is right rather than merely different: the header is a *fallback*
  # for an id the relay does not have, and two envelopes must never share one. An
  # SDK's own `event_id` still wins — it travels in the payload, which
  # `Courier.ErrorRelay.Policy` keeps — so this does not disturb the id a reporter
  # knows its error by.
  defp maybe_put_dsn(header, nil), do: header

  defp maybe_put_dsn(header, dsn), do: Map.put(header, "dsn", dsn)

  # 32 lowercase hex characters, which is the envelope spec's shape for an
  # envelope id and what GlitchTip's `UUID` parser accepts. `:crypto.strong_rand_bytes/1`
  # rather than `System.unique_integer/1`: this value ends up in a dedupe key in
  # somebody else's database, and a monotonic counter is guessable in a way that
  # makes "here are your neighbours' event ids" a free answer.
  defp fresh_event_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  defp payload_bytes(%{"payload" => payload}) when is_binary(payload), do: {:ok, payload}

  defp payload_bytes(%{"payload" => payload}) when is_map(payload) or is_list(payload) do
    encode(payload)
  end

  defp payload_bytes(_other), do: {:error, :no_payload}

  defp encode(term) do
    case Jason.encode(term) do
      {:ok, json} -> {:ok, json}
      {:error, _reason} -> {:error, :unencodable}
    end
  end

  defp to_iso8601(datetime), do: DateTime.to_iso8601(datetime)

  # --- the items -------------------------------------------------------------

  # Each item is an item-header line, then `length` bytes, then the newline the
  # spec puts after the payload. `length` is read from the item header when
  # present and falls back to "up to the next newline" when it is not, because a
  # self-hoster's SDK configuration can turn it off and an envelope that is
  # otherwise fine should not be discarded for that.
  # `take_line/1` cannot fail: every binary is either newline-terminated or it
  # is the last line, and both are answers. The failure this function has to
  # handle is a line that is not an item header, and a payload that is shorter
  # than its own header claims — the two ways a Sentry SDK's framing can be
  # wrong without the bytes being obviously not-an-envelope.
  defp take_items(binary, acc) do
    case take_line(binary) do
      {:ok, "", _rest} ->
        {:ok, acc}

      {:ok, line, rest} ->
        with {:ok, header} <- decode(line),
             {:ok, payload, rest} <- take_payload(header, rest) do
          take_items(rest, [Map.put(header, "payload", payload) | acc])
        else
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp take_payload(%{"length" => declared} = _header, rest)
       when is_integer(declared) and declared >= 0 do
    # The declared length is matched *in the same expression* as the slice that
    # uses it, which is the only form the compiler will check: a bitstring
    # `size` cannot read a variable bound in the function head, so the naive
    # version compiles with a warning and no guarantee that the number in the
    # guard is the number in the pattern.
    #
    # Two accepted shapes, and the second is a real one: the spec puts a newline
    # after every payload, but a sender that omits the final one has still sent
    # a complete envelope, and rejecting it would lose the last event of every
    # batch from a self-hoster's SDK.
    #
    # `case` rather than `if` so the "not enough bytes" branch is the *shape* of
    # the failure rather than a length comparison written twice.
    # `binary_part/3` rather than a bitstring match, and the reason is worth
    # writing down because the bitstring form is the obvious one and it cannot
    # be written: a size bound inside `<<…>>` is a **fresh** variable, so it
    # cannot be compared in the same guard against `declared` from the enclosing
    # scope, and Elixir rejects the guard as an undefined variable. Three
    # attempts at that shape failed to compile before this one.
    #
    # So: the length is checked against what actually arrived, and the slice
    # uses the same expression for the bound. `declared` is caller-supplied and
    # is a **guard**, so a negative or absurd value cannot reach `binary_part/3`
    # and produce a negative-size crash — the `is_integer`/`>= 0` clause above
    # is what guarantees that, which is why it is a clause head and not a check
    # inside this body.
    if byte_size(rest) >= declared + 1 do
      # The byte at `declared` must be the newline the framing promises. It is
      # **checked** rather than pattern-matched, and that is the fix for a `500` on
      # the error path: a header that declares fewer bytes than the payload really
      # has lands the slice in the middle of the payload, so the pattern
      # `<<"\n"::binary, tail::binary>>` found a `"` where a newline should be and
      # raised `MatchError` out of `parse_envelope/1`, through the controller, and
      # onto the wire as a 500. A Sentry SDK retries every non-2xx, so a bad length
      # became a retry storm in whichever service miscounted.
      #
      # Found by POSTing a hand-written envelope at the running compose stack — the
      # parser's other callers all build their framing with `build_envelope/2` and so
      # agreed with it by construction. `CourierWeb.ErrorRelayEndpointTest` now
      # holds both the correct hand-written framing and this miscounted one.
      case :binary.at(rest, declared) do
        ?\n ->
          tail = :binary.part(rest, declared + 1, byte_size(rest) - declared - 1)
          {:ok, :binary.part(rest, 0, declared), tail}

        _not_a_newline ->
          {:error, :misframed}
      end
    else
      if byte_size(rest) == declared do
        # The spec puts a newline after every payload, but a sender that omits
        # the final one has still sent a complete envelope. Rejecting it would
        # lose the last event of every batch from a self-hoster's SDK.
        {:ok, rest, ""}
      else
        # A header that claims more bytes than arrived means a truncated body,
        # and a truncated body is not an envelope worth forwarding: the payload
        # is half an event and the store would group it with something real.
        # The declared length is deliberately not echoed — it is caller-supplied
        # and this is a log line.
        {:error, :truncated}
      end
    end
  end

  defp take_payload(_header, rest) do
    case :binary.split(rest, "\n") do
      [payload, tail] -> {:ok, payload, tail}
      [_payload] -> {:ok, rest, ""}
    end
  end

  defp take_line(binary) do
    case :binary.split(binary, "\n") do
      [line, rest] -> {:ok, line, rest}
      [_line] -> {:ok, binary, ""}
    end
  end

  defp decode(line) do
    case Jason.decode(line) do
      {:ok, term} when is_map(term) -> {:ok, term}
      _other -> {:error, :undecodable_item_header}
    end
  end
end
