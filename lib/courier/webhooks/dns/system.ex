defmodule Courier.Webhooks.Dns.System do
  @moduledoc """
  The resolver courier ships: `:inet.getaddrs/2`, and nothing else.

  One note on the record type: it asks for `:in` (IPv4) and `:inet6` separately
  rather than `:inet` (both), because `getaddrs` with a union record type is not
  a supported query, and because a customer with a dual-stack endpoint has to
  work. Both families are checked against the same block list, so a name that
  answers with a public A record and a private AAAA record is still refused.
  """

  @behaviour Courier.Webhooks.Dns

  @records [:in, :inet6]

  @impl Courier.Webhooks.Dns
  def resolve(host) when is_binary(host) do
    host = String.trim_trailing(host, ".")

    @records
    |> Enum.flat_map(fn record ->
      case :inet.getaddrs(host, record) do
        {:ok, addresses} -> Enum.map(addresses, fn {address, _family} -> address |> :inet.ntoa() |> to_string() end)
        {:error, _reason} -> []
      end
    end)
    |> case do
      [] -> {:error, :nxdomain}
      answers -> {:ok, answers}
    end
  end
end
