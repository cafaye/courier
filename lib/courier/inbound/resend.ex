defmodule Courier.Inbound.Resend do
  @moduledoc """
  Resend's deliverability reports, in courier's vocabulary.

  The first provider implementation of `Courier.Inbound`, and the one that
  matters for a specific reason: **Resend signs its webhooks with Svix**, and
  Svix is the scheme Standard Webhooks was standardised from. So the provider
  courier already talks to for OUTBOUND delivery is the provider that speaks the
  scheme courier already implements for OUTBOUND webhooks, and
  `Courier.Inbound.Signature` verifies it with the same base string.

  ## What this module is, and is not

  It is a translator and nothing else. It reads one provider's JSON and produces
  the event maps `Courier.Suppressions.ingest/1` already accepts, with the kind
  expressed in courier's words rather than Resend's. It does not verify anything
  (that is `Courier.Inbound.Signature`, and it runs first), it does not write
  anything (that is `Suppressions.ingest/1`), and it does not decide HTTP status
  (that is worker C's route).

  The mapping honours `Courier.Suppression`'s stated rationale rather than
  inventing a parallel vocabulary: "a Postmark `HardBounce` and an SES
  `Permanent` are both `:undeliverable` here, because the question courier asks
  is not 'what did Postmark call it' but 'can this mailbox receive mail'."
  Resend's `bounce.type` is the same shape of word, so the table is:

  | Resend `bounce.type` | courier kind | what courier does |
  | -------------------- | ------------ | ----------------- |
  | `Permanent`          | `:hard_bounce` | records `:undeliverable`, stops sending |
  | `Transient`          | `:soft_bounce` | records nothing |
  | `Temporary`          | `:soft_bounce` | records nothing |
  | `Undetermined`       | `:soft_bounce` | records nothing |

  Plus two event types that are not bounces at all:

  | Resend `type`      | courier kind | why |
  | ------------------ | ------------ | --- |
  | `email.complained` | `:complaint` | an abuse report; `Courier.Suppressions` makes it outrank a bounce |
  | `email.delivery_delayed` | `:soft_bounce` | "couldn't be delivered due to a temporary issue" — RFC 5321 §4.2.2 |

  Everything else is `{:ok, []}` or an error, and both of those are decisions
  rather than omissions. `test/courier/inbound/resend_test.exs` states each one
  with the documentation it came from.

  ## The four rules a parser of somebody else's JSON has to follow

    * **An event courier cannot classify is refused, not defaulted.** An unknown
      `type` is `{:error, :unsupported_event}` and an unknown `bounce.type` is
      `{:error, {:unknown_bounce_type, value}}`. `Courier.Suppressions` is
      explicit: "Storing an unclassifiable event as 'not suppressed' would be a
      decision courier could not defend." A provider that adds a bounce type
      should be VISIBLE in courier's logs, not quietly recorded as nothing.
    * **A known value meaning "we don't know" is the safe direction.**
      `Undetermined` is a real documented value and courier treats it as soft,
      because being told there was a bounce is not being told the mailbox is
      gone. Distinguishing "the provider says it does not know" from "courier
      does not recognise what the provider said" is the whole difference between
      a decision and a guess.
    * **The idempotency key is `email_id` AND the recipient.** Resend's `to` is
      "Array of impacted recipient email addresses" and a broadcast has one
      `email_id` for all of them, so `email_id` alone would let four of five
      bounces be recorded as duplicates of the first — four live mailboxes
      courier goes on mailing forever.
    * **Nothing is stored that courier does not act on.** The subject, the
      sender, the tags and the broadcast id are read out of the payload and
      dropped. `Courier.Suppression` says a `payload` column "would be a copy of
      somebody's inbox held for no operational reason", and every field carried
      forward is one `Courier.Observability` would have to keep out of a span.
  """

  @behaviour Courier.Inbound

  alias Courier.Suppressions

  @provider "resend"

  # Resend's documented bounce types, from
  # https://resend.com/docs/dashboard/emails/email-bounces ("There are three types
  # of bounces") plus the `Temporary` spelling in the `email.bounced` event page's
  # own example object. Both spellings of the soft case are listed because a
  # rename in either direction must not change what courier does.
  #
  # The two events that are not `email.bounced` and are still about a mailbox.
  @complained "email.complained"
  @delivery_delayed "email.delivery_delayed"
  @bounced "email.bounced"

  @bounce_types %{
    "Permanent" => :hard_bounce,
    "Transient" => :soft_bounce,
    "Temporary" => :soft_bounce,
    "Undetermined" => :soft_bounce
  }

  # Events courier has READ the documentation for and decided it has no
  # deliverability opinion on. Each is a decision, and the test file names the
  # reason for every one:
  #
  #   * `email.delivered` / `email.sent` / `email.scheduled` / `email.opened` /
  #     `email.clicked` — the send worked, or somebody read it.
  #   * `email.failed` — "the email failed to send due to an error": a quota, an
  #     API key, domain verification. Says nothing about the RECIPIENT's mailbox.
  #   * `suppression.added` / `suppression.removed` — Resend's own list. Its
  #     `origin` may be `manual`, i.e. a decision in Resend's dashboard that
  #     courier has no row for, and the causal bounce or complaint that put the
  #     address there has already arrived on its own.
  #
  # Deliberately NOT listed, and this is the load-bearing part: a type that is
  # not in this map is `{:error, :unsupported_event}`, not `{:ok, []}`. So a
  # provider that introduces a new event type, or renames one, produces a log
  # line rather than silence. A list of every type Resend documents is not used
  # here precisely because a list that accepts everything classifies nothing.
  @uninteresting_events MapSet.new([
                          "email.delivered",
                          "email.sent",
                          "email.scheduled",
                          "email.opened",
                          "email.clicked",
                          "email.failed",
                          "email.received",
                          "suppression.added",
                          "suppression.removed",
                          "domain.created",
                          "domain.updated",
                          "domain.deleted",
                          "contact.created",
                          "contact.updated",
                          "contact.deleted",
                          "contact.topics.updated",
                          "topic.created",
                          "topic.updated",
                          "topic.deleted",
                          "inbox.created",
                          "inbox.updated",
                          "inbox.deleted",
                          "inbox.thread.created",
                          "inbox.thread.folder.updated",
                          "inbox.thread.assigned",
                          "inbox.thread.unassigned",
                          "inbox.thread.labels.updated",
                          "inbox.email.received",
                          "inbox.email.sent",
                          "inbox.draft.created",
                          "inbox.draft.updated",
                          "inbox.draft.sent",
                          "inbox.draft.deleted"
                        ])

  @doc """
  The value that goes in `email_suppressions.provider`, and half of the unique
  index `(provider, provider_event_id)`.
  """
  @impl Courier.Inbound
  def provider, do: @provider

  @doc """
  Parses one Resend webhook body into zero or more `Courier.Suppressions` events.

  Takes the RAW body as a binary, not a decoded map, and the reason is not
  fussiness: the caller has to hand `Courier.Inbound.Signature.verify/4` the same
  bytes, and spec §Signature scheme names parse-then-re-serialize as "a very
  common failure mode" of verification. A parser that took a map would invite a
  route that parsed first and verified a re-encoding, which verifies nothing.

  `{:ok, []}` means "understood, and courier has no opinion on this event".
  `{:ok, events}` means one or more reports, one per recipient, each ready for
  `Courier.Suppressions.ingest/1`. An error means the payload could not be read
  or not be classified, and the reason says which.
  """
  @impl Courier.Inbound
  def parse(body) when is_binary(body) do
    # The ENVELOPE and the `data` object are both threaded through, not just
    # `data`, and `created_at` is the reason: the envelope's copy is when the
    # report happened and `data.created_at` is when the email was sent. Only
    # keeping the envelope would lose the recipients; only keeping `data` would
    # date every suppression to the send, which is hours early and answers a
    # different question than the one an operator is asking.
    with {:ok, envelope} <- decode(body),
         {:ok, type} <- string_field(envelope, :type),
         {:ok, data} <- object_field(envelope, :data),
         do: classify(type, envelope, data)
  end

  @impl Courier.Inbound
  def parse(_not_a_binary), do: {:error, :invalid_body}

  # Three outcomes, and the middle one is a decision rather than a gap:
  #
  #   * a bounce or complaint — build one event per recipient
  #   * an event courier has read and has no opinion on — `{:ok, []}`
  #   * anything else — refused, loudly
  # The RECIPIENTS are read inside the branches rather than before them, and that
  # ordering is load-bearing in both directions. `suppression.added` names its
  # address in `data.email` and has no `to` at all, so a parser that demanded `to`
  # before classifying would refuse an event courier has deliberately no opinion
  # on — turning a decision into a 422 and making the no-opinion list untestable.
  # And an unknown `type` would be reported as a missing `to` rather than as an
  # event courier cannot classify, which is the one error an operator needs to see
  # when a provider introduces a new event type.
  defp classify(@bounced, envelope, data) do
    # The bounce object's own `type` is read BEFORE the email id, so a payload
    # that is missing both is reported as the thing a reader would fix first:
    # a bounce with nothing to say why it bounced is not a report courier can
    # classify at all.
    with {:ok, bounce} <- object_field(data, :bounce),
         {:ok, bounce_type} <- string_field(bounce, :type),
         {:ok, kind} <- bounce_kind(bounce_type),
         {:ok, email_id} <- string_field(data, :email_id),
         {:ok, recipients} <- recipients(data),
         do: build(@bounced, kind, envelope, data, bounce, recipients, email_id)
  end

  defp classify(@complained, envelope, data) do
    with {:ok, email_id} <- string_field(data, :email_id),
         {:ok, recipients} <- recipients(data),
         do: build(@complained, :complaint, envelope, data, nil, recipients, email_id)
  end

  defp classify(@delivery_delayed, envelope, data) do
    with {:ok, email_id} <- string_field(data, :email_id),
         {:ok, recipients} <- recipients(data),
         do: build(@delivery_delayed, :soft_bounce, envelope, data, nil, recipients, email_id)
  end

  defp classify(type, _envelope, _data) do
    if MapSet.member?(@uninteresting_events, type),
      do: {:ok, []},
      else: {:error, :unsupported_event}
  end

  defp bounce_kind(type) do
    case Map.fetch(@bounce_types, type) do
      {:ok, kind} ->
        {:ok, kind}

      :error ->
        # The value is courier's own vocabulary being rejected from a provider
        # courier configured, never caller text, so it is safe to log.
        {:error, {:unknown_bounce_type, type}}
    end
  end

  # Every identifying field is in `data` and the report's own clock is at the top
  # level, so both maps are threaded through rather than one of them. Reading
  # only `data` would date every suppression to the send — hours early, and a
  # question nobody asked. Reading only the envelope would lose the recipients.
  defp build(type, kind, envelope, data, bounce, recipients, email_id) do
    with {:ok, message_id} <- optional_string(data, :message_id) do
      {:ok, Enum.map(recipients, &event(&1, type, kind, envelope, bounce, email_id, message_id))}
    end
  end

  defp event(email, type, kind, envelope, bounce, email_id, message_id) do
    %{
      provider: @provider,
      provider_event_id: event_id(type, email_id, email),
      email: email,
      kind: kind,
      reason: reason(bounce),
      message_id: message_id,
      occurred_at: occurred_at(envelope)
    }
  end

  # The unit of the report is (this KIND of report, this email, this address), and
  # all three parts are load-bearing. Measured while writing the test that found
  # it: with `email_id` and the address alone, a complaint about an address that
  # had already hard-bounced produced the SAME key, so `Courier.Suppressions`'s
  # unique index returned `{:ok, :duplicate, row}` and no `:suppressed` row was
  # ever written — the complaint silently lost, which is the exact inversion of
  # the rule `Courier.Suppressions` exists to make unbreakable ("`:suppressed`
  # outranks `:undeliverable`"). The type goes in first for the same reason the
  # address does: without it, one address and one email can only ever produce one
  # row, and a report that gets STRONGER later would be discarded as a repeat.
  #
  # `:soft_bounce` and `:complaint` are kept apart for the same reason even though
  # neither suppresses: a soft bounce records nothing, so if the two shared a key
  # a complaint arriving after one would be refused as a duplicate of a report
  # that was never stored, and the address would go on being mailed.
  defp event_id(type, email_id, email) do
    "#{type}/#{email_id}:#{Suppressions.normalize(email)}"
  end

  # The provider's own words, per `Courier.Suppression`: "when an operator asks
  # courier why an address is suppressed the useful answer is the provider's
  # sentence and not courier's enum." For a complaint there is nothing — the
  # documented payload has no explanation field, because the recipient pressed a
  # button — so the reason is `nil` rather than a sentence courier invented.
  #
  # `bounce.diagnosticCode` is documented as "Array of SMTP diagnostic responses
  # from the receiving server, including the status code and reason", and it is
  # PREFERRED over `bounce.message` when present: those are the recipient's own
  # server's words rather than Resend's summary of them, and "5.1.1 does not
  # exist" is the sentence an operator actually needs. Folded into `reason`
  # rather than given a column because `Courier.Suppression` bounds its free
  # text at `reason_length/0` and says adding a field is a decision somebody
  # reads.
  defp reason(nil), do: nil

  defp reason(bounce) do
    [
      Map.get(bounce, "type"),
      Map.get(bounce, "subType"),
      bounce |> diagnostic() |> Kernel.||(Map.get(bounce, "message"))
    ]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join(": ")
  end

  defp diagnostic(bounce) do
    case bounce |> Map.get("diagnosticCode") |> List.wrap() |> Enum.filter(&is_binary/1) do
      [] -> nil
      codes -> Enum.join(codes, " | ")
    end
  end

  # `created_at` at the TOP LEVEL is the report's own timestamp; `data.created_at`
  # is "when the email was created", which is the send — hours earlier, and the
  # wrong answer to "when did this address bounce". The envelope's value is the
  # one used, which is why the whole payload is threaded through to here rather
  # than only `data`.
  #
  # Parsed leniently on purpose: `Courier.Suppressions`' event type marks
  # `occurred_at` optional, and refusing a whole report because a provider's
  # timestamp format changed would mean a silent end to every suppression in the
  # fleet. An unparseable instant is `nil`, which is a documented shape.
  defp occurred_at(envelope) do
    with value when is_binary(value) <- Map.get(envelope, "created_at"),
         {:ok, instant, _offset} <- DateTime.from_iso8601(value) do
      instant
    else
      _absent_or_unparseable -> nil
    end
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, payload} when is_map(payload) -> {:ok, payload}
      {:ok, _not_an_object} -> {:error, :invalid_payload}
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  defp object_field(payload, field) do
    case Map.fetch(payload, Atom.to_string(field)) do
      {:ok, value} when is_map(value) ->
        {:ok, value}

      {:ok, _wrong_type} ->
        {:error, {:invalid_field, field}}

      :error ->
        {:error, {:missing_field, field}}
    end
  end

  defp string_field(payload, field) do
    case Map.fetch(payload, Atom.to_string(field)) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, _wrong_type} -> {:error, {:invalid_field, field}}
      :error -> {:error, {:missing_field, field}}
    end
  end

  defp optional_string(payload, field) do
    case Map.fetch(payload, Atom.to_string(field)) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      :error -> {:ok, nil}
      {:ok, _wrong_type} -> {:error, {:invalid_field, field}}
    end
  end

  # Every recipient is checked, and one bad address refuses the whole report.
  # `Courier.Suppression`'s changeset validates the format at the boundary, so a
  # malformed one would become a changeset error there — but arriving as a
  # readable reason here is what lets the route answer 422 and log WHICH address
  # was wrong, and a report courier cannot read is not a report courier should
  # half-apply.
  defp recipients(data) do
    case Map.fetch(data, "to") do
      {:ok, list} when is_list(list) -> validate_recipients(list)
      {:ok, _not_a_list} -> {:error, {:invalid_field, :to}}
      :error -> {:error, {:missing_field, :to}}
    end
  end

  # The bad address is NAMED rather than collapsed into "no recipients", for the
  # reason `Courier.Idempotency.refusal/1` gives: a refusal a reader cannot act on
  # is a note rather than a diagnosis, and this one is a provider payload courier
  # can log verbatim. It is `List.wrap/1`'d and string-filtered first because
  # `bounce` payloads have been seen carrying `to` as a bare string in the wild,
  # and `"a@b.com"` wrapped into a list is a list of one address rather than a
  # crash.
  defp validate_recipients([]), do: {:error, {:missing_field, :to}}

  defp validate_recipients(list) do
    case Enum.find(list, &(not valid_recipient?(&1))) do
      nil -> {:ok, list}
      bad -> {:error, {:invalid_recipient, bad}}
    end
  end

  defp valid_recipient?(address) when is_binary(address) do
    Regex.match?(~r/^[^@\s,;]+@[^@\s,;]+\.[^@\s,;]+$/, address)
  end

  defp valid_recipient?(_other), do: false
end
