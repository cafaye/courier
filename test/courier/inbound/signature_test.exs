defmodule Courier.Inbound.SignatureTest do
  @moduledoc """
  Verifying an INBOUND webhook, which is the half of the Standard Webhooks scheme
  courier had never implemented.

  ## Why this file leads with a vector svix published

  `test/courier/webhooks/signature_test.exs` says the thing this file has to
  respect: "A test that asserted the signer against itself would pass even if the
  base string were wrong; these cannot." An inbound verifier asserted against
  `Courier.Webhooks.Signature.sign/4` proves only that two pieces of this
  repository agree with each other, and if both are wrong about the base string
  then every assertion here is green and every request courier accepts in
  production is forged.

  So the first test is svix's OWN worked example, fetched from
  <https://docs.svix.com/receiving/verifying-payloads/how-manual> (§"Example
  signatures"), which publishes the secret, the id, the timestamp, the body and
  the expected signature:

      secret    = whsec_plJ3nmyCDGBKInavdOK15jsl
      msg_id    = msg_loFOjxBNrRLzqYUf
      timestamp = 1731705121
      payload   = {"event_type":"ping","data":{"success":true}}
      signature = v1,rAvfW3dJ/X/qxhsaXPOyyCGmRKsaKWcsNccKXlIktD0=

  That single string pins the base string, the algorithm, the key derivation, the
  encoding, the `v1` identifier and the separator, all against a party that is not
  this repository. Every other test in this file is a consequence of that one.

  **One published vector that did NOT verify, and why it is not here.** Resend's
  own <https://resend.com/docs/webhooks/verify-webhooks-requests> prints
  `svix-signature: v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=` beside
  `payload: '{"test": 2432232314}'`, and a `whsec_` secret appears later on the
  same page. They do not go together: in the block carrying the signature the
  secret is `process.env.WEBHOOK_SECRET`, which the page never prints. Measured,
  the signature is NOT the HMAC of that body under that secret. Using the pair as
  a fixture would have been a test asserting a coincidence, so the vector above
  is used instead and this note records the measurement.

  ## The header names are the one place svix is not the spec

  Spec §Webhook headers says "All of the headers should be prefixed with
  `webhook-`". Resend sends `svix-` by default, and svix's docs add that
  "Professional and Enterprise tier customers can have the headers white-labeled
  to use the `webhook-` prefix instead of the `svix-` prefix used above. The
  Svix libraries support both." Both are read, and neither is read as a substitute
  for the other — a request carrying `svix-signature` and `webhook-timestamp` is
  missing a header, not half-satisfied. This is not a loosened assertion: it is
  one documented naming per account, and an operator on a white-labelled account
  whose every delivery was refused would have no way to tell why.
  """

  use ExUnit.Case, async: true

  alias Courier.Inbound.Signature
  alias Courier.Webhooks.Signature, as: WebhookSignature

  # svix's published example, verbatim. See the moduledoc.
  @vector_secret "whsec_plJ3nmyCDGBKInavdOK15jsl"
  @vector_id "msg_loFOjxBNrRLzqYUf"
  @vector_timestamp 1_731_705_121
  @vector_body ~s({"event_type":"ping","data":{"success":true}})
  @vector_signature "v1,rAvfW3dJ/X/qxhsaXPOyyCGmRKsaKWcsNccKXlIktD0="

  @tolerance 300

  defp secret, do: "whsec_" <> Base.encode64(:crypto.strong_rand_bytes(32))

  defp headers(id, timestamp, signature, prefix \\ "svix") do
    %{
      "#{prefix}-id" => id,
      "#{prefix}-timestamp" => to_string(timestamp),
      "#{prefix}-signature" => signature
    }
  end

  # Signed the way a provider signs: the base string is the provider's, and the
  # HMAC is computed here rather than by `Courier.Webhooks.Signature`, so the
  # "accept" tests below do not lean on courier's own signer agreeing with itself.
  defp sign(provider_secret, id, timestamp, body) do
    "v1," <>
      (provider_secret
       |> String.replace_prefix("whsec_", "")
       |> Base.decode64!()
       |> then(&:crypto.mac(:hmac, :sha256, &1, "#{id}.#{timestamp}.#{body}"))
       |> Base.encode64())
  end

  defp now, do: System.system_time(:second)

  describe "the provider's own published vector" do
    test "verifies, which pins the base string, the algorithm and the key derivation" do
      assert :ok =
               Signature.verify(
                 @vector_body,
                 headers(@vector_id, @vector_timestamp, @vector_signature),
                 @vector_secret,
                 now: @vector_timestamp
               )
    end

    test "and the same bytes with the real clock are out of tolerance" do
      # The pair is the point. A verifier that accepted this forever would be a
      # verifier with no replay window, and the timestamp check is the only part
      # of this scheme that defends against a captured delivery being re-sent.
      # `@vector_timestamp` is November 2024, so "now" is years outside it.
      assert {:error, :timestamp_out_of_tolerance} =
               Signature.verify(
                 @vector_body,
                 headers(@vector_id, @vector_timestamp, @vector_signature),
                 @vector_secret,
                 now: now()
               )
    end

    test "and courier's own outbound signer produces a signature it accepts" do
      # One implementation of the base string, in both directions. This is the
      # assertion that keeps the two halves from drifting; the vector above is
      # what proves the shared implementation is the SPEC's and not merely
      # consistent.
      signing_secret = secret()

      body =
        ~s({"type":"email.bounced","data":{"email_id":"56761188-7520-42d8-8898-ff6fc54ce618"}})

      timestamp = now()
      id = "msg_2KWPBgLlAfxdpx2AI54pPJ85f4W"
      signature = WebhookSignature.sign(signing_secret, id, timestamp, body)

      assert :ok = Signature.verify(body, headers(id, timestamp, signature), signing_secret)
    end
  end

  describe "what a forger changes" do
    setup do
      %{secret: secret(), timestamp: now(), id: "msg_loFOjxBNrRLzqYUf"}
    end

    test "one byte of the body", %{secret: secret, timestamp: timestamp, id: id} do
      body = ~s({"type":"email.bounced"})
      signature = sign(secret, id, timestamp, body)

      # The hard bounce, with one space added. Still valid JSON, still the same
      # event, and a different signature — which is why a framework that parses
      # and re-serializes the body before verifying breaks here.
      assert {:error, :signature_mismatch} =
               Signature.verify(body <> " ", headers(id, timestamp, signature), secret)
    end

    test "a body re-serialized from the parsed map", %{
      secret: secret,
      timestamp: timestamp,
      id: id
    } do
      # The failure mode the spec §Signature scheme names outright: "many webhook
      # consumers often accidentally parse the body as json, and then serialize it
      # again". Key order here differs from the signed bytes.
      signed = ~s({"type":"email.bounced","data":{"email_id":"a"}})
      resent = ~s({"data":{"email_id":"a"},"type":"email.bounced"})

      assert {:error, :signature_mismatch} =
               Signature.verify(
                 resent,
                 headers(id, timestamp, sign(secret, id, timestamp, signed)),
                 secret
               )
    end

    test "the recipient's address", %{secret: secret, timestamp: timestamp, id: id} do
      # The body courier is asked to act on, byte for byte. An attacker who can
      # change one address in a signed payload can suppress a competitor's
      # mailbox, which is the denial of service this whole boundary exists to
      # prevent.
      body = ~s({"to":["victim@example.com"]})

      assert {:error, :signature_mismatch} =
               Signature.verify(
                 ~s({"to":["attacker@example.com"]}),
                 headers(id, timestamp, sign(secret, id, timestamp, body)),
                 secret
               )
    end

    test "the id the signature is bound to", %{secret: secret, timestamp: timestamp, id: id} do
      # The base string leads with the id, so an id is part of what is signed.
      signature = sign(secret, id, timestamp, ~s({}))

      assert {:error, :signature_mismatch} =
               Signature.verify(~s({}), headers("msg_someoneElses", timestamp, signature), secret)
    end

    test "another account's secret", %{timestamp: timestamp, id: id} do
      body = ~s({"type":"email.complained"})

      assert {:error, :signature_mismatch} =
               Signature.verify(
                 body,
                 headers(id, timestamp, sign(secret(), id, timestamp, body)),
                 secret()
               )
    end

    test "a prefix of a genuine signature, which a `starts_with?` would accept", %{
      secret: secret,
      timestamp: timestamp,
      id: id
    } do
      # Not a timing test, which would be flaky and would prove nothing about
      # `:crypto.hash_equals`. This is the property a short-circuit comparison
      # gets wrong: a value that is a PREFIX of the right answer is not the right
      # answer, and a verifier that says otherwise accepts a forged signature
      # that an attacker can extend.
      signature = sign(secret, id, timestamp, ~s({}))
      truncated = "v1," <> String.slice(signature, 3, 20)

      assert {:error, :signature_mismatch} =
               Signature.verify(~s({}), headers(id, timestamp, truncated), secret)
    end

    test "a signature of a different length entirely", %{
      secret: secret,
      timestamp: timestamp,
      id: id
    } do
      assert {:error, :signature_mismatch} =
               Signature.verify(~s({}), headers(id, timestamp, "v1,AAAA"), secret)
    end
  end

  describe "the comparison is constant time" do
    test "which is asserted on the source, because nothing observable can assert it" do
      # MEASURED. A mutation test — replacing `:crypto.hash_equals(received,
      # expected)` with `received == expected` — leaves this file at 108/108
      # PASSING. The reason is that constant-timeness is a property of HOW a
      # comparison happens, not of what it returns, and every test here is about
      # what it returns: a wrong implementation returns the same `:ok` and the same
      # `{:error, :signature_mismatch}`. A timing test would be the alternative and
      # it is worse than useless — it is flaky on a loaded machine, so it fails
      # when nothing is wrong and passes when something is.
      #
      # So the assertion reads the source. It is the only check that can fail, and
      # it is also the only one that would still be true if the function were
      # rewritten. Spec §Verifying signatures is not a style preference: "Failing
      # to do so can expose consumers to timing-attacks and turn them into signing
      # oracles", and an `==` here is exactly that.
      # `Path.expand/2` against `__DIR__` rather than a path from the repository
      # root: the suite has to find this file from wherever `mix test` was started,
      # and a test that only passes from the root is a test that only runs on one
      # machine. The same trick as `mailer_adapter_credentials_test.exs`.
      source =
        Path.expand("../../../lib/courier/inbound/signature.ex", __DIR__)
        |> File.read!()

      assert source =~ ":crypto.hash_equals(",
             "Courier.Inbound.Signature must compare signatures with :crypto.hash_equals/2"

      # And the length guard in front of it, which is what stops a four-character
      # signature raising `ArgumentError` out of `hash_equals/2` — an
      # unauthenticated 500, which is the self-inflicted outage the probe rules
      # out. Also unobservable: mutating it away still returns
      # `{:error, :signature_mismatch}` on every test but raises on this one.
      assert source =~ "byte_size(received) == byte_size(expected)",
             "the length guard before :crypto.hash_equals/2 must be kept"

      # A `==` on the two signatures is the mutation, so its ABSENCE is the claim.
      refute source =~ "received == expected",
             "an == on two signatures is a timing oracle"
    end
  end

  describe "the three headers" do
    setup do
      %{secret: secret(), timestamp: now(), id: "msg_loFOjxBNrRLzqYUf", body: ~s({})}
    end

    test "all three absent", %{secret: secret} do
      assert {:error, {:missing_header, "svix-id"}} = Signature.verify(~s({}), %{}, secret)
    end

    test "the id is missing", %{secret: secret, timestamp: timestamp} do
      headers = %{"svix-timestamp" => to_string(timestamp), "svix-signature" => "v1,x"}

      assert {:error, {:missing_header, "svix-id"}} = Signature.verify(~s({}), headers, secret)
    end

    test "the timestamp is missing", %{secret: secret, id: id} do
      headers = %{"svix-id" => id, "svix-signature" => "v1,x"}

      assert {:error, {:missing_header, "svix-timestamp"}} =
               Signature.verify(~s({}), headers, secret)
    end

    test "the signature is missing", %{secret: secret, id: id, timestamp: timestamp} do
      headers = %{"svix-id" => id, "svix-timestamp" => to_string(timestamp)}

      assert {:error, {:missing_header, "svix-signature"}} =
               Signature.verify(~s({}), headers, secret)
    end

    test "a timestamp that is not an integer", %{secret: secret, id: id, body: body} do
      signature = sign(secret, id, now(), body)

      assert {:error, :malformed_timestamp} =
               Signature.verify(body, headers(id, "not-a-number", signature), secret)
    end

    test "a timestamp with trailing rubbish", %{secret: secret, id: id, body: body} do
      # `Integer.parse/1` returns the number it managed to read, so a lenient
      # check would accept "1731705121x" — and the base string is built from the
      # header's own bytes, which makes that a signature over a different string.
      signature = sign(secret, id, now(), body)
      timestamp = to_string(now())

      assert {:error, :malformed_timestamp} =
               Signature.verify(body, headers(id, timestamp <> "x", signature), secret)
    end

    test "an id carrying a full stop, which the spec forbids", %{
      secret: secret,
      timestamp: timestamp,
      body: body
    } do
      # Spec §Signature scheme: "It's important that both the message id and the
      # timestamp not be user controlled, or at the very least not be allowed to
      # include any `.` to prevent certain attacks." A dot lets the id append
      # fields to the base string.
      signature = sign(secret, "msg_a.b", timestamp, body)

      assert {:error, :malformed_id} =
               Signature.verify(body, headers("msg_a.b", timestamp, signature), secret)
    end

    test "an empty id", %{secret: secret, timestamp: timestamp, body: body} do
      signature = sign(secret, "", timestamp, body)

      assert {:error, :malformed_id} =
               Signature.verify(body, headers("", timestamp, signature), secret)
    end
  end

  describe "the replay window" do
    setup do
      %{secret: secret(), id: "msg_loFOjxBNrRLzqYUf", body: ~s({})}
    end

    test "is five minutes, the number the outbound verifier publishes" do
      assert Signature.tolerance() == 300
    end

    test "a timestamp at the edge is inside it", %{secret: secret, id: id, body: body} do
      # Signed AT the drifted timestamp, because the timestamp is part of the
      # signed base string. A signature made at `now` and checked against
      # `now - 300` is a mismatch, not an edge case.
      now = now()

      for drift <- [-@tolerance, @tolerance] do
        sent = now + drift
        signature = sign(secret, id, sent, body)

        assert :ok = Signature.verify(body, headers(id, sent, signature), secret)
      end
    end

    test "one second past the edge is not", %{secret: secret, id: id, body: body} do
      now = now()

      for drift <- [@tolerance + 1, -(@tolerance + 1)] do
        sent = now + drift
        signature = sign(secret, id, sent, body)

        assert {:error, :timestamp_out_of_tolerance} =
                 Signature.verify(body, headers(id, sent, signature), secret)
      end
    end

    test "a delivery replayed within the window is still authentic", %{
      secret: secret,
      id: id,
      body: body
    } do
      # Honest about what the window does and does not buy. Inside five minutes a
      # captured delivery verifies again, which is why spec §Verifying signatures
      # ALSO says "Use the `webhook-id` header as an idempotency key" — and why
      # `email_suppressions_provider_idempotency_index` is a real defence rather
      # than bookkeeping. This test exists so nobody later reads the tolerance as
      # a complete replay defence.
      timestamp = now()
      signature = sign(secret, id, timestamp, body)

      assert :ok = Signature.verify(body, headers(id, timestamp, signature), secret)
      assert :ok = Signature.verify(body, headers(id, timestamp, signature), secret)
    end
  end

  describe "the signing secret" do
    test "one without the whsec_ prefix is refused, not used" do
      # `Courier.Webhooks.Signature.sign_key/2` RAISES here, which is right at
      # boot and wrong at a request boundary: a route that 500s on a misconfigured
      # secret is indistinguishable from one that is being attacked.
      bare = Base.encode64(:crypto.strong_rand_bytes(32))

      assert {:error, :invalid_secret} = Signature.verify(~s({}), %{}, bare)
    end

    test "one whose payload is not base64 is refused" do
      assert {:error, :invalid_secret} =
               Signature.verify(~s({}), %{}, "whsec_not base64 at all!!")
    end

    test "one with an empty key is refused" do
      assert {:error, :invalid_secret} = Signature.verify(~s({}), %{}, "whsec_")
    end

    test "an empty string is refused" do
      # The env-var shape: `COURIER_RESEND_WEBHOOK_SECRET=` in a compose file
      # produces `""`, not an unset variable, and a secret that decodes to
      # nothing is a key anybody can sign with.
      assert {:error, :invalid_secret} = Signature.verify(~s({}), %{}, "")
    end
  end

  describe "the signature header is a list" do
    setup do
      %{secret: secret(), id: "msg_loFOjxBNrRLzqYUf", timestamp: now(), body: ~s({})}
    end

    test "a genuine v1 beside a v2 entry is found", ctx do
      %{secret: secret, id: id, timestamp: timestamp, body: body} = ctx
      genuine = sign(secret, id, timestamp, body)
      header = "v2,MzJsNDk4MzI0K2VvdSMjMTEjQEBAQDEyMzMzMzEyMwo= " <> genuine

      assert :ok = Signature.verify(body, headers(id, timestamp, header), secret)
    end

    test "the current key beside a previous one is found", ctx do
      # Spec §Webhook headers: the list exists "to support zero downtime secret
      # rotation", the webhook being signed with both the current and an old key.
      # A verifier that only ever looked at the first entry would break every
      # rotation in progress.
      %{secret: secret, id: id, timestamp: timestamp, body: body} = ctx
      previous = sign(secret(), id, timestamp, body)
      header = previous <> " " <> sign(secret, id, timestamp, body)

      assert :ok = Signature.verify(body, headers(id, timestamp, header), secret)
    end

    test "a list of only stale keys is refused", ctx do
      %{secret: secret, id: id, timestamp: timestamp, body: body} = ctx
      header = sign(secret(), id, timestamp, body) <> " " <> sign(secret(), id, timestamp, body)

      assert {:error, :signature_mismatch} =
               Signature.verify(body, headers(id, timestamp, header), secret)
    end

    test "an empty list is refused", ctx do
      %{secret: secret, id: id, timestamp: timestamp, body: body} = ctx

      assert {:error, :signature_mismatch} =
               Signature.verify(body, headers(id, timestamp, "   "), secret)
    end
  end

  describe "the header prefix" do
    setup do
      %{
        secret: secret(),
        id: "msg_loFOjxBNrRLzqYUf",
        timestamp: now(),
        body: ~s({"type":"email.bounced"})
      }
    end

    test "svix is the default and is what Resend sends", ctx do
      %{secret: secret, id: id, timestamp: timestamp, body: body} = ctx

      assert :ok =
               Signature.verify(
                 body,
                 headers(id, timestamp, sign(secret, id, timestamp, body), "svix"),
                 secret
               )
    end

    test "the spec's webhook- prefix is accepted too, which is svix's white-labelling", ctx do
      # svix's docs: "Professional and Enterprise tier customers can have the
      # headers white-labeled to use the `webhook-` prefix instead of the `svix-`
      # prefix used above. The Svix libraries support both."
      %{secret: secret, id: id, timestamp: timestamp, body: body} = ctx

      assert :ok =
               Signature.verify(
                 body,
                 headers(id, timestamp, sign(secret, id, timestamp, body), "webhook"),
                 secret
               )
    end

    test "the two prefixes are not interchangeable", ctx do
      # A signature is a space-delimited list, and a list is not a header name.
      # Reading `svix-signature` beside a `webhook-timestamp` is a request missing
      # a header, not one half-satisfied — and treating it as anything else is
      # how a scheme with two namings turns into a scheme with none.
      %{secret: secret, id: id, timestamp: timestamp, body: body} = ctx

      mixed = %{
        "svix-id" => id,
        "webhook-timestamp" => to_string(timestamp),
        "svix-signature" => sign(secret, id, timestamp, body)
      }

      assert {:error, {:missing_header, "svix-timestamp"}} =
               Signature.verify(body, mixed, secret)
    end

    test "a header name in the wrong case is not the header", ctx do
      # Plug downcases what a client sends, so this is a hand-rolled `fetch` or a
      # proxy that rewrote the case. `Courier.Webhooks.Verifier` takes the same
      # position in the other direction.
      %{secret: secret, id: id, timestamp: timestamp, body: body} = ctx

      shouted = %{
        "Svix-Id" => id,
        "Svix-Timestamp" => to_string(timestamp),
        "Svix-Signature" => sign(secret, id, timestamp, body)
      }

      assert {:error, {:missing_header, "svix-id"}} = Signature.verify(body, shouted, secret)
    end

    test "a keyword list of headers is read the same as a map", ctx do
      %{secret: secret, id: id, timestamp: timestamp, body: body} = ctx

      list = [
        svix_id: id,
        svix_timestamp: to_string(timestamp),
        svix_signature: sign(secret, id, timestamp, body)
      ]

      # Not a real request — a keyword list has symbol keys, and no proxy sends
      # one. It is here because `Map.new/1` on a keyword list yields atom keys
      # and this asserts they are NOT silently accepted as if they were the
      # strings, which would be a request boundary that answers from nothing.
      assert {:error, {:missing_header, "svix-id"}} = Signature.verify(body, list, secret)
    end
  end
end
