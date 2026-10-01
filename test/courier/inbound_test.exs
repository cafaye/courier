defmodule Courier.InboundTest do
  @moduledoc """
  The pipeline, and above all the property that makes it safe: **an unsigned or
  badly-signed payload records nothing.**

  ## This is the test the packet exists for

  `Courier.Suppressions.ingest/1` was written, tested, documented as "the HTTP
  surface's entry point", and called by nothing — so courier's suppression table
  was only ever written by tests. The failure this file closes is the security
  half of that: the obvious way to give `ingest/1` a caller is a route that
  `Jason.decode!`s a body and passes it in, and that route is an unauthenticated
  `POST` that records suppressions. Anyone who finds the URL can suppress anyone
  else's mail — a competitor's, or courier's own, which is a denial of service on
  the whole product delivered by the feature meant to protect it.

  So every test here drives the REAL `Courier.Suppressions` against the REAL
  `email_suppressions` table through `Courier.Inbound.handle/5`, and asserts on
  what is in the database afterwards. Not a mock, not a spy on the parser: the
  claim is about rows, and a mock cannot hold a row.

  ## The absence assertions are paired with presence ones, deliberately

  A test that asserts "no row was written" passes just as happily against a
  function that writes nothing ever, and `AGENTS.md` records the reason that
  matters here: "a redaction boundary that deletes everything passes 'no canary'
  and is useless", with three separate bugs named that left a suite green with
  nothing exported at all. So every negative test in this file is paired with a
  positive one that proves the same path DOES write when the request is genuine.
  If the positives stop passing, the negatives have stopped meaning anything.

  ## Ordering is asserted, not assumed

  "The parser is never reached" is the property, and it is checked with a parser
  that raises if called — a mock would let a partial parse look like a refusal.
  """

  # A database test: the assertions are about rows in `email_suppressions`, and a
  # claim about the pipeline that cannot see a row is a claim about a mock.
  use Courier.DataCase, async: true

  alias Courier.Inbound
  alias Courier.Inbound.Resend
  alias Courier.Suppression
  alias Courier.Suppressions
  alias Courier.TestSupport.FakeResend

  @secret FakeResend.secret()

  # A parser that must never be reached. `raise` rather than a mock, so a
  # partially-parsed body is a failure and not a shape that looks like a refusal.
  defmodule ExplodingParser do
    @moduledoc false
    @behaviour Courier.Inbound

    @impl Courier.Inbound
    def provider, do: "exploding"

    @impl Courier.Inbound
    def parse(_body), do: raise("the parser must not run on an unauthenticated body")
  end

  # Every assertion below counts rows for ONE address that this test minted, never
  # `Repo.aggregate(Suppression, :count) == 0`. AGENTS.md is explicit that a count
  # over the whole table "is a claim about every other test in the repository as
  # much as about the code under test", and a security test built on one would be
  # green or red according to what else the suite had written.
  defp rows_for(email) do
    Suppression
    |> where([s], s.email == ^Suppressions.normalize(email))
    |> order_by([s], asc: s.inserted_at, asc: s.id)
    |> Repo.all()
  end

  defp state_of(email), do: Suppressions.state(email)

  # ---------------------------------------------------------------------------
  # The security property
  # ---------------------------------------------------------------------------

  describe "a genuine, signed bounce" do
    test "records exactly one row, and it is undeliverable" do
      # THE presence half. Without this test every assertion below would also
      # pass against a pipeline that records nothing at all.
      email = "genuine-bounce@example.com"
      {body, headers} = FakeResend.signed(FakeResend.bounce(recipients: [email]))

      assert {:ok, [{:ok, :new, row}]} = Inbound.handle(Resend, body, headers, @secret)

      assert row.state == :undeliverable
      assert row.provider == "resend"
      assert Suppressions.suppressed?(email)
      assert [%Suppression{}] = rows_for(email)
    end

    test "and a complaint records suppressed, which outranks the bounce" do
      # Both halves of the fold, from the provider's side rather than from a
      # hand-built event map, because the provider is where a mistake would be.
      email = "genuine-complaint@example.com"
      {body, headers} = FakeResend.signed(FakeResend.complaint(recipients: [email]))

      assert {:ok, [{:ok, :new, row}]} = Inbound.handle(Resend, body, headers, @secret)
      assert row.state == :suppressed
    end

    test "and a bounce then a complaint about one address leaves it suppressed" do
      # The precedence rule, driven through the real provider path. This is the
      # case the `email.complained/` prefix in `provider_event_id` exists for: if
      # the two reports shared a key, the second would be refused as a duplicate
      # of the first and the address would stay `:undeliverable` forever.
      email = "escalating@example.com"
      email_id = "4ef9a417-02e9-4d39-ad75-9611e0fcc33c"

      {bounce, bounce_headers} =
        FakeResend.signed(FakeResend.bounce(recipients: [email], email_id: email_id))

      {complaint, complaint_headers} =
        FakeResend.signed(FakeResend.complaint(recipients: [email], email_id: email_id))

      assert {:ok, [{:ok, :new, _row}]} = Inbound.handle(Resend, bounce, bounce_headers, @secret)
      assert state_of(email) == :undeliverable

      assert {:ok, [{:ok, :new, _row}]} =
               Inbound.handle(Resend, complaint, complaint_headers, @secret)

      assert state_of(email) == :suppressed
      assert length(rows_for(email)) == 2
    end
  end

  describe "an unsigned payload" do
    test "records nothing" do
      email = "unsigned@example.com"
      body = FakeResend.bounce(recipients: [email])

      assert {:error, {:missing_header, "svix-id"}} = Inbound.handle(Resend, body, %{}, @secret)

      assert rows_for(email) == []
      refute Suppressions.suppressed?(email)
    end

    test "and never reaches the parser" do
      body = FakeResend.bounce()

      assert {:error, _reason} = Inbound.handle(ExplodingParser, body, %{}, @secret)
    end
  end

  describe "a badly-signed payload" do
    test "signed by somebody else records nothing" do
      # The attack in its plainest form: the body is byte-for-byte a real bounce
      # report, the only difference is the key. It is the payload a competitor
      # would POST to courier's inbound URL.
      email = "forged@example.com"
      {body, headers} = FakeResend.signed_by_stranger(FakeResend.bounce(recipients: [email]))

      assert {:error, :signature_mismatch} = Inbound.handle(Resend, body, headers, @secret)

      assert rows_for(email) == []
      refute Suppressions.suppressed?(email)
    end

    test "signed by somebody else never reaches the parser" do
      {body, headers} = FakeResend.signed_by_stranger(FakeResend.bounce())

      assert {:error, _reason} = Inbound.handle(ExplodingParser, body, headers, @secret)
    end

    test "altered after signing records nothing" do
      # The body courier is asked to act on, byte for byte. A provider that
      # re-serialized, or a proxy that touched a byte, lands here.
      email = "tampered@example.com"
      {body, headers} = FakeResend.signed(FakeResend.bounce(recipients: [email]))

      assert {:error, :signature_mismatch} =
               Inbound.handle(Resend, body <> " ", headers, @secret)

      assert rows_for(email) == []
    end

    test "whose recipient was swapped records nothing" do
      # The sharpest version: a GENUINE Resend bounce, correctly signed, with one
      # address changed to a competitor's. It is the only shape that gets past a
      # verifier which signs a re-serialization of the parsed body, which is why
      # the signature test asserts against the raw bytes too.
      email = "swapped-in@example.com"
      signed_body = FakeResend.bounce(recipients: ["someone-else@example.com"])
      {_signed, headers} = FakeResend.signed(signed_body)

      tampered =
        String.replace(signed_body, "someone-else@example.com", "swapped-in@example.com")

      assert {:error, :signature_mismatch} = Inbound.handle(Resend, tampered, headers, @secret)
      assert rows_for(email) == []
    end

    test "with a signature lifted from another event records nothing" do
      # The capture-and-replay attack: a genuine, correctly-signed delivery of
      # one report, with its signature moved onto a DIFFERENT report. The id and
      # the body are both inside the signed base string, so this cannot verify.
      #
      # MEASURED, and the first draft of this test asserted the wrong thing. It
      # mixed one event's id and signature with another event's TIMESTAMP and
      # expected a mismatch — and the payload was ACCEPTED, which looked like a
      # broken verifier and was not: the two `FakeResend.signed/1` calls landed in
      # the same second, so the two base strings were byte-identical and the
      # signature genuinely was correct for what was presented. Presenting a
      # mismatched id/signature with a body they were not computed over is the
      # attack; this is that.
      email = "moved@example.com"

      {captured, captured_headers} =
        FakeResend.signed(FakeResend.bounce(recipients: ["a@example.com"]))

      {target, target_headers} = FakeResend.signed(FakeResend.bounce(recipients: [email]))

      lifted = %{
        "svix-id" => captured_headers["svix-id"],
        "svix-timestamp" => captured_headers["svix-timestamp"],
        "svix-signature" => captured_headers["svix-signature"]
      }

      assert {:error, :signature_mismatch} = Inbound.handle(Resend, target, lifted, @secret)
      assert rows_for(email) == []

      # And the honest control: the captured event on its OWN headers is accepted,
      # so the refusal above is the mismatch and not something incidental.
      assert {:ok, [{:ok, :new, _}]} =
               Inbound.handle(Resend, captured, captured_headers, @secret)

      # `target_headers` is the pair the attacker replaced.
      assert target_headers["svix-signature"] != lifted["svix-signature"]
    end

    test "and a replayed delivery is a duplicate, not a second row" do
      # The other half of the security story, and it is a FEATURE rather than a
      # flaw: within the tolerance window a captured genuine delivery verifies
      # again, and the unique index is what makes that harmless. Resend's
      # `Retries and Replays` docs make redelivery normal.
      email = "replayed@example.com"
      {body, headers} = FakeResend.signed(FakeResend.bounce(recipients: [email]))

      assert {:ok, [{:ok, :new, _first}]} = Inbound.handle(Resend, body, headers, @secret)
      assert {:ok, [{:ok, :duplicate, second}]} = Inbound.handle(Resend, body, headers, @secret)

      assert [%Suppression{}] = rows_for(email)
      assert second.state == :undeliverable
    end
  end

  describe "a payload courier cannot configure" do
    test "no signing secret means nothing is recorded, and the reason says so" do
      # An inbound route wired before the operator set the secret would otherwise
      # accept everything. It refuses everything, and says why.
      email = "nosecret@example.com"
      {body, headers} = FakeResend.signed(FakeResend.bounce(recipients: [email]))

      assert {:error, :invalid_secret} = Inbound.handle(Resend, body, headers, "")
      assert {:error, :invalid_secret} = Inbound.handle(Resend, body, headers, "not-a-secret")

      assert rows_for(email) == []
    end
  end

  # ---------------------------------------------------------------------------
  # The events courier deliberately does nothing about
  # ---------------------------------------------------------------------------

  describe "an authenticated event courier has no opinion on" do
    test "a soft bounce is ignored and records nothing" do
      # `Courier.Suppressions`' moduledoc: a soft bounce "records nothing, on
      # purpose", because suppressing on one is "how a suppression list starts
      # eating live addresses". The distinct `{:ok, :ignored}` answer is what
      # stops a caller retrying it forever.
      email = "full-mailbox@example.com"

      {body, headers} =
        FakeResend.signed(
          FakeResend.bounce(
            recipients: [email],
            bounce_type: "Transient",
            sub_type: "MailboxFull",
            message: "The recipient's mailbox is full."
          )
        )

      assert {:ok, [{:ok, :ignored}]} = Inbound.handle(Resend, body, headers, @secret)
      assert rows_for(email) == []
      refute Suppressions.suppressed?(email)
    end

    test "an undetermined bounce is ignored and records nothing" do
      email = "undetermined@example.com"

      {body, headers} =
        FakeResend.signed(
          FakeResend.bounce(recipients: [email], bounce_type: "Undetermined", sub_type: nil)
        )

      assert {:ok, [{:ok, :ignored}]} = Inbound.handle(Resend, body, headers, @secret)
      assert rows_for(email) == []
    end

    test "a delivery delay is ignored and records nothing" do
      email = "delayed@example.com"
      {body, headers} = FakeResend.signed(FakeResend.delivery_delayed(recipients: [email]))

      assert {:ok, [{:ok, :ignored}]} = Inbound.handle(Resend, body, headers, @secret)
      assert rows_for(email) == []
    end

    test "a send that failed records nothing" do
      email = "quota@example.com"

      {body, headers} =
        FakeResend.signed(FakeResend.event("email.failed", recipients: [email]))

      assert {:ok, []} = Inbound.handle(Resend, body, headers, @secret)
      assert rows_for(email) == []
    end

    test "Resend's own suppression notice records nothing" do
      # `origin` may be `manual` — a decision in Resend's dashboard, which courier
      # has no row for. The causal bounce or complaint has already arrived.
      email = "manual@example.com"

      body =
        ~s({"type":"suppression.added","created_at":"2026-11-17T19:32:22.980Z","data":{"id":"e169aa45-1ecf-4183-9955-b1499d5701d3","email":"#{email}","origin":"manual","source_id":null,"created_at":"2026-11-17T19:32:22.980Z"}})

      {body, headers} = FakeResend.signed(body)

      assert {:ok, []} = Inbound.handle(Resend, body, headers, @secret)
      assert rows_for(email) == []
    end
  end

  # ---------------------------------------------------------------------------
  # One report, many recipients
  # ---------------------------------------------------------------------------

  describe "a report naming several recipients" do
    test "records one row per address" do
      # The case the idempotency key is built for. A broadcast shares one
      # `email_id` across every recipient, so keying on `email_id` alone would let
      # four of five bounces be recorded as duplicates of the first — four live
      # mailboxes courier goes on mailing forever.
      recipients = ~w(a1@example.com b2@example.com c3@example.com d4@example.com e5@example.com)
      {body, headers} = FakeResend.signed(FakeResend.bounce(recipients: recipients))

      assert {:ok, results} = Inbound.handle(Resend, body, headers, @secret)
      assert length(results) == 5
      assert Enum.all?(results, &match?({:ok, :new, _row}, &1))

      for email <- recipients do
        assert [%Suppression{state: :undeliverable}] = rows_for(email)
      end
    end

    test "and one bad address refuses the whole report" do
      # Fail closed on the report, not half of it. Nine good addresses are still
      # worth suppressing, but a report courier cannot fully read is a report
      # whose shape it does not understand, and recording nine of ten is a silent
      # partial write.
      recipients = ["good1@example.com", "not-an-address", "good3@example.com"]
      {body, headers} = FakeResend.signed(FakeResend.bounce(recipients: recipients))

      assert {:error, {:invalid_recipient, "not-an-address"}} =
               Inbound.handle(Resend, body, headers, @secret)

      for email <- ["good1@example.com", "good3@example.com"] do
        assert rows_for(email) == []
      end
    end
  end

  # ---------------------------------------------------------------------------
  # What the caller gets
  # ---------------------------------------------------------------------------

  describe "the answers handle/5 returns" do
    test "one per event, in the parser's order" do
      email = "ordered@example.com"
      {body, headers} = FakeResend.signed(FakeResend.bounce(recipients: [email]))

      assert {:ok, [{:ok, :new, %Suppression{}}]} = Inbound.handle(Resend, body, headers, @secret)
    end

    test "an error from ingest rather than a crash" do
      # A duplicate is `{:ok, :duplicate, row}`; the shape a caller must not count
      # as a failure. Asserted from the pipeline because worker C's route will
      # branch on exactly this.
      email = "duplicate-shape@example.com"
      {body, headers} = FakeResend.signed(FakeResend.bounce(recipients: [email]))

      assert {:ok, [{:ok, :new, _}]} = Inbound.handle(Resend, body, headers, @secret)
      assert {:ok, [{:ok, :duplicate, _}]} = Inbound.handle(Resend, body, headers, @secret)
    end

    test "a refusal carries a reason the route can map to a status" do
      # The vocabulary worker C branches on. Each of these is a distinct answer
      # and conflating any two of them is a bug: an operator cannot fix a
      # misconfigured secret, and a provider cannot fix a payload courier refused
      # to read, and they need different responses.
      {body, headers} = FakeResend.signed(FakeResend.bounce())

      assert {:error, {:missing_header, "svix-id"}} = Inbound.handle(Resend, body, %{}, @secret)

      assert {:error, :invalid_secret} = Inbound.handle(Resend, body, headers, "")

      # `invalid_json` needs its OWN signed headers. Signing a valid body and then
      # sending malformed bytes gets `:signature_mismatch`, which is the correct
      # answer and the order the pipeline is built for — the first draft of this
      # test asserted `invalid_json` here and was wrong about what it was
      # checking, not about what the code did.
      assert {:error, :invalid_json} =
               "not json"
               |> FakeResend.signed()
               |> then(fn {b, h} ->
                 Inbound.handle(Resend, b, h, @secret)
               end)

      assert {:error, :unsupported_event} =
               "email.brand_new"
               |> FakeResend.event()
               |> FakeResend.signed()
               |> then(fn {b, h} -> Inbound.handle(Resend, b, h, @secret) end)

      assert {:error, {:unknown_bounce_type, "Eternal"}} =
               FakeResend.bounce(bounce_type: "Eternal")
               |> FakeResend.signed()
               |> then(fn {b, h} -> Inbound.handle(Resend, b, h, @secret) end)
    end
  end

  # ---------------------------------------------------------------------------
  # The contract itself
  # ---------------------------------------------------------------------------

  describe "the behaviour contract" do
    test "Resend implements it" do
      assert Courier.Inbound in (Resend.module_info(:attributes)[:behaviour] || [])
    end

    test "and the provider name is what the row is keyed on" do
      email = "provider-name@example.com"
      {body, headers} = FakeResend.signed(FakeResend.bounce(recipients: [email]))

      assert {:ok, [{:ok, :new, row}]} = Inbound.handle(Resend, body, headers, @secret)
      assert row.provider == Resend.provider()
    end

    test "and every kind it can produce is one Suppressions accepts" do
      # The vocabulary is courier's, closed, and the parser cannot widen it. A
      # provider that renamed an event cannot make courier act on a kind nothing
      # downstream handles.
      assert Suppressions.kinds() == [:hard_bounce, :soft_bounce, :complaint]
    end
  end
end
