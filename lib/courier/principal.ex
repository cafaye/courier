defmodule Courier.Principal do
  @moduledoc """
  The caller of a request, as far as courier can tell.

  A struct rather than a bare account id so that what courier knows about a caller
  is visible in one place and adding a field later (a subject, scopes) does not
  change the shape of every call site.

  There is no role here, and that is deliberate: core's OpenAPI conventions say
  "Services do not parse roles out of a `roles` claim — they check `scopes`, or ask
  identity." courier checks `account_id` for tenancy and asks identity about
  capability, so a `role` field on this struct would be a thing nothing reads.
  """

  @type t :: %__MODULE__{
          account_id: Ecto.UUID.t() | nil,
          subject: String.t() | nil
        }

  defstruct account_id: nil, subject: nil
end

defmodule Courier.Principal.Resolver do
  @moduledoc """
  The behaviour `CourierWeb.Plugs.Principal` asks who is calling.

  A behaviour with a refusing default rather than a direct JWT call, so the shape
  of "who is calling" is settled now — before the packet that fills it in — and a
  deployment with no verifier configured refuses every webhook request instead of
  serving them to anyone who asks.
  """

  @typedoc "`{:ok, principal}` for an authenticated caller, `:error` for anyone else."
  @type answer :: {:ok, Courier.Principal.t()} | :error

  @doc "Resolves the caller of `conn`, or refuses."
  @callback resolve(Plug.Conn.t()) :: answer()
end

defmodule Courier.Principal.Reject do
  @moduledoc """
  The default resolver: it authenticates nobody.

  courier does not verify JWTs yet. This is what a deployed courier gets until the
  identity packet lands, and it is the safe direction: every webhook request is a
  401 rather than an unauthenticated read of another account's endpoints.

  A caller that *is* authenticated still needs this plug configured to something
  that can see it, which is a deliberate two-step rather than a default that
  guesses: a default that trusted a header would be an authentication bypass with
  a config file attached.
  """

  @behaviour Courier.Principal.Resolver

  @impl Courier.Principal.Resolver
  def resolve(_conn), do: :error
end
