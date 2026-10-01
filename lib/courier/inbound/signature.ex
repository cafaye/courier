defmodule Courier.Inbound.Signature do
  @moduledoc """
  courier as a webhook RECEIVER: is this POST really from the provider?

  `Courier.Webhooks.Verifier` is the same scheme run the other way, and it says
  why it exists: "courier is a *producer* — nothing here receives webhooks." That
  was true when it was written and it stopped being true with this module, because
  the suppression table needs somebody to tell it what happened. The spec makes
  verification and signing two halves of one contract (§Verifying signatures), so
  the consumer half is written here rather than reinvented per provider.

  ## It is the same scheme, and that is the point

  Resend signs with [Svix](https://docs.svix.com), and Svix is the scheme Standard
  Webhooks was standardised from — identical base string, identical algorithm,
  identical secret serialization, identical `v1` prefix, identical space-delimited
  rotation list. So the crypto is not reimplemented. It delegates to
  `Courier.Webhooks.Signature`, and `test/courier/inbound/signature_test.exs`
  asserts that courier's OWN outbound signer produces a signature this accepts, so
  the two halves cannot drift.

  What is not delegated is the header NAMES. Spec §Webhook headers says
  "All of the headers should be prefixed with `webhook-`", and Svix's docs say
  "Professional and Enterprise tier customers can have the headers white-labeled
  to use the `webhook-` prefix instead of the `svix-` prefix used above. The
  Svix libraries support both." Resend sends `svix-` by default. Both are read;
  neither substitutes for the other.

  ## What a verifier has to get right, and why each is a test

  A verifier that is merely correct is not enough, and the reasons are the
  reasons this file is 300 lines rather than 15:

    * **The body is signed as received.** Spec §Signature scheme: the payload
      "sent is the same as the payload signed", and names parse-then-re-serialize
      as "a very common failure mode". This takes the body as a binary and never
      touches it, which is why the caller must pass `conn.body_reader` output and
      not a re-encoded map.
    * **Comparison is constant time.** Spec §Verifying signatures: "Failing to do
      so can expose consumers to timing-attacks and turn them into signing
      oracles." `:crypto.hash_equals/2`, and a test that a PREFIX of a valid
      signature is refused — the bug a `String.starts_with?` would have.
    * **There is a tolerance.** Spec §Verifying signatures requires "some allowable
      tolerance"; the same five minutes `Courier.Webhooks.Verifier` uses, so
      courier's window on inbound and outbound is one number.
    * **A fresh signature is still not "a new event".** The tolerance does NOT
      prevent replay inside the window, and the test says so out loud. Spec
      §Verifying signatures is explicit that the other half is "Use the
      `webhook-id` header as an idempotency key", and in courier that idempotency
      is `email_suppressions_provider_idempotency_index`. The verifier's job ends
      at authenticity; deduplication is the caller's row.
    * **A bad secret is a refusal, not a crash.** `sign_key/2` RAISES on a
      malformed secret, which is correct when a boot reads one and wrong when a
      request does: a route answering 500 to a misconfigured secret is
      indistinguishable from one under attack, and the operator's first question
      would be the wrong one.

  ## Nothing here is a parse, and no parse happens before this returns `:ok`

  `parse/1` lives in each provider and is only reached after this succeeds. An
  unauthenticated body is never decoded, so a malformed or hostile payload cannot
  reach a decoder, an event builder, or the suppression table — see
  `Courier.InboundTest` for the assertion that the parser is never called at all.
  """

  alias Courier.Webhooks.Signature, as: WebhookSignature
  alias Courier.Webhooks.Verifier

  @version "v1"
  @secret_prefix "whsec_"

  # The prefixes Svix uses, in the order they are tried. `:svix` is first because
  # it is what Resend sends; `:webhook` is the spec's spelling, which Svix also
  # emits for white-labelled accounts.
  @prefixes [:svix, :webhook]

  @fields [:id, :timestamp, :signature]

  @doc """
  The replay window, in seconds.

  Read from `Courier.Webhooks.Verifier.tolerance/0` rather than repeated, because
  two numbers in two files is how an inbound window and an outbound window end up
  disagreeing by an order of magnitude with nobody able to say which is the typo.
  """
  @spec tolerance() :: pos_integer()
  def tolerance, do: Verifier.tolerance()

  @doc """
  Verifies `body` against `headers` with `secret`, or says why not.

  `body` must be the bytes as received. `headers` is a map of the three
  `svix-`/`webhook-` headers; header names are matched exactly, because a name in
  another case is not the header (§see moduledoc).

  Returns `:ok`, or `{:error, reason}` where reason is one of:

    * `:invalid_secret` — the secret is unset, unprefixed, or undecodable
    * `{:missing_header, name}` — the full name of an absent header
    * `{:malformed_id}` — the id is empty or contains a full stop
    * `{:malformed_timestamp}` — the timestamp is not a bare integer
    * `:timestamp_out_of_tolerance` — outside the ±`tolerance/0` window
    * `:signature_mismatch` — well-formed, fresh, and not from this provider

  The order is the same as `Courier.Webhooks.Verifier` and deliberate: a caller
  should not learn a signature is wrong before establishing the request is even
  well-formed, and clock skew is a more useful report than a mismatch.
  """
  @spec verify(binary(), map() | keyword(), String.t(), keyword()) :: :ok | {:error, term()}
  def verify(body, headers, secret, opts \\ []) when is_binary(body) do
    # MUTATION-MARKER
    with {:ok, headers} <- normalize(headers),
         {:ok, key} <- fetch_key(secret),
         {:ok, prefix} <- fetch_prefix(headers),
         {:ok, headers} <- fetch_headers(headers, prefix),
         {:ok, id} <- fetch_id(headers, prefix),
         {:ok, timestamp} <- fetch_timestamp(headers, prefix) do
      case check_tolerance(timestamp, opts) do
        :ok -> check_signature(body, headers, prefix, id, timestamp, key)
        {:error, _reason} = error -> error
      end
    end
  end

  # A keyword list is accepted because `Courier.Webhooks.Verifier` accepts one and
  # the two halves should not disagree about what a caller may hand them. Keys are
  # stringified, so `[svix_id: id]` becomes `"svix_id"` and is then correctly
  # reported as a missing `"svix-id"` — an atom key is not the header, and
  # `Plug.Conn.get_req_header/2` hands back strings.
  defp normalize(headers) when is_map(headers), do: {:ok, headers}

  defp normalize(headers) when is_list(headers) do
    if Keyword.keyword?(headers) do
      {:ok, Map.new(headers, fn {key, value} -> {to_string(key), value} end)}
    else
      {:error, :malformed_headers}
    end
  end

  defp normalize(_other), do: {:error, :malformed_headers}

  # The secret is fetched FIRST, before any header is read, and the order is the
  # point. A courier deployed without a signing secret has one problem — its own
  # configuration — and it should be told that about every single request rather
  # than about whichever request happened to omit a header first. Checking the
  # headers first means a misconfigured deployment answers `{:missing_header,
  # "svix-id"}` to an attacker and `:invalid_secret` to a well-formed one, which
  # is both a worse diagnostic and a small oracle for "is this endpoint
  # configured".
  # The prefix is chosen by which headers ARRIVED, not by which arrived completely.
  # A request carrying `svix-id` and `svix-signature` but no `svix-timestamp` is a
  # request about the svix naming with one header missing, and the useful answer
  # is "svix-timestamp is missing" rather than the id — the one it did send. So
  # the first prefix with any of the three wins, and `fetch_headers/2` names what
  # is absent. With none of either prefix present, the default is reported, since
  # Resend's default is the one an operator should be told they are missing.
  defp fetch_prefix(headers) do
    case Enum.find(@prefixes, &has_any_header?(headers, &1)) do
      nil -> {:ok, hd(@prefixes)}
      prefix -> {:ok, prefix}
    end
  end

  defp fetch_key(<<@secret_prefix, encoded::binary>>) when encoded != "" do
    case Base.decode64(encoded) do
      {:ok, key} when byte_size(key) > 0 -> {:ok, key}
      _undecodable -> {:error, :invalid_secret}
    end
  end

  defp fetch_key(_other), do: {:error, :invalid_secret}

  defp has_any_header?(headers, prefix) do
    Enum.any?(@fields, &Map.has_key?(headers, header_name(prefix, &1)))
  end

  defp fetch_headers(headers, prefix) do
    case Enum.reject(@fields, &Map.has_key?(headers, header_name(prefix, &1))) do
      [] -> {:ok, headers}
      [missing | _rest] -> {:error, {:missing_header, header_name(prefix, missing)}}
    end
  end

  # Spec §Signature scheme: "It's important that both the message id and the
  # timestamp not be user controlled, or at the very least not be allowed to
  # include any `.` to prevent certain attacks." A dot in the id lets the id
  # append fields to the base string, and a field appended to a signed string is
  # a field the provider never signed.
  # `"" <> rest` matches the EMPTY string in Elixir, binding `rest` to `""` — so
  # the empty case has to be refused before the full-stop check or an empty id
  # sails through. The pattern is written as a guard rather than as a second
  # clause because a clause below this one is unreachable for `""`.
  defp fetch_id(headers, prefix) do
    case Map.fetch!(headers, header_name(prefix, :id)) do
      id when is_binary(id) and id != "" ->
        if String.contains?(id, "."),
          do: {:error, :malformed_id},
          else: {:ok, id}

      _empty_or_not_a_string ->
        {:error, :malformed_id}
    end
  end

  # `Integer.parse/1` returns the number it managed to read ALONG WITH the rest, so
  # "1731705121x" parses to `1731705121` and a lenient check would accept it. The
  # base string is built from the header's own bytes, so the trailing "x" is part
  # of what was signed and accepting the number would be verifying one string and
  # sending courier to parse another.
  defp fetch_timestamp(headers, prefix) do
    case Map.fetch!(headers, header_name(prefix, :timestamp)) do
      value when is_binary(value) ->
        case Integer.parse(value) do
          {seconds, ""} -> {:ok, seconds}
          _not_a_bare_integer -> {:error, :malformed_timestamp}
        end

      _not_a_string ->
        {:error, :malformed_timestamp}
    end
  end

  defp check_tolerance(timestamp, opts) do
    tolerance = Keyword.get(opts, :tolerance, tolerance())
    now = Keyword.get_lazy(opts, :now, &WebhookSignature.unix_now/0)
    drift = abs(now - timestamp)

    if drift <= tolerance, do: :ok, else: {:error, :timestamp_out_of_tolerance}
  end

  defp check_signature(body, headers, prefix, id, timestamp, key) do
    header = Map.fetch!(headers, header_name(prefix, :signature))
    base_string = WebhookSignature.base_string(id, to_string(timestamp), body)

    if Enum.any?(String.split(header, " ", trim: true), &matches?(&1, base_string, key)) do
      :ok
    else
      {:error, :signature_mismatch}
    end
  end

  # An identifier other than `v1` is SKIPPED rather than rejected, for the reason
  # `Courier.Webhooks.Verifier` gives: the header is a space-delimited list so a
  # provider can sign with a current and a previous key during a rotation, and the
  # list may carry `v1a` entries from a producer that has moved to the asymmetric
  # scheme. Neither may stop the `v1` entry beside it from being found.
  defp matches?(@version <> "," <> received, base_string, key) do
    expected =
      :hmac
      |> :crypto.mac(:sha256, key, base_string)
      |> Base.encode64()

    # Constant time, per spec §Verifying signatures. An `==` here is a timing
    # oracle that turns courier into a signing oracle for whoever is asking.
    #
    # The length guard is what makes that true rather than merely intended:
    # `:crypto.hash_equals/2` RAISES `ArgumentError` when the two binaries differ
    # in size, so calling it unguarded turns "send a 4-character signature" into a
    # 500 — an unauthenticated request that takes down the endpoint, which is
    # the same self-inflicted outage the readiness probe rules out. Returning
    # `false` is also the correct answer: HMAC-SHA256 is 32 bytes, so a signature
    # of any other length cannot be the right one, and the length is public.
    byte_size(received) == byte_size(expected) and :crypto.hash_equals(received, expected)
  end

  defp matches?(_other_identifier, _base_string, _key), do: false

  defp header_name(prefix, field), do: "#{prefix}-#{field}"
end
