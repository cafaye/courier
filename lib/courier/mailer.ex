defmodule Courier.Mailer do
  @moduledoc """
  courier's Swoosh mailer.

  It is a thin wrapper on purpose: the adapter is configuration
  (`config :courier, Courier.Mailer, adapter: ...`), so choosing a provider is a
  deploy-time decision and not a code change. `Courier.Mailers` composes the
  messages; this module is the only place that hands one to a provider.

  No provider adapter ships yet. Test is `Swoosh.Adapters.Test` (hands the
  message to the process that sent it), dev and prod are `Swoosh.Adapters.Local`
  (renders into memory, returns a provider-shaped id, opens no socket), so a
  released courier exercises the whole pipeline without mailing anyone.
  """

  use Swoosh.Mailer, otp_app: :courier
end
