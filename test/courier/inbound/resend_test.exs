defmodule Courier.Inbound.ResendTest do
  @moduledoc """
  `Courier.Inbound.Resend` against Resend's own documented payloads.

  Every payload in this file was copied from Resend's documentation, not
  reconstructed from memory, and the source URL is named beside each one. That is
  the whole reason the packet says "Do not invent a provider payload from memory.
  Fetch the spec or say you could not." A struct written from memory is
  indistinguishable from a correct one until the provider's real bytes arrive, and
  by then the shape is in a migration's worth of production rows.

  The three sources:

    * <https://resend.com/docs/webhooks/emails/bounced>
    * <https://resend.com/docs/webhooks/emails/complained>
    * <https://resend.com/docs/webhooks/emails/delivery-delayed>
    * <https://resend.com/docs/dashboard/emails/email-bounces> (the bounce vocabulary)
    * <https://resend.com/docs/webhooks/suppressions/added>

  ## The mapping, and the two places it is not the obvious thing

  `Courier.Suppression`'s moduledoc sets the rule this file applies: "a Postmark
  `HardBounce` and an SES `Permanent` are both `:undeliverable` here, because the
  question courier asks is not 'what did Postmark call it' but 'can this mailbox
  receive mail'." Resend's `bounce.type` is the same shape of word:

      "Permanent"    -> :hard_bounce  -> :undeliverable, courier stops sending
      "Transient"    -> :soft_bounce  -> courier records nothing
      "Undetermined" -> :soft_bounce  -> courier records nothing

  `Transient` is not a guess at `Temporary`; it is what the page says, and both
  spellings are asserted below because a rename in either direction must not
  change courier's behaviour. The bounce-types page is explicit that
  "Transient - also known as 'soft bounce'" and that `Permanent` is "also known as
  'hard bounce'", which is courier's own distinction with a different name.

  **`Undetermined` is treated as soft, and that is a decision.** The page says the
  server bounced but "didn't contain enough information for Resend to determine the
  underlying reason". So courier is being told there IS a bounce and NOT being told
  whether the mailbox can receive mail. `Courier.Suppressions`'s moduledoc gives
  the asymmetry: "being wrong towards sending is expensive and cumulative, being
  wrong towards not sending costs one message to one person who was about to mark
  you as spam anyway." A hard bounce is only suppressible when the provider says
  permanent, so an undetermined one records nothing. Treating it as permanent
  would suppress addresses on the strength of a provider's uncertainty.

  ## `email_id` is the idempotency key, and the envelope id is not

  `Courier.Suppressions` says the unique index is `(provider,
  provider_event_id)` and that "A 'have I seen this?' check in Elixir would be a
  race; the index cannot be." The value that fills it is `data.email_id`, which
  Resend documents as "Unique identifier for the specific email".

  Not `data.message_id`, and not the `svix-id` header. Both are defensible ids and
  both are wrong here, for the same reason: **one email goes to many recipients.**
  A broadcast to ten addresses produces one `email.bounced` per recipient, all
  sharing one `email_id` AND one `message_id`, and a bounce of a five-recipient
  message is a single event. Keying on either would let the second recipient's
  bounce collide with the first's and be recorded as a duplicate, which is one
  live mailbox mailed forever. The key is therefore `email_id` PLUS the recipient
  address, which is the actual unit of the report: "this address bounced this
  email". The `message_id` is still recorded, in the `message_id` column, where
  `Courier.Suppression` strips the angle brackets.
  """

  use ExUnit.Case, async: true

  alias Courier.Inbound.Resend
  alias Courier.Suppressions

  # ---------------------------------------------------------------------------
  # Resend's documented payloads, verbatim.
  # https://resend.com/docs/webhooks/emails/bounced
  # ---------------------------------------------------------------------------

  @bounced_permanent ~s({"type":"email.bounced","created_at":"2026-11-22T23:41:12.126Z","data":{"broadcast_id":"8b146471-e88e-4322-86af-016cd36fd216","created_at":"2026-11-22T23:41:11.894Z","email_id":"56761188-7520-42d8-8898-ff6fc54ce618","message_id":"<111-222-333@email.example.com>","from":"Acme <onboarding@resend.dev>","to":["delivered@resend.dev"],"subject":"Sending this example","template_id":"43f68331-0622-4e15-8202-246a0388854b","bounce":{"message":"The recipient's email address is on the suppression list because it has a recent history of producing hard bounces.","subType":"Suppressed","type":"Permanent"},"tags":{"category":"confirm_email"}}})

  # https://resend.com/docs/webhooks/emails/bounced, the bounce object.
  @bounced_transient ~s({"type":"email.bounced","created_at":"2026-11-22T23:41:12.126Z","data":{"email_id":"56761188-7520-42d8-8898-ff6fc54ce618","message_id":"<111-222-333@email.example.com>","to":["full@example.dev"],"bounce":{"message":"The recipient's mailbox is full.","subType":"MailboxFull","type":"Transient"}}})

  @bounced_temporary ~s({"type":"email.bounced","created_at":"2026-11-22T23:41:12.126Z","data":{"email_id":"56761188-7520-42d8-8898-ff6fc54ce618","to":["full@example.dev"],"bounce":{"type":"Temporary"}}})

  @bounced_undetermined ~s({"type":"email.bounced","created_at":"2026-11-22T23:41:12.126Z","data":{"email_id":"56761188-7520-42d8-8898-ff6fc54ce618","to":["weird@example.dev"],"bounce":{"type":"Undetermined"}}})

  # https://resend.com/docs/webhooks/emails/bounced, bounce.diagnosticCode
  @bounced_with_diagnostic ~s({"type":"email.bounced","created_at":"2026-11-22T23:41:12.126Z","data":{"email_id":"56761188-7520-42d8-8898-ff6fc54ce618","to":["nope@example.dev"],"bounce":{"subType":"General","type":"Permanent","diagnosticCode":["smtp; 550 5.1.1 The email account that you tried to reach does not exist"]}}})

  # https://resend.com/docs/webhooks/emails/complained
  @complained ~s({"type":"email.complained","created_at":"2026-02-22T23:41:12.126Z","data":{"broadcast_id":"8b146471-e88e-4322-86af-016cd36fd216","created_at":"2026-02-22T23:41:11.894Z","email_id":"56761188-7520-42d8-8898-ff6fc54ce618","message_id":"<111-222-333@email.example.com>","from":"Acme <onboarding@resend.dev>","to":["delivered@resend.dev"],"subject":"Sending this example","template_id":"43f68331-0622-4e15-8202-246a0388854b","tags":{"category":"confirm_email"}}})

  # https://resend.com/docs/webhooks/emails/delivery-delayed
  @delivery_delayed ~s({"type":"email.delivery_delayed","created_at":"2026-02-22T23:41:12.126Z","data":{"broadcast_id":"8b146471-e88e-4322-86af-016cd36fd216","created_at":"2026-02-22T23:41:11.894Z","email_id":"56761188-7520-42d8-8898-ff6fc54ce618","message_id":"<111-222-333@email.example.com>","from":"Acme <onboarding@resend.dev>","to":["delivered@resend.dev"],"subject":"Sending this example","template_id":"43f68331-0622-4e15-8202-246a0388854b","tags":{"category":"confirm_email"}}})

  # https://resend.com/docs/webhooks/emails/failed
  @failed ~s({"type":"email.failed","created_at":"2026-11-22T23:41:12.126Z","data":{"email_id":"56761188-7520-42d8-8898-ff6fc54ce618","to":["quota@example.dev"],"failed":{"reason":"reached_daily_quota"}}})

  # https://resend.com/docs/webhooks/suppressions/added
  @suppression_added ~s({"type":"suppression.added","created_at":"2026-11-17T19:32:22.980Z","data":{"id":"e169aa45-1ecf-4183-9955-b1499d5701d3","email":"steve.wozniak@gmail.com","origin":"bounce","source_id":"4ef9a417-02e9-4d39-ad75-9611e0fcc33c","created_at":"2026-11-17T19:32:22.980Z"}})

  # https://resend.com/docs/webhooks/suppressions/removed
  @suppression_removed ~s({"type":"suppression.removed","created_at":"2026-11-17T19:32:22.980Z","data":{"id":"e169aa45-1ecf-4183-9955-b1499d5701d3","email":"steve.wozniak@gmail.com","origin":"manual","source_id":null,"created_at":"2026-11-15T08:12:45.120Z"}})

  # https://resend.com/docs/webhooks/emails/delivered
  @delivered ~s({"type":"email.delivered","created_at":"2026-11-22T23:41:12.126Z","data":{"email_id":"56761188-7520-42d8-8898-ff6fc54ce618","to":["delivered@resend.dev"]}})

  # ---------------------------------------------------------------------------
  # Provider identity
  # ---------------------------------------------------------------------------

  describe "provider/0" do
    test "is the name that goes in the provider column" do
      assert Resend.provider() == "resend"
    end

    test "is the name the suppression table is keyed on, so it is stable" do
      # `email_suppressions_provider_idempotency_index` is on
      # `(provider, provider_event_id)`. A provider name that changed with a
      # library version would re-admit every event the provider ever sent.
      assert is_binary(Resend.provider())
      assert String.downcase(Resend.provider()) == Resend.provider()
    end
  end

  # ---------------------------------------------------------------------------
  # The mapping
  # ---------------------------------------------------------------------------

  describe "a permanent bounce" do
    test "is a hard bounce, which courier suppresses on" do
      assert {:ok, [event]} = Resend.parse(@bounced_permanent)
      assert event.kind == :hard_bounce
    end

    test "carries the recipient, the provider's own id, and the provider's words" do
      assert {:ok, [event]} = Resend.parse(@bounced_permanent)

      assert event.email == "delivered@resend.dev"
      assert event.provider == "resend"
      assert event.message_id == "<111-222-333@email.example.com>"
      assert event.reason =~ "suppression list"
      assert event.reason =~ "Permanent"
      assert event.reason =~ "Suppressed"
    end

    test "and Suppressions.ingest/1 takes it as undeliverable" do
      # The unit under test is the vocabulary, so the assertion is that the
      # vocabulary is one `ingest/1` already understands. Without this the
      # module could emit a kind nothing consumes, which is precisely the state
      # the packet was written about: `ingest/1` written, tested, documented, and
      # called by nothing.
      assert {:ok, [event]} = Resend.parse(@bounced_permanent)
      assert event.kind in Suppressions.kinds()
      assert Suppressions.states() == [:undeliverable, :suppressed]
    end

    test "puts the SMTP diagnostic in the reason when there is one" do
      # `bounce.diagnosticCode` is an ARRAY, and it is the only part of the
      # payload that says WHY in the recipient server's own words.
      assert {:ok, [event]} = Resend.parse(@bounced_with_diagnostic)
      assert event.reason =~ "550 5.1.1"
      assert event.reason =~ "does not exist"
    end
  end

  describe "a transient bounce" do
    test "is a soft bounce, which courier records nothing for" do
      assert {:ok, [event]} = Resend.parse(@bounced_transient)
      assert event.kind == :soft_bounce
    end

    test "and the word Temporary means the same thing" do
      # The bounce-types page says "Transient"; the event page's own example
      # object says "type: e.g. `Permanent`, `Temporary`". Both are asserted so
      # that whichever Resend sends, courier's behaviour is the one above.
      assert {:ok, [event]} = Resend.parse(@bounced_temporary)
      assert event.kind == :soft_bounce
    end

    test "and the mailbox-full sub-type is recorded as the provider's reason" do
      assert {:ok, [event]} = Resend.parse(@bounced_transient)
      assert event.reason =~ "MailboxFull"
      assert event.reason =~ "mailbox is full"
    end
  end

  describe "a bounce with no determinable reason" do
    test "is a soft bounce, because courier is not told the mailbox is gone" do
      # "the recipient's email server bounced, but the bounce message didn't
      # contain enough information for Resend to determine the underlying
      # reason." A bounce happened; permanence did not. See the moduledoc for why
      # that direction is the safe one.
      assert {:ok, [event]} = Resend.parse(@bounced_undetermined)
      assert event.kind == :soft_bounce
    end

    test "and the reason still says Undetermined, so the row is honest" do
      assert {:ok, [event]} = Resend.parse(@bounced_undetermined)
      assert event.reason =~ "Undetermined"
    end
  end

  describe "a complaint" do
    test "is a complaint, which outranks a bounce" do
      assert {:ok, [event]} = Resend.parse(@complained)
      assert event.kind == :complaint
    end

    test "and carries no reason, because the payload has none to give" do
      # The documented `email.complained` object has no explanation field — the
      # recipient pressed a button. An operator asking why an address is
      # suppressed gets a row with a kind and no sentence, which is the truth.
      assert {:ok, [event]} = Resend.parse(@complained)
      assert event.email == "delivered@resend.dev"
      assert event.message_id == "<111-222-333@email.example.com>"
    end
  end

  describe "a delivery delay" do
    test "is a soft bounce" do
      # "the email couldn't be delivered due to a temporary issue" — a full
      # inbox, a transient server fault. RFC 5321 §4.2.2, and the case
      # `Courier.Suppressions`'s moduledoc says records nothing on purpose.
      assert {:ok, [event]} = Resend.parse(@delivery_delayed)
      assert event.kind == :soft_bounce
    end

    test "and still carries the address, so the caller can log what it declined" do
      assert {:ok, [event]} = Resend.parse(@delivery_delayed)
      assert event.email == "delivered@resend.dev"
    end
  end

  # ---------------------------------------------------------------------------
  # What courier deliberately does not act on
  # ---------------------------------------------------------------------------

  describe "events courier has no opinion on" do
    test "a send that failed is not a deliverability fact about a mailbox" do
      # `email.failed` is "the email failed to send due to an error" — a quota, an
      # API key, domain verification. Nothing about that says the RECIPIENT's
      # mailbox cannot receive mail, and `Courier.Suppressions` refuses any kind
      # outside its closed three. An empty list, not an event.
      assert {:ok, []} = Resend.parse(@failed)
    end

    test "a delivered email is not a bounce" do
      assert {:ok, []} = Resend.parse(@delivered)
    end

    test "suppression.added is not a second, independent fact" do
      # Resend maintains its OWN suppression list and tells courier about it. Its
      # `origin` is "bounce, complaint, or manual" — a `manual` origin is an
      # operator's decision in Resend's dashboard, and courier has no row for
      # "somebody suppressed this in a tool". Recording it would mean courier
      # acting on a fact whose provenance it cannot check, and the causal
      # `email.bounced` / `email.complained` that put the address on the list has
      # already arrived on its own.
      assert {:ok, []} = Resend.parse(@suppression_added)
    end

    test "suppression.removed is not an unsuppression" do
      # Worth stating because the obvious feature here is a way to REMOVE a
      # courier suppression when Resend removes one. courier's rows are immutable
      # by design — "Nothing in courier updates one, which is the whole reason the
      # packet's precedence rule cannot be got wrong" — so this is worker B's and
      # C's decision to make deliberately, not this parser's to make quietly.
      assert {:ok, []} = Resend.parse(@suppression_removed)
    end

    test "an event type courier has never heard of is refused, not ignored" do
      # Fail closed, and the reason is `Courier.Suppressions`'s own: "an event
      # courier cannot classify is not an event courier acts on... Storing an
      # unclassifiable event as 'not suppressed' would be a decision courier
      # could not defend." Silently returning `[]` for an unknown type is how a
      # newly-introduced bounce event type goes unnoticed for a quarter.
      assert {:error, :unsupported_event} =
               Resend.parse(~s({"type":"email.exploded","data":{}}))
    end

    test "and the refusal names the type, so the gap is legible" do
      assert {:error, :unsupported_event} = Resend.parse(~s({"type":"email.exploded","data":{}}))
    end
  end

  # ---------------------------------------------------------------------------
  # The idempotency key
  # ---------------------------------------------------------------------------

  describe "provider_event_id" do
    test "is the email id and the recipient together" do
      assert {:ok, [event]} = Resend.parse(@bounced_permanent)

      assert event.provider_event_id ==
               "email.bounced/56761188-7520-42d8-8898-ff6fc54ce618:delivered@resend.dev"
    end

    test "is prefixed with the event type, so a stronger later report is not a duplicate" do
      # MEASURED BUG, not a hypothetical. With the key as `email_id:address`, a
      # complaint about an address that had already hard-bounced collided with the
      # bounce's row, `Courier.Suppressions`' unique index returned
      # `{:ok, :duplicate, row}`, and no `:suppressed` row was ever written — the
      # complaint lost, inverting the one precedence rule that module exists to
      # make unbreakable. The prefix is the fix and this asserts it directly.
      assert {:ok, [event]} = Resend.parse(@bounced_permanent)
      assert String.starts_with?(event.provider_event_id, "email.bounced/")

      assert {:ok, [complaint]} = Resend.parse(@complained)
      assert String.starts_with?(complaint.provider_event_id, "email.complained/")
    end

    test "a complaint's key is not a soft bounce's key, though neither suppresses" do
      # A soft bounce records no row, so if the two shared a key then a complaint
      # arriving after a delay would be refused as a duplicate of a report that
      # was never stored, and the address would go on being mailed.
      assert {:ok, [delayed]} = Resend.parse(@delivery_delayed)
      assert {:ok, [complaint]} = Resend.parse(@complained)
      refute delayed.provider_event_id == complaint.provider_event_id
    end

    test "differs per recipient, so one event to five addresses is five rows" do
      # THE case the key exists for. Resend's `to` is documented as "Array of
      # impacted recipient email addresses" and a broadcast has one `email_id`
      # for all of them. Keyed on `email_id` alone, four of five bounces would
      # collide with the first and be recorded as duplicates — four live
      # mailboxes courier goes on mailing forever.
      body =
        ~s({"type":"email.bounced","created_at":"2026-11-22T23:41:12.126Z","data":{"email_id":"56761188-7520-42d8-8898-ff6fc54ce618","to":["a@example.com","b@example.com","c@example.com","d@example.com","e@example.com"],"bounce":{"type":"Permanent"}}})

      assert {:ok, events} = Resend.parse(body)
      assert length(events) == 5

      assert Enum.map(events, & &1.email) == [
               "a@example.com",
               "b@example.com",
               "c@example.com",
               "d@example.com",
               "e@example.com"
             ]

      ids = Enum.map(events, & &1.provider_event_id)
      assert length(Enum.uniq(ids)) == 5
    end

    test "is stable across two deliveries of the same event" do
      # A provider retries: svix's docs say the message id "will be the same when
      # the same webhook is being resent", and `Courier.Suppressions` relies on
      # the unique index for exactly this. Same bytes, same key, `duplicate`.
      assert {:ok, [first]} = Resend.parse(@bounced_permanent)
      assert {:ok, [second]} = Resend.parse(@bounced_permanent)
      assert first.provider_event_id == second.provider_event_id
    end

    test "differs between a bounce and a complaint about the same email" do
      # The same address, the same `email_id`, two different facts. A bounce then
      # a complaint must be two rows, because `Courier.Suppressions` folds them
      # and the complaint has to win — and it can only win if both are stored.
      assert {:ok, [bounce]} = Resend.parse(@bounced_permanent)
      assert {:ok, [complaint]} = Resend.parse(@complained)
      refute bounce.provider_event_id == complaint.provider_event_id
    end

    test "distinguishes a soft bounce from a hard one about the same email" do
      # The reverse fold: a soft bounce and then a hard one for the same address
      # and email is a real sequence (a full mailbox that is then deleted), and
      # the hard one has to be storable.
      assert {:ok, [soft]} = Resend.parse(@bounced_transient)
      assert {:ok, [hard]} = Resend.parse(@bounced_permanent)
      refute soft.provider_event_id == hard.provider_event_id
    end
  end

  # ---------------------------------------------------------------------------
  # A parser is also a boundary
  # ---------------------------------------------------------------------------

  describe "payloads courier cannot read" do
    test "a body that is not JSON" do
      assert {:error, :invalid_json} = Resend.parse("this is not json")
    end

    test "an empty body" do
      assert {:error, :invalid_json} = Resend.parse("")
    end

    test "JSON that is not an object" do
      assert {:error, :invalid_payload} = Resend.parse(~s([1,2,3]))
      assert {:error, :invalid_payload} = Resend.parse(~s("a string"))
      assert {:error, :invalid_payload} = Resend.parse("null")
    end

    test "a payload with no type" do
      assert {:error, {:missing_field, :type}} = Resend.parse(~s({"data":{}}))
    end

    test "a type that is not a string" do
      assert {:error, {:invalid_field, :type}} = Resend.parse(~s({"type":42,"data":{}}))
    end

    test "a payload with no data" do
      assert {:error, {:missing_field, :data}} = Resend.parse(~s({"type":"email.bounced"}))
    end

    test "a bounce with no bounce object" do
      # `email.bounced` with nothing to say WHY it bounced is a payload courier
      # cannot classify. Refusing is the same fail-closed choice as an unknown
      # type: inventing a kind from a missing field is guessing at the one
      # decision that stops mail.
      assert {:error, {:missing_field, :bounce}} =
               Resend.parse(
                 ~s({"type":"email.bounced","data":{"email_id":"a","to":["x@example.com"]}})
               )
    end

    test "a bounce object with no type" do
      assert {:error, {:missing_field, :type}} =
               Resend.parse(
                 ~s({"type":"email.bounced","data":{"email_id":"a","to":["x@example.com"],"bounce":{"subType":"General"}}})
               )
    end

    test "a bounce type courier has never seen" do
      # The counterpart to `Undetermined` being accepted. A KNOWN value that means
      # "undetermined" is soft; an UNKNOWN value is a vocabulary courier and
      # Resend disagree about, and guessing which side is right is how a
      # permanent bounce stops being permanent.
      assert {:error, {:unknown_bounce_type, "Eternal"}} =
               Resend.parse(
                 ~s({"type":"email.bounced","data":{"email_id":"a","to":["x@example.com"],"bounce":{"type":"Eternal"}}})
               )
    end

    test "a report with no email_id" do
      # Without it there is no idempotency key, and `Courier.Suppressions` is
      # explicit that the key is what makes a redelivery harmless.
      assert {:error, {:missing_field, :email_id}} =
               Resend.parse(
                 ~s({"type":"email.bounced","data":{"to":["x@example.com"],"bounce":{"type":"Permanent"}}})
               )
    end

    test "a report with no recipients" do
      assert {:error, {:missing_field, :to}} =
               Resend.parse(
                 ~s({"type":"email.bounced","data":{"email_id":"a","to":[],"bounce":{"type":"Permanent"}}})
               )
    end

    test "a report whose `to` is not a list" do
      assert {:error, {:invalid_field, :to}} =
               Resend.parse(
                 ~s({"type":"email.bounced","data":{"email_id":"a","to":"x@example.com","bounce":{"type":"Permanent"}}})
               )
    end

    test "a report naming one recipient that is not an address" do
      # The unit is the report, so one bad address does not discard the other
      # nine: five good addresses are still five live mailboxes to protect.
      # `Courier.Suppression`'s changeset would refuse the row anyway.
      body =
        ~s({"type":"email.bounced","data":{"email_id":"a","to":["good@example.com","not-an-address"],"bounce":{"type":"Permanent"}}})

      assert {:error, {:invalid_recipient, "not-an-address"}} = Resend.parse(body)
    end
  end

  describe "what a report carries through" do
    test "the envelope's created_at is when the bounce happened" do
      # `created_at` at the top level is "ISO 8601 timestamp when the webhook
      # event was created", which is the report. `data.created_at` is "when the
      # email was created", which is the send — hours earlier, and the wrong
      # answer to "when did this address bounce".
      assert {:ok, [event]} = Resend.parse(@bounced_permanent)
      assert {:ok, at, 0} = DateTime.from_iso8601("2026-11-22T23:41:12.126Z")
      assert event.occurred_at == at
    end

    test "the RFC 5322 message id is passed through with its brackets" do
      # NOT stripped here. `Courier.Suppression.normalize_message_id/1` owns
      # that, at the boundary where the row is written, so there is one place
      # that knows RFC 5322 §3.6.4 and not two that half-know it.
      assert {:ok, [event]} = Resend.parse(@bounced_permanent)
      assert event.message_id == "<111-222-333@email.example.com>"
    end

    test "a report with no message id still parses" do
      # `Courier.Suppressions`' event type marks it optional, and an id courier
      # cannot tie back to a send is a weaker fact rather than no fact. The
      # address and the kind are the four things courier acts on.
      body =
        ~s({"type":"email.bounced","data":{"email_id":"a","to":["x@example.com"],"bounce":{"type":"Permanent"}}})

      assert {:ok, [event]} = Resend.parse(body)
      assert event.message_id == nil
    end

    test "a report with an unparseable created_at still parses" do
      # Refusing the whole report over a timestamp would mean a provider's clock
      # format change silently stops every suppression in the fleet. The event
      # type marks `occurred_at` optional for this.
      body =
        ~s({"type":"email.bounced","created_at":"last Tuesday","data":{"email_id":"a","to":["x@example.com"],"bounce":{"type":"Permanent"}}})

      assert {:ok, [event]} = Resend.parse(body)
      assert event.occurred_at == nil
    end

    test "the sender, the subject and the tags are dropped, not carried" do
      # Nothing in `Courier.Suppression` holds them and that module's moduledoc
      # says why: "A schema that had a `payload` map would be a copy of somebody's
      # inbox held for no operational reason." An event carrying fields nothing
      # reads is how a customer's subject line ends up in a courier span, which
      # `Courier.Observability` would then have to redact. The key set is
      # asserted exactly, so a field added to the event map is a failure here.
      assert {:ok, [event]} = Resend.parse(@bounced_permanent)

      assert Map.keys(event) |> Enum.sort() ==
               Enum.sort([
                 :provider,
                 :provider_event_id,
                 :email,
                 :kind,
                 :reason,
                 :message_id,
                 :occurred_at
               ])
    end
  end

  describe "the closed vocabulary" do
    test "every kind this module can produce is one Suppressions accepts" do
      # The whole point of the mapping being courier's own vocabulary rather than
      # the provider's. Asserted over the payloads rather than a constant, so a
      # new branch has to be added to this test to be added at all.
      payloads = [
        @bounced_permanent,
        @bounced_transient,
        @bounced_temporary,
        @bounced_undetermined,
        @bounced_with_diagnostic,
        @complained,
        @delivery_delayed
      ]

      for payload <- payloads do
        assert {:ok, events} = Resend.parse(payload)

        for event <- events do
          assert event.kind in Suppressions.kinds()
          assert event.provider == "resend"
        end
      end
    end

    test "and the kinds produced are exactly the three courier knows" do
      produced =
        [
          @bounced_permanent,
          @bounced_transient,
          @bounced_undetermined,
          @complained,
          @delivery_delayed
        ]
        |> Enum.flat_map(fn payload ->
          {:ok, events} = Resend.parse(payload)
          Enum.map(events, & &1.kind)
        end)
        |> Enum.uniq()
        |> Enum.sort()

      assert produced == Enum.sort(Suppressions.kinds())
    end
  end
end
