defmodule CourierWeb.Plugs.ParseBodyTest do
  @moduledoc """
  The one thing this plug does that it did not used to, and the whole reason the
  inbound surface can exist.

  ## The claim

  **An unauthenticated body reaches no decoder.** `Courier.Inbound.Signature`
  refuses anything but the bytes that arrived, and spec §Signature scheme names
  parse-then-re-serialize as "a very common failure mode" of verification — so
  that refusal is only the right refusal if nothing upstream has already decoded
  the body and written a different one.

  `CourierWeb.Plugs.ParseBody` is an **endpoint** plug, not a router one. It runs
  on every request courier serves, including `POST /inbound/resend`, and
  `Plug.Parsers` with the `:json` parser would decode the body of a request whose
  signature has not been checked. The route's own tests assert the consequence
  behaviourally — an unsigned but well-formed bounce records nothing — and this
  file asserts the mechanism, because a behavioural test cannot tell "the parser
  did not run" from "the parser ran and the controller ignored the result".

  ## Why this file has no database

  Because its subject is two functions and a conn. `Plug.Parsers` reads bytes
  and `CourierWeb.Router.signed_body?/1` matches a string, and neither of those
  is a thing postgres can lie about. The rows are the *route's* subject and they
  are asserted in `CourierWeb.InboundControllerTest`.

  ## And the direction that matters just as much

  A skip that leaked onto another route would be a body courier stopped parsing
  on a path whose controller expects `conn.params` — a 500 on `POST /v1/messages`
  for every send, in production, with nothing in the failure naming the plug. So
  the last two tests here are the negative half: the skip is for `resend` and
  nothing else, and the other five operations still parse.
  """

  use ExUnit.Case, async: true

  import Plug.Conn

  alias CourierWeb.Plugs.ParseBody
  alias CourierWeb.Router

  @options [
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason
  ]

  @signed "/inbound/resend"
  @parsed "/v1/messages"

  # `Plug.Test.conn/3` fully qualified, because `Plug.Conn.conn/3` is also imported
  # and it is a different function with the same arity — a builder for a Plug's
  # own `conn/3`, not a test request. The shadowed one is the sort of ambiguity
  # that produces a `MatchError` about `Plug.Parsers`' options and takes twenty
  # minutes to read as anything to do with authentication.
  defp request(path, body) do
    Plug.Test.conn(:post, path, body)
    |> put_req_header("content-type", "application/json")
  end

  # `init/1` before `call/2`, and that is not optional. `config :phoenix,
  # :plug_init_mode, :runtime` means the endpoint's plug builder runs `init/1` at
  # boot and hands `call/2` the **compiled** options — a four-element tuple — rather
  # than the keyword list written in the endpoint. `Plug.Parsers.call/2` pattern
  # matches that tuple, so calling it with the raw list is a `MatchError` whose
  # right-hand side is the whole option list, which reads like nothing to do with
  # parsing. `ParseBody.init/1` passes straight through, so the same call shape
  # works here and in the endpoint.
  defp parse(conn), do: ParseBody.call(conn, ParseBody.init(@options))

  defp call(path, body) do
    path |> request(body) |> parse()
  end

  # The bytes, read the way the action reads them. On a route the plug skipped,
  # nothing else has read the body, so `conn.body` is unset until somebody asks —
  # and what comes back is the request's own bytes.
  defp bytes(conn) do
    {:ok, body, _conn} = read_body(conn)
    body
  end

  describe "a signed inbound body" do
    test "is left exactly as it arrived" do
      # A body a real provider signed. The bytes here are the ones
      # `Courier.TestSupport.FakeResend` writes, and the assertion is that this
      # plug did not touch them — which is the whole property, stated as a fact
      # about the conn rather than as a fact about a refusal.
      body = ~s({"type":"email.bounced","created_at":"2026-11-22T23:41:12.126Z","data":{}})

      assert call(@signed, body) |> bytes() == body
    end

    test "is not decoded, so there are no body_params for a controller to trust" do
      # `Plug.Parsers` leaves `conn.params` and `conn.body_params` as
      # `Plug.Conn.Unfetched` when it does not run. That is what the action sees,
      # and it is why `CourierWeb.InboundController` reads `conn.body` rather than
      # `params["type"]`: a controller that reached for a parsed field would get
      # `nil` here rather than a decode of an unauthenticated body, which is a
      # safe failure and not a silent one.
      conn = call(@signed, ~s({"type":"email.bounced"}))

      assert %Plug.Conn.Unfetched{} = conn.body_params
      assert %Plug.Conn.Unfetched{} = conn.params
    end

    test "a malformed one is not answered 400 here either" do
      # This is the sharpest consequence. On every other route courier's 400 for a
      # body that is not JSON is correct, and it is raised before the router runs.
      # On this route it would tell whoever forges a webhook that courier decoded
      # their body, so the request has to reach the action and be refused there —
      # as a 401, because courier never looks at the bytes.
      conn = call(@signed, "{not json")

      refute conn.halted
      assert %Plug.Conn.Unfetched{} = conn.body_params
      assert bytes(conn) == "{not json"
      assert conn.status == nil
    end

    test "and it is not halted, so the action runs" do
      conn = call(@signed, "{}")

      refute conn.halted
    end

    test "the trailing slash spelling is skipped too" do
      # `Phoenix.Router` matches `/inbound/resend/` to the same route, so a check
      # that only knew the spelling without the slash would parse exactly the
      # request a copy-pasted URL produces — and the failure would be a 401 for a
      # correctly-signed body, with nothing in it saying why.
      assert Router.signed_body?("/inbound/resend/")
      assert "/inbound/resend/" |> request("{}") |> parse() |> bytes() == "{}"
    end
  end

  describe "every other route" do
    test "is still parsed" do
      # The negative half of the whole claim. A skip that leaked would make
      # `POST /v1/messages` a 500 on every send.
      conn = call(@parsed, ~s({"type":"welcome"}))

      assert conn.body_params == %{"type" => "welcome"}
    end

    test "and a malformed body on it is still courier's 400" do
      # `CourierWeb.Plugs.ParseBody` is the only reason that body is problem+json
      # rather than Phoenix's own, and `openapi_error_responses_test.exs` asserts
      # the 400 is declared on every operation that can reach it.
      conn = call(@parsed, "{not json")

      assert conn.halted
      assert conn.status == 400
      assert [content_type] = get_resp_header(conn, "content-type")
      assert String.starts_with?(content_type, "application/problem+json")
    end
  end

  describe "the path list" do
    test "names only routes the router serves" do
      # A rename that left the list behind would parse a body whose signature
      # covers re-encoded bytes, and the symptom is a 401 with nothing naming the
      # plug. `Router.signed_body_paths/0` is checked against the router's own
      # `__routes__/0` here rather than trusted.
      for path <- Router.signed_body_paths() do
        assert Enum.any?(Router.__routes__(), &(&1.path == path and &1.verb == :post)),
               "#{path} is in `signed_body_paths/0` and no POST route serves it. A " <>
                 "rename left the list behind, and this is the check that makes a rename " <>
                 "visible rather than a 401 with nothing naming the plug."
      end
    end

    test "and the inbound route is in it" do
      # The other direction, and the one that matters more: an empty list would
      # pass the test above and the route would parse every body it is sent.
      assert @signed in Router.signed_body_paths()
    end

    test "a path that is not one is not skipped" do
      refute Router.signed_body?("/v1/messages")
      refute Router.signed_body?("/healthz")
      # Not a prefix match, either: `/inbound/resendx` is a different path and
      # would 404, so parsing it costs nothing and skipping it would be a claim
      # about a route that does not exist.
      refute Router.signed_body?("/inbound/resendx")
      refute Router.signed_body?("/")
      refute Router.signed_body?(nil)
    end
  end
end
