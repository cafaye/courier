defmodule Courier.Webhooks.Dns do
  @moduledoc """
  The resolver seam the URL guard goes through.

  A behaviour rather than a direct `:inet` call for one reason: the attack this
  guards against is a *DNS answer*, so a test that cannot control the answer
  cannot test the guard. `Courier.TestSupport.TestDns` returns a list the test
  wrote, which is how `Courier.Webhooks.UrlGuardTest` can show a public name
  answering with `127.0.0.1` and being refused.

  The contract is deliberately minimal — a host in, a list of answer strings
  out — so a fake is two lines and the production resolver is the only place
  that knows about resolvers at all.
  """

  @typedoc "Answers are the textual form of the addresses, as `:inet` hands them back."
  @type answer :: String.t()

  @doc """
  Every address `host` currently answers with.

  Returning *every* answer rather than the first is deliberate: a name that
  answers with one public and one private address is the DNS-rebinding shape,
  and a guard that only inspected the first would pass it.
  """
  @callback resolve(host :: String.t()) :: {:ok, [answer()]} | {:error, term()}
end
