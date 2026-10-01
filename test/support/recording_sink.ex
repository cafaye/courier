defmodule Courier.TestSupport.RecordingSink do
  @moduledoc """
  A `Courier.ErrorRelay.Sink` that hands each envelope to the test instead of
  opening a socket.

  The reason it exists is the same one `Courier.TestSupport.RecordingSender`
  exists for the webhook pipeline: an assertion about what courier *sends* has
  to be an assertion about courier, not about a listener's timing. Every
  "what the sink receives" test in `Courier.ErrorRelayTest` reads its bytes from
  here, which is why those tests can assert on the redaction boundary at the
  level of the envelope that would be stored and still finish in milliseconds.

  The target is a pid rather than a name, so a test that starts two relays gets
  two recordings and neither sees the other's.
  """

  @behaviour Courier.ErrorRelay.Sink

  @impl Courier.ErrorRelay.Sink
  def forward(envelope, opts) do
    case Keyword.get(opts, :sink_target) do
      pid when is_pid(pid) -> send(pid, {:relayed, envelope})
      _absent -> :ok
    end

    :ok
  end
end
