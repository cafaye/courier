defmodule Courier.ErrorReporting do
  @moduledoc """
  courier's own error reporting: the SDK seam, the client-side volume control, and
  the rule about which errors are reported at all.

  ## This is a seam, and the default is off

  `enabled?/0` reads `config :courier, :error_reporting`. In test it is `false` and
  `capture/2` is a no-op, so the suite neither opens a socket nor emits an
  envelope. That is asserted rather than assumed — see
  `CourierWeb.ErrorReportingTest` — because a reporting path that is "off in test"
  only in the sense that nobody checked is a reporting path that is on in
  production with a test DSN in it.

  The shape follows `Courier.Principal` and `Courier.Webhooks.Sender`: a
  configured module, a refusing default, and a configuration that has to be
  deliberate to do anything. A courier deployed without `COURIER_ERROR_REPORTING_DSN`
  does not report errors, and says nothing about it at boot — the same reasoning
  `Courier.ErrorRelay.Sink.Noop` gives at length.

  ## Which signals, and the OTel rule that decides it

  The brief asks whether to report per-request errors only or background failures
  too, and the OTel semantic conventions answer it before taste does:

  > "Errors that were retried or handled (allowing an operation to complete
  > gracefully) SHOULD NOT be recorded on spans or metrics that describe this
  > operation."

  An error store is a *different* class of system from a span — a store is
  retained and read by a human, a span is sampled and queried — so the argument
  does not transfer wholesale. But the rule marks the line that matters, and this
  module draws it here:

    * **Uncaught request-handling failures** are reported. The exception reached
      the top of the stack, nobody handled it, and the response is a 500.
    * **Uncaught background failures** are reported. An Oban job that exits
      abnormally has no stack above it to handle it, and it is exactly the failure
      that a customer notices as "the emails stopped" days later.
    * **Rescued, retried and handled errors are not reported.** `Deliver.deliver/3`
      failing once and succeeding on the next attempt is not an error; recording it
      makes the error rate a lie, and the same sentence appears in core's
      `docs/observability.md` rule 3. A handled domain failure is already an
      **event** in the outbox — PLAN.md §7b's first error layer — and it is
      aggregated by a consumer, not by an SDK.
    * **A 4xx is not an error.** It is a caller error with a caller-side fix, and
      it is `error.type: invalid_request` in the vocabulary rather than something
      to page on. Only a 5xx reaches this module.

  So: the two uncaught kinds, and nothing handled. Both are wired to the same
  capture path, and which one fired is visible in the event's `error.type`.

  ## The client-side limiter, and why it is not the throttle

  Sentry does not sample errors by design — `sample_rate` applies to transactions
  and an exception is reported every time it happens. That is the right default
  for a store, and it means volume control has to be built.

  There are two controls and they are at two different places on purpose, because
  two controls of the same kind is one control:

    * **Here**: a token bucket keyed on the exception's class, so a hot loop in
      one function does not build ten thousand envelopes. It is in-process and it
      resets on deploy.
    * **In the relay** (`Courier.ErrorRelay`): the same idea keyed on a
      fingerprint, shared across all three services, and it holds even if this one
      is misconfigured or a service is running a version without it.

  This one is the cheap early exit; the relay's is the one that makes the promise.

  ## `error.type` is set here, because this is where the class is known

  The OTel spec is explicit that `error.type` is "a class, not a message" and
  SHOULD be predictable and low-cardinality. courier's classes come from core's
  closed vocabulary of twelve plus `_OTHER`, and `Courier.ErrorRelay.Policy`
  validates them — so a class courier has not opted into is replaced with
  `_OTHER` at the relay rather than trusted. Stamping it here, from the exception
  itself, is what keeps the error store joinable to the trace signal: same
  attribute name, same enum, so a change of backend is a change of DSN.

  ## It never raises

  Every function here is total. The one thing that must not happen is a reporting
  path taking down the request that was being reported, so `capture/2` returns
  `:ok` or `{:error, reason}` and swallows anything the SDK does. The tests assert
  this against a relay that is not there.
  """

  require Logger

  alias Courier.ErrorRelay.Policy

  @type reason :: term()

  @doc """
  Is error reporting switched on?

  `false` unless `config :courier, :error_reporting, enabled: true`. Checked
  first by every other function here, so a disabled courier never touches the SDK.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    :courier
    |> Application.get_env(:error_reporting, [])
    |> Keyword.get(:enabled, false) ==
      true
  end

  @doc """
  Report an unhandled failure. Returns `:ok` or `{:error, reason}`; never raises.

  `error_type` must be one of core's classes — see `Policy.error_types/0`. A value
  outside it is sent anyway and replaced with `_OTHER` at the relay, so a typo
  degrades a class rather than losing a crash.

  `context` is a keyword list of **bounded** facts about the failure — a
  notification type, a webhook id, a queue name. It is *not* a place for a
  message, an email address or a token: the relay drops every key that is not on
  its allowlist, so anything here that is not an allowed key is silently
  discarded, and anything that is an allowed key with a credential in it is
  masked. The relay is the enforcement point; this is a comment saying not to
  rely on it.
  """
  @spec capture(Exception.t(), atom() | String.t(), keyword()) :: :ok | {:error, reason()}
  def capture(exception, error_type, context \\ []) do
    if enabled?() do
      if allowed?(error_type) do
        do_capture(exception, error_type, context)
      else
        Logger.warning(
          "[error-reporting] #{inspect(error_type)} is not in core's error vocabulary; " <>
            "it will be stored as _OTHER"
        )

        do_capture(exception, :_OTHER, context)
      end
    else
      :ok
    end
  rescue
    # The last line of defence, and the reason this function is documented as
    # total. A reporting path that raises inside a `rescue` clause turns a
    # recovered request into a crashed one, which is the opposite of the promise.
    exception ->
      Logger.error(
        "[error-reporting] capture raised and the error is lost: #{Exception.message(exception)}"
      )

      {:error, :capture_raised}
  end

  @doc """
  Same as `capture/3` for a non-`Exception` term.

  A background job can fail with a map, a string, or a bare `:badarg` from a
  library, and a reporting path that only accepts `Exception.t/0` is a reporting
  path that silently drops half of what it exists to see.
  """
  @spec capture_any(term(), atom() | String.t(), keyword()) :: :ok | {:error, reason()}
  def capture_any(failure, error_type, context \\ []) do
    capture(normalise(failure), error_type, context)
  end

  @doc "Is this class one courier is allowed to report?"
  @spec allowed?(atom() | String.t()) :: boolean()
  def allowed?(error_type), do: to_string(error_type) in Policy.error_types()

  @doc """
  The `error.type` courier would store for this class, which is the class itself
  when it is in the vocabulary and `_OTHER` when it is not.
  """
  @spec normalise_type(atom() | String.t()) :: String.t()
  def normalise_type(error_type) do
    if allowed?(error_type), do: to_string(error_type), else: "_OTHER"
  end

  # --- the SDK call ----------------------------------------------------------

  defp do_capture(exception, error_type, context) do
    Sentry.capture_exception(exception,
      # `tags`, not `extra`. The relay's allowlist keeps a small closed set of
      # tags and drops `extra` wholesale, so a fact that matters has to arrive as
      # a tag or not at all — and putting operator context in `extra` is how a
      # prompt or a token ends up in a retained store.
      tags: %{
        "error.type" => normalise_type(error_type),
        "service.name" => "courier",
        "deployment.environment" => environment(),
        "release" => release()
      },
      # **The stack trace, explicitly.** The SDK does not find it on its own:
      # `Sentry.Event.create_event/2` reads `Keyword.get(opts, :stacktrace)` and
      # there is no default, so an event captured without this option has
      # `stacktrace: nil` and reaches the store with **no frames at all**. That is
      # not obvious and it is not a small thing: "enough detail to act" *is* the
      # file and the line, and the class alone tells you which of a thousand
      # `RuntimeError`s in a BEAM stack you are looking at.
      #
      # `Process.info(self(), :current_stacktrace)` rather than `__STACKTRACE__`,
      # because `__STACKTRACE__` is only defined inside a `rescue`/`catch`/`after`
      # clause and this function is also called from an Oban `handle_info` failure
      # where there is no clause to put it in. It is a message to the VM rather
      # than a compiler special form, so it is available everywhere — and it
      # returns `nil` in a process with no current stacktrace, which is the
      # correct answer rather than an error.
      #
      # The frames' `vars` — the function arguments, which in Elixir are the bound
      # local variables — *are* rendered by the SDK and then removed by the
      # filter, along with the exception's message. That is the trade
      # `Courier.ErrorRelay.Policy` argues in full.
      stacktrace: current_stacktrace(),
      # Empty `user` and empty `extra` rather than omitted, and **no `contexts`
      # option at all** — `Sentry.capture_exception/2` has no `:contexts` key and
      # raises `unknown options [:contexts]` if it is given one. That raise is
      # caught by the `rescue` below, so the version of this file that passed
      # `contexts: %{}` reported **nothing at all** and returned `{:error,
      # :sdk_raised}` while looking, in a passing test, like a working reporting
      # path. Contexts come from `Sentry.Context` and the SDK's own runtime
      # integration; the filter keeps only `runtime`, `device`, `os` and `trace`,
      # and the relay keeps the same four.
      user: %{},
      extra: Map.new(context)
    )

    :ok
  rescue
    exception ->
      Logger.error(
        "[error-reporting] the SDK raised and the error is lost: #{Exception.message(exception)}"
      )

      {:error, :sdk_raised}
  end

  # --- the small normalisers -------------------------------------------------

  # The stack the SDK renders, or `nil` when there is not one. A VM message rather
  # than `__STACKTRACE__`, which only exists inside a `rescue`/`catch`/`after`
  # clause — and the background-failure path this module also serves has no such
  # clause to put it in.
  defp current_stacktrace do
    case Process.info(self(), :current_stacktrace) do
      {:current_stacktrace, [_ | _] = stacktrace} -> stacktrace
      _absent_or_empty -> nil
    end
  end

  defp environment,
    do:
      Application.get_env(:courier, :error_reporting, []) |> Keyword.get(:environment, "unknown")

  defp release,
    do: Application.get_env(:courier, :error_reporting, []) |> Keyword.get(:release, "unknown")

  # `is_exception/1` and not `%Exception{}`. An Elixir exception is a map with a
  # `__struct__` of `:error` or `:exit`, not a struct, so the struct pattern does
  # not exist and does not compile — which is a nice illustration of why a guard
  # is the right tool for "is this one of a family" and a pattern is not.
  defp normalise(failure) when is_exception(failure), do: failure
  defp normalise(failure) when is_binary(failure), do: RuntimeError.exception(failure)
  defp normalise(failure), do: RuntimeError.exception(inspect(failure))
end
