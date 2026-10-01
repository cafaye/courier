defmodule CourierWeb.InboundController do
  @moduledoc """
  `POST /inbound/resend` — the surface `Courier.Suppressions.ingest/1` was written
  for and had no caller.

  ## Why this route exists at all

  `Courier.Suppressions.ingest/1` was written, tested, and documented as "the HTTP
  surface's entry point" — and nothing called it. The suppression table was
  therefore written by nothing but tests, permanently empty in production, and a
  customer whose address hard-bounced went on being mailed forever. That is how a
  sending domain's reputation dies, killed by the list meant to prevent it. This
  controller is the missing caller.

  ## Three steps, in this order, and the order is the property

      1. Courier.Inbound.Signature   is this POST really from the provider?
      2. Courier.Inbound.Resend      what does this provider's JSON mean?
      3. Courier.InboundReports      what does courier do about it?

  Step 1 does not return `:ok` until the signature matches, and step 2 is only
  reached then. **An unauthenticated body never reaches a decoder**: not
  `Courier.Inbound.Resend`, and not `Plug.Parsers` either, which is an endpoint
  plug and would otherwise have decoded every body on this route before the
  signature was checked. `CourierWeb.Plugs.ParseBody` skips the paths
  `CourierWeb.Router.signed_body_paths/0` names for exactly that reason.

  The obvious way to write this action is `Courier.Inbound.handle/5`, and it is
  the right function for a caller with no HTTP surface. This one is not that
  caller: a route has to answer **three different statuses for the three
  refusals** — an unauthenticated request is a 401, a payload courier cannot
  classify is a 422, and courier's own misconfiguration is a 500 — and `handle/5`
  returns one `{:error, reason}` for all of them. The two steps are therefore
  called here, in the order `handle/5` documents, so the route can tell them
  apart without pattern-matching on a private reason list.

  ## The statuses, and what a provider should do about each

  | outcome | status | `code` | the provider should |
  | --- | --- | --- | --- |
  | verified, and courier acted | 200 | — | stop |
  | verified, and this report is a repeat | 200 | — (`duplicates`) | stop |
  | the signature did not verify | 401 | `unauthorized` | **stop** — a retry with the same bytes fails again |
  | the body is not JSON | 400 | `bad_request` | stop |
  | courier cannot classify the report | 422 | `validation_failed` | stop, and read `errors[]` |
  | courier has no signing secret configured | 500 | `internal` | retry — this one is courier's |

  **An unauthenticated request is a 401 and not a 400**, even when the body is
  also malformed. A 400 is core's status for "malformed syntax the client could
  not have known", and this provider's syntax is not something the sender chooses
  — and answering 400 for a forged body would tell whoever is forging them that
  courier decoded it. Verification comes first, so an unsigned malformed body is
  the same 401 as an unsigned valid one.

  **A report courier cannot classify is a 422 and not a 200.** A 200 would be
  courier claiming it did something with a report it could not read, which is the
  silence `Courier.Inbound.Resend`'s moduledoc refuses. A 422 tells the provider
  courier understood the request and will not act on it, and `errors[]` names the
  field — the one place a provider can read that without parsing prose.

  **`:invalid_secret` is a 500 and not a 401**, and this is the one that reads
  like a detail. `Courier.Inbound.Signature`'s moduledoc raises the objection
  directly: a route answering 500 to a misconfigured secret is indistinguishable
  from one under attack, "and the operator's first question would be the wrong
  one". So the two are told apart by status. A secret courier does not have is
  courier's own defect, it is logged with the variable to set, and the 401 stays
  available for the case it is actually for. `config/runtime.exs` refuses to boot
  a production courier without it, so this is a deployment that went wrong after
  boot rather than one that got that far.

  ## Nothing in a response is about a mailbox

  Neither the counts nor any refusal carries an address, and the reason is
  `POST /v1/messages`'s: `email_suppressions` has no `account_id`, so a response
  quoting an address is a way to ask courier questions about mailboxes it holds,
  and the table is not exposed through any route at all. The one place a
  suppressed address may appear is courier's own logs, which is why the log lines
  here name the value `Courier.Inbound.Resend` put in the refusal.

  ## Why there is no `Idempotency-Key` here

  A provider retries a webhook it did not get an answer for, and that is normal
  rather than an error. The deduplication that answers it is
  `email_suppressions`'s unique index on `(provider, provider_event_id)`, which
  `Courier.Inbound.Resend` derives from the report's own content — so a redelivery
  is a 200 saying `duplicates: 1` and writes nothing. The `webhook-id` header
  would be a worse key, and `Courier.InboundReports` says why at length. And
  `CourierWeb.Plugs.Idempotency` is scoped to a principal, which this route has
  none of by design.

  ## A body courier will not buffer

  `max_body_bytes/0` bounds what courier reads before verifying, because this is
  an unauthenticated endpoint and an unbounded read is a denial of service
  handed to whoever finds the URL. Every provider report courier accepts is a few
  kilobytes, so the bound is generous for the report and small enough to be
  cheap.
  """

  use CourierWeb, :controller

  require Logger

  alias Courier.Inbound.Resend
  alias Courier.Inbound.Signature
  alias Courier.InboundConfig
  alias Courier.InboundReports, as: Reports
  alias CourierWeb.Problem

  # The bound on the body courier will read before verifying, in bytes. 1 MiB is
  # roughly a hundred times a documented Resend deliverability report and small
  # enough that the worst case is a request that costs a memcpy rather than one
  # that costs the process's memory.
  @max_body_bytes 1_048_576

  @doc """
  The body size this route will read before it verifies, in bytes.

  Public because the test that pads a body over it needs the number and a test
  that hard-codes 1_048_576 would be asserting against a copy.
  """
  @spec max_body_bytes() :: pos_integer()
  def max_body_bytes, do: @max_body_bytes

  @doc """
  Takes one provider report, or says exactly why it was refused.
  """
  def create(conn, _params) do
    # The secret is fetched FIRST, before the body and before any header, and the
    # order is `Courier.Inbound.Signature`'s own: a courier with no secret has one
    # problem — its own configuration — and it should be told that about every
    # request rather than about whichever request happened to omit a header
    # first.
    case signing_secret(conn) do
      {:ok, secret} -> verify(conn, secret)
      {:error, :no_signing_secret} -> not_configured(conn)
    end
  end

  defp verify(conn, secret) do
    case with_body(conn) do
      {:ok, body, conn} -> authenticated(conn, body, secret)
      {:error, :body_too_large} -> body_too_large(conn)
      {:error, {:unreadable_body, reason}} -> unreadable(conn, reason)
    end
  end

  # **`:invalid_secret` is courier's own defect and is answered as one**, which is
  # the whole reason it is separated from the five reasons a hostile request can
  # produce. `Courier.Inbound.Signature`'s moduledoc raises the objection
  # directly — "a route answering 500 to a misconfigured secret is
  # indistinguishable from one under attack, and the operator's first question
  # would be the wrong one" — and the answer is that the two are told apart by
  # status. A secret courier holds and cannot decode is a 500 naming the
  # variable; a request courier cannot authenticate is a 401.
  #
  # A secret that is *absent* never reaches here: `signing_secret/1` has already
  # refused it. This clause is for one that is present and undecodable, which
  # `config/runtime.exs` cannot catch because it only checks that the variable
  # is set.
  defp authenticated(conn, body, secret) do
    case Signature.verify(body, headers(conn), secret) do
      :ok -> record(conn, body)
      {:error, :invalid_secret} -> not_configured(conn)
      {:error, reason} -> not_authentic(conn, reason)
    end
  end

  # The raw bytes, as they arrived, and nothing else. `read_body/2` is what reads
  # them and there is no re-encoding anywhere on the way to
  # `Courier.Inbound.Signature` — because `CourierWeb.Plugs.ParseBody` left this
  # route alone, these are the bytes the signature covers. Spec §Signature scheme:
  # the payload "sent is the same as the payload signed", and it names
  # parse-then-re-serialize as "a very common failure mode" of verification.
  #
  # The connection is threaded through the `with` rather than rebound inside it,
  # because `read_body/2` returns a new conn and rebinding inside an `if` or a
  # `with` clause is the way that value goes missing.
  defp with_body(conn) do
    case read_body(conn, length: @max_body_bytes) do
      {:ok, body, conn} -> {:ok, body, conn}
      # `{:more, …}` means the body is over the bound, because `read_body/2` was
      # given a length and there is more. It is a 400 and not a 413 because a
      # provider that retries will not send a smaller one, so the honest answer
      # is "this request is not one courier will act on" rather than a status
      # inviting a retry with the same bytes.
      {:more, _partial, _conn} -> {:error, :body_too_large}
      {:error, reason} -> {:error, {:unreadable_body, reason}}
    end
  end

  # The three `svix-` headers, as a map. Both prefixes are read because
  # `Courier.Inbound.Signature` accepts either and a provider is free to send
  # either; every other header is dropped, so a signature check reads three names
  # and not the request's whole header set.
  defp headers(conn) do
    Enum.into(conn.req_headers, %{}, fn {name, value} -> {String.downcase(name), value} end)
  end

  # A provider courier was not configured for, or one it holds no usable secret
  # for, are the SAME answer and for the same reason: from this route's side they
  # are indistinguishable, and both are courier's configuration rather than
  # anything the requester did. `Courier.InboundConfig` is where the boot-time
  # refusal lives, and this is the per-request one — asked every time rather than
  # once, for the reason `CourierWeb.MessagesController` asks its adapter
  # predicate a third time per request: **the refusal has to be visible to the
  # caller**, and a courier that booted with no inbound secret would otherwise
  # answer 500 with nothing in it to say why.
  defp signing_secret(conn) do
    case InboundConfig.secret(conn.assigns[:inbound_provider]) do
      secret when is_binary(secret) and secret != "" -> {:ok, secret}
      _unusable -> {:error, :no_signing_secret}
    end
  end

  # Steps 2 and 3, in that order, and each refusal is its own answer rather than
  # a shared one — the whole reason this action does not call
  # `Courier.Inbound.handle/5` in one go.
  defp record(conn, body) do
    case Resend.parse(body) do
      {:ok, events} -> ingest(conn, events)
      {:error, reason} -> unclassifiable(conn, body, reason)
    end
  end

  defp ingest(conn, events) do
    case Reports.record_all(events) do
      {:ok, counts} ->
        json(conn, %{data: counts})

      {:error, reason} ->
        not_recorded(conn, reason)
    end
  end

  # --- the refusals -----------------------------------------------------------

  defp not_authentic(conn, reason) do
    # A refused signature is **not** an error worth an error-level log: somebody
    # guessing a webhook URL is the internet, and a log line per guess is a log
    # line per request an attacker chooses. `:invalid_secret` is the exception
    # and is handled by `not_configured/1`, because there it is courier's defect.
    Logger.warning("inbound report refused, not authentic: #{inspect(reason)}")

    Problem.send(
      conn,
      401,
      :unauthorized,
      "This request did not carry a valid provider signature, so courier did not " <>
        "read it. " <> reason_detail(reason)
    )
  end

  # The reason, in words, and **never a value from the request**. A refusal that
  # echoes what was sent is an oracle: it tells a forger which part of a forged
  # request to fix. Every one of these is a fixed sentence about courier's own
  # state, and the specific reason is in the log line above under the trace id.
  defp reason_detail(:timestamp_out_of_tolerance) do
    "A signature outside courier's replay window is refused even if it is " <>
      "correct, so a report older than that window is not acted on."
  end

  defp reason_detail({:missing_header, name}) do
    "The header #{inspect(name)} is missing."
  end

  defp reason_detail(:malformed_id), do: "The message id header is malformed."
  defp reason_detail(:malformed_timestamp), do: "The timestamp header is not a bare integer."
  defp reason_detail(:signature_mismatch), do: "The signature does not match the body received."
  defp reason_detail(_other), do: ""

  defp not_configured(conn) do
    Logger.error(
      "inbound report refused: this courier has no signing secret configured for the " <>
        "provider that signed it. See COURIER_INBOUND_RESEND_SECRET."
    )

    Problem.send(
      conn,
      500,
      :internal,
      "courier has no signing secret configured for this provider, so it cannot " <>
        "authenticate the request. This is courier's own configuration, not the " <>
        "provider's. See COURIER_INBOUND_RESEND_SECRET."
    )
  end

  # The socket failed courier before courier looked at the body. A 400 and not a
  # 500, because a body that cannot be read is a request courier could not have
  # known would arrive broken, and the detail names nothing from it.
  defp unreadable(conn, reason) do
    Logger.warning("inbound report refused, the body could not be read: #{inspect(reason)}")

    Problem.send(
      conn,
      400,
      :bad_request,
      "The request body could not be read, so it was not authenticated and nothing " <>
        "was recorded."
    )
  end

  defp body_too_large(conn) do
    Problem.send(
      conn,
      400,
      :bad_request,
      "The request body is larger than courier will read, so it was not authenticated " <>
        "and nothing was recorded."
    )
  end

  # A report courier understood and will not act on.
  #
  # **The split is 400 against 422, and it is core's own line.** "400 only for
  # malformed syntax the client could not have known; anything semantically wrong
  # is 422." A body that is not JSON, or is JSON that is not an object, is the
  # first: there is no field to name and nothing to correct, which is exactly what
  # `CourierWeb.Plugs.ParseBody`'s 400 means on every other route. A body courier
  # read and could not act on is the second, and `errors[]` names the field.
  #
  # The status is chosen by **which half of the parser failed** rather than by
  # matching the reason, and the reason list is small and closed:
  # `Courier.Inbound.Resend` documents exactly these as its `parse/1` contract, and
  # a new one has to be classified here rather than fall through to a status the
  # document does not declare.
  defp unclassifiable(conn, body, reason) do
    # The log line names what arrived, because `Courier.Inbound.Resend` refuses
    # with it precisely so an operator can act: a bounce type courier has not read
    # is a provider change, and "an event courier cannot classify" without the
    # event's name is a log line nobody can act on.
    Logger.warning(
      "inbound report refused, courier cannot act on it: " <>
        "#{describe(reason)}; event type #{inspect(event_type(body))}"
    )

    case status_for(reason) do
      400 ->
        unreadable_json(conn, reason)

      422 ->
        Problem.send(
          conn,
          422,
          :validation_failed,
          "courier could not act on this report. " <> summarise(reason),
          [error_field(reason)]
        )
    end
  end

  defp status_for(:invalid_json), do: 400
  defp status_for(:invalid_payload), do: 400
  defp status_for(_semantically_wrong), do: 422

  # The 400, and it says what courier did *not* do as much as what it could not:
  # the body was never decoded into anything courier acts on, so nothing was
  # recorded and no event was published.
  defp unreadable_json(conn, :invalid_payload) do
    Problem.send(
      conn,
      400,
      :bad_request,
      "The body is not a JSON object, so there was nothing in it courier could read. " <>
        "Nothing was recorded."
    )
  end

  defp unreadable_json(conn, _reason) do
    Problem.send(
      conn,
      400,
      :bad_request,
      "The body is not valid JSON, so courier could not read it. Nothing was recorded."
    )
  end

  # The event type, read out of an **already-verified** body for the log line
  # only. It is not read before verification anywhere, and it is not part of the
  # response: naming the type in the response would make this route a way to ask
  # a signed caller about courier's vocabulary, which is not what it is for.
  defp event_type(body) do
    case Jason.decode(body) do
      {:ok, %{"type" => type}} when is_binary(type) -> type
      _other -> "unknown"
    end
  end

  defp describe(:unsupported_event) do
    "It is an event type courier has not read, and courier does not act on an event " <>
      "it cannot classify."
  end

  defp describe({:unknown_bounce_type, value}) do
    "Its bounce type #{inspect(value)} is not one of the types courier has read."
  end

  # The one place a value from the payload is named, and it is named HERE — in a
  # log line — and not in the response. `Courier.Inbound.Resend` refuses with the
  # address precisely so this line can carry it: an operator who cannot see which
  # address arrived has a log line saying nothing happened, and the same value in
  # a body anybody who can reach the route can read is how this table becomes
  # queryable. The rule is `POST /v1/messages`'s — the 409 there does not echo the
  # address either.
  #
  # **The bounce type is named in both**, deliberately and for the opposite reason:
  # it is courier's own vocabulary being rejected, from a provider courier was
  # configured to receive from, and it names no mailbox. It is safe to return
  # because there is nothing in it to return.
  defp describe({:invalid_recipient, address}) do
    "One of the addresses it names, #{inspect(address)}, is not an address courier " <>
      "could send to."
  end

  defp describe({:missing_field, field}) do
    "It has no #{inspect(to_string(field))}, and courier cannot act on a report " <>
      "without one."
  end

  defp describe({:invalid_field, field}) do
    "Its #{inspect(to_string(field))} is not the shape courier reads."
  end

  defp describe(:invalid_payload) do
    "It is not a JSON object, so there is nothing in it courier can read."
  end

  defp describe(reason), do: "The reason is #{inspect(reason)}."

  # The same refusals, worded for a **response**: no value from the request, and
  # each one still specific enough for a provider to act on. Kept separate from
  # `describe/1` rather than filtering its output, because the two differ in
  # exactly one case and a filter that stripped values would be a way for the next
  # reason to leak one by omission.
  defp summarise({:invalid_recipient, _address}) do
    "One of the addresses it names is not an address courier could send to."
  end

  defp summarise(reason), do: describe(reason)

  # The field in `errors[]`, named as the provider's own documentation spells it
  # rather than as a path into courier's envelope: the sender wrote `bounce`, not
  # `data.bounce`, and a field a sender cannot find in the body it sent is not a
  # field it can fix.
  defp error_field({:unknown_bounce_type, _value}),
    do: %{"field" => "bounce", "code" => "unknown_bounce_type"}

  defp error_field(:unsupported_event), do: %{"field" => "type", "code" => "unsupported_event"}

  defp error_field({:invalid_recipient, _a}),
    do: %{"field" => "to", "code" => "invalid_recipient"}

  defp error_field({:missing_field, field}) do
    %{"field" => to_string(field), "code" => "required"}
  end

  defp error_field({:invalid_field, field}) do
    %{"field" => to_string(field), "code" => "invalid_format"}
  end

  defp error_field(_other), do: %{"field" => "type", "code" => "invalid_format"}

  defp not_recorded(conn, reason) do
    # The reason is logged rather than returned, for the same reason the send
    # path's provider refusal is: a database error string is PostgreSQL's own and
    # this repository is public. The transaction unwound, so nothing is
    # half-recorded and the provider's retry is safe.
    Logger.error(
      "inbound report could not be recorded, and nothing was written: #{inspect(reason)}"
    )

    Problem.send(
      conn,
      503,
      :unavailable,
      "courier could not record this report, so nothing was written and no event was " <>
        "published. The report is safe to retry: delivery is at-least-once and the " <>
        "same report recorded twice is one row."
    )
  end
end
