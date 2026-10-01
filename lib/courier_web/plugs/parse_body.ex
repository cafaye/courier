defmodule CourierWeb.Plugs.ParseBody do
  @moduledoc """
  `Plug.Parsers`, with courier's answer for a body it cannot parse.

  The only reason this is a module of its own: a body that is not JSON raises
  before the router runs, so the `:api` pipeline is too late to catch it, and the
  default answer would be Phoenix's own rather than the problem+json every other
  error in courier uses. 400 is right, and is core's status convention for
  exactly this: malformed syntax the client could not have known.

  The parser options stay in the endpoint, where the generated application had
  them, and are passed straight through — this plug translates one exception,
  changes nothing else, and **leaves the body of a signed inbound webhook alone**
  so the bytes a signature covers are the bytes that arrive. The detail it reports
  is deliberately short: the parser's own message quotes the body, and a
  repository that is public should not put a request body into a response.
  """

  import Plug.Conn

  alias CourierWeb.Problem
  alias CourierWeb.Router

  def init(opts), do: Plug.Parsers.init(opts)

  # **A signed body is not parsed here, and that is the security property.**
  #
  # Spec §Signature scheme names parse-then-re-serialize "a very common failure
  # mode" of signature verification: the signature covers `msg_id.timestamp.
  # payload`, so a body that has been decoded and re-encoded is a body whose bytes
  # are not the bytes that were signed. `Courier.Inbound.Signature` refuses
  # anything but the received bytes, which is only the right refusal if nothing
  # upstream has already rewritten them.
  #
  # This plug is in the ENDPOINT, so it runs on every request including a route
  # that has to see the raw bytes — and skipping it is the only way to keep the
  # order `Courier.Inbound` is built around: **an unauthenticated body reaches no
  # decoder at all.** Without the skip, a `POST` to `/inbound/resend` with an
  # unsigned body is decoded by `Plug.Parsers` before `Courier.Inbound.Signature`
  # ever sees it, and the claim in `Courier.Inbound`'s moduledoc would be true of
  # the library and false of the route in front of it.
  #
  # It is also what makes the 400 on that route mean something. A malformed body
  # is 400 because a client could not have known; an *unsigned* malformed body on
  # an inbound route is a 401, because courier refuses before it looks at a byte.
  # Parsing first would answer 400 for both and make the two indistinguishable.
  #
  # The list of paths lives in `CourierWeb.Router.signed_body_paths/0` rather than
  # here, so a renamed route takes the exception with it —
  # `test/courier_web/router_test.exs` asserts every path in it is a route the
  # router serves.
  def call(conn, opts) do
    if Router.signed_body?(conn.request_path) do
      conn
    else
      Plug.Parsers.call(conn, opts)
    end
  rescue
    _error in Plug.Parsers.ParseError ->
      conn
      |> Problem.send(400, :bad_request, "The request body is not valid JSON.")
      |> halt()
  end
end
