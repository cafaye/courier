defmodule Courier.TestSupport.TestDns do
  @moduledoc """
  A DNS resolver that answers from a table the test writes, so SSRF decisions can
  be tested against the attack they exist for without touching the network.

  The attack this stands in for is a public name that answers with a private
  address. Reproducing it for real would mean a name anyone can register, so the
  answers live here: `resolve/1` returns the list for the host it was configured
  with, and `{:canned, answers}` answers with the same list for any host.

      Courier.TestSupport.TestDns.canned(["127.0.0.1"])

  It never calls `:inet`, so a test cannot pass or fail because of what a real
  resolver decided about a real name.
  """

  @behaviour Courier.Webhooks.Dns

  @impl Courier.Webhooks.Dns
  def resolve({:canned, answers}), do: normalize(answers)
  def resolve({:host, host, answers}), do: if(host_is?(host, answers), do: {:ok, answers}, else: {:error, :nxdomain})

  defp normalize(answers) when is_list(answers) do
    if answers == [], do: {:error, :nxdomain}, else: {:ok, answers}
  end

  defp normalize(reason), do: {:error, reason}

  defp host_is?({:host, host, _answers}, _answers), do: true
  defp host_is?(_configured, _answers), do: false
end
