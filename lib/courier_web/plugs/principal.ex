defmodule CourierWeb.Plugs.Principal do
  @moduledoc """
  Resolves who is calling, and refuses the request when nobody is.

  ## This is a seam, not authentication

  courier does not verify JWTs yet — identity issues them and the packet that
  verifies them has not landed. This plug exists because webhook endpoints are the
  first courier resource where that gap would be a breach rather than an
  inconvenience: an endpoint's url and its signing secret are a way to make
  courier send signed requests on someone's behalf, and a list endpoint with no
  authentication is a way to enumerate them.

  So the shape is settled now and the verifier arrives later. What is settled:

    * **A request with no principal is a 401, always.** courier never guesses an
      account for an anonymous caller, and it never falls back to a default one.
    * **The account comes from the principal, never from the body.** Every
      controller reads `conn.assigns.current_account` and the context is called
      with that; an `account_id` in a request body is ignored, and the tests say so
      on every action that would be affected.
    * **The default resolver authenticates nothing.** `Courier.Principal.Reject`
      answers `:error` to everything, so a deployed courier without the JWT packet
      refuses every webhook request rather than serving them to whoever asks. A
      missing verifier is a locked door, not an open one.

  The header the test resolver reads (`x-courier-account`) is a stand-in for the
  verified claim, and it is only ever read when `config :courier, :principal`
  points at a resolver that reads it. In the default configuration no header makes
  a request authenticated, so this cannot be mistaken for a bypass.

  ## Why the account and not a role

  Core's OpenAPI conventions are explicit: "`scopes` for capability, `account_id`
  for tenancy… Services do not parse roles out of a `roles` claim — they check
  `scopes`, or ask identity." courier therefore has no notion of owner / admin /
  member, and the authorization matrix is expressed in those two terms: is there a
  principal, is this their account, and is the action permitted on it. A future
  role check is one more question in this plug, not a new authorization model.
  """

  import Plug.Conn

  alias Courier.Principal
  alias CourierWeb.Problem

  @account_header "x-courier-account"

  @doc false
  def account_header, do: @account_header

  @doc """
  Assigns `:current_account` from the configured resolver, or answers 401.

  The 401 is courier's problem+json like every other non-2xx, built by
  `CourierWeb.Problem`, so an unauthenticated request is the same shape as every
  other error a client has to parse.
  """
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def init(opts), do: opts

  def call(conn, _opts) do
    case resolver().resolve(conn) do
      {:ok, %Principal{account_id: account_id}} ->
        assign(conn, :current_account, account_id)

      :error ->
        unauthorized(conn)
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_resp_content_type("application/problem+json")
    |> send_resp(
      401,
      Jason.encode!(
        Problem.build(
          conn.assigns,
          401,
          :unauthorized,
          "This request needs an authenticated caller."
        )
      )
    )
    |> halt()
  end

  @doc """
  The resolver configured for this deployment.

  Defaults to the one that authenticates nothing, so the absence of a configured
  verifier is a refusal rather than a silent gap.
  """
  @spec resolver() :: module()
  def resolver, do: Application.get_env(:courier, :principal, Courier.Principal.Reject)
end
