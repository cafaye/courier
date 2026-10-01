defmodule Courier.ErrorReporting.Filter do
  @moduledoc """
  The SDK-side half of the redaction boundary, run by Sentry's `before_send`
  before an envelope is built.

  ## Why there are two, and why this one is not a second policy

  core's `redaction.schema.json` has a `defenceInDepth` field, and this is what
  it describes: "two independent controls, because the realistic failure is one of
  them being removed by a well-meaning change and nobody noticing for a month".

  The chokepoint is `Courier.ErrorRelay.Policy`, which every event passes through
  on its way to the store. This is the barrier in front of it.

  The reason it is not optional is specific rather than general: **the relay is a
  deployment, and deployments get misconfigured.** A service whose DSN points at
  `https://key@sentry.io/1` instead of at courier's relay never reaches
  `Courier.ErrorRelay.Policy` at all, and the event arrives at a third party
  carrying an exception message and a request URL. That is the leak this whole
  packet exists to close, and no amount of correctness in the relay prevents it.

  So this filter exists, and it is deliberately **thin**: it knows about Sentry's
  `Sentry.Event` struct and nothing else. Every list it enforces comes from
  `Courier.ErrorRelay.Policy.vocabulary/0` and every mask from
  `Policy.mask/1`, so there is one policy in this repository and two places it
  runs. A hand-written second copy of the allowlists would be a second thing to
  forget to update, which is the failure `defenceInDepth` warns about.

  ## Fail-closed

  `before_send/1` returning `nil` drops the event. An event this filter cannot
  read is an event the store will not receive, and that is the correct direction:
  losing a crash is recoverable, and a customer credential in a third party's
  index is not.

  ## What survives, and it is the same list the relay keeps

  Class, module, file, line, function, `in_app`, release, environment, the tags
  in the closed set, the four bounded `contexts`, the HTTP method, the route
  template, and the `error.type` from core's vocabulary. Nothing else. The
  exception **message** goes, and so do the frame **variables** — which in Elixir
  are the function arguments, and in the SDK's own rendering include the bound
  local variables. `Courier.ErrorRelay.Policy` argues the trade in full; this
  module is where it is paid.

  ## The struct round-trip is the fragile part, so a test holds it

  `Sentry.Event` is a **struct with atom keys**, while the policy speaks
  string-keyed maps because that is what Jason produces. So this filter converts
  struct → string-keyed map, redacts, and converts back. Both conversions are
  places a value can be silently lost, which is why
  `CourierWeb.ErrorReportingTest` asserts on the SDK's own output rather than on
  this module in isolation: the claim that matters is "a secret does not reach the
  envelope", and the envelope is what the SDK hands the transport.
  """

  alias Courier.ErrorRelay.Policy

  @doc """
  Sentry's `before_send` callback. Returns a redacted `Sentry.Event`, or `nil` to
  drop the event.
  """
  @spec before_send(map()) :: map() | nil
  def before_send(event) do
    with {:ok, redacted} <- redact(event),
         {:ok, rebuilt} <- rebuild(event, redacted) do
      rebuilt
    else
      {:error, _reason} ->
        # Fail-closed. A crash whose event cannot be redacted is a crash courier
        # does not report.
        #
        # A `:telemetry` event rather than a `:counters` ref: a counter needs a
        # process to own the ref, and adding one to observe how often a callback
        # failed would be more machinery than the observation is worth. The event
        # goes into the same telemetry courier already ships, and
        # `CourierWeb.Telemetry` can attach a counter to it in one line if anybody
        # ever wants an alert.
        :telemetry.execute([:courier, :error_reporting, :filter_dropped], %{}, %{})
        nil
    end
  end

  # `Sentry.Event` is a struct with atom keys; the policy speaks string keys. The
  # conversion is explicit in both directions and neither is clever.
  defp redact(event) do
    event
    |> plain_map()
    |> Policy.redact()
  end

  # The redacted event is **the whole event**, not a patch.
  #
  # `Sentry.Event`'s fields are atoms and the policy's allowlist is strings, so
  # the redacted map names a *subset* of the struct's fields. Building the result
  # by merging that subset over the original would leave every field the policy
  # **dropped** at its original value — so `:server_name` (an unbounded
  # per-container identifier), `:modules` (the whole dependency list), `:fingerprint`
  # (the SDK's `["{{ default }}"]`) and `:original_exception` (the live exception,
  # message and all) all survived a filter that had correctly decided to remove
  # them.
  #
  # Two earlier attempts, both wrong in instructive ways:
  #
  #   * `struct(Sentry.Event, redacted)` — string keys against atom fields, so
  #     every field came out at its default and the envelope read
  #     `{"event_id":null,"tags":{},"exception":[]}`. Every leak assertion passed
  #     and the crash itself had been deleted. **A filter that empties the event
  #     satisfies every leak test ever written**, which is why the test also
  #     asserts the class, the file and the line are still there.
  #   * `Map.merge(original, atomised)` — the subset-over-original merge above.
  #
  # What is wanted is the third thing: keep the fields the policy named, and put
  # every *other* field back to the struct's own default. That is
  # `Map.merge(defaults, kept)`, where `defaults` is the struct with everything
  # cleared and `kept` holds only allowlisted fields.
  #
  # `:original_exception` is the one field that is deliberately *not* restored,
  # and the reason is that it is the exception itself: `Map.from_struct/1` on a
  # `RuntimeError` yields `%{message: "…", __exception__: true}`, so leaving it
  # in place would put the exception's message in the event under a key the
  # policy never named. It is kept as a **struct**, not converted, so the SDK's
  # own `after_send` callbacks still receive something of the right type — and it
  # is the SDK's *serialiser* that decides whether that struct reaches the wire,
  # which it does not for a field this filter has replaced.
  defp rebuild(original, redacted) do
    fields = original |> Map.from_struct() |> Map.keys()

    cleared = Map.new(fields, fn field -> {field, default_for(original, field)} end)

    kept =
      fields
      |> atomise(redacted)
      # `:exception` is the field the SDK's own renderer destructures hardest.
      # `render_exception/1` pattern-matches `%Interfaces.Exception{}` and
      # `render_or_delete_stacktrace/1` pattern-matches
      # `%Interfaces.Stacktrace{frames: [_ | _]}`; a redacted exception that is a
      # plain map, or a list of plain maps, matches **neither**, so the SDK drops
      # the exception from the event. The envelope came out reading
      # `"exception":[{"module":null,"type":null,…}]` — a crash with its class
      # deleted, which is the one outcome this filter exists to prevent and the
      # one no leak assertion catches.
      #
      # `retype/2` puts the SDK's structs back. This line is only the unwrapping:
      # the policy emits the **wire** shape `{"values" => [...]}` and the SDK
      # wants a list, and the conversion has to happen somewhere.
      |> then(fn kept ->
        case Map.fetch(kept, :exception) do
          {:ok, exception} -> Map.put(kept, :exception, unwrap_exception(exception))
          :error -> kept
        end
      end)

    # **`struct/2`, and the result has to be a struct again.**
    #
    # `Map.merge/2` and `Map.from_struct/1` both return a *plain map*: the first
    # because merging is not struct-aware, the second because that is its job. So
    # an earlier version of this function returned a plain map from `before_send`,
    # and the SDK's own `Client.send_event/2` then failed its own
    # `with {:ok, %Event{} = event} <- maybe_call_before_send(...)` match — which
    # made `capture_exception/2` return `{:ok, <plain map>}` instead of
    # `{:ok, envelope_id}`, and, because the `with` short-circuited on the
    # non-match, **never posted the envelope at all**.
    #
    # The symptom was the most confusing one in this packet: no error, no
    # `assert_receive` timeout message about redaction, just a mailbox that stayed
    # empty while `capture/2` cheerfully returned `:ok`. It is worth writing down
    # because the SDK reports success for an event it silently discarded, and the
    # only way to see it is to assert on the *bytes* rather than on the return
    # value — which is the third half of the test and the reason it exists.
    merged =
      cleared
      |> Map.merge(kept)
      |> retyped(original)

    {:ok, struct(Sentry.Event, merged)}
  end

  # Put each kept field back into the **SDK's own type**.
  #
  # This is not tidiness. `Sentry.Client.render_event/1` — the function that turns
  # the event into the bytes on the wire — calls `Map.from_struct/1` on several
  # fields *unconditionally*:
  #
  #     update_if_present(:sdk, &Map.from_struct/1)
  #     update_if_present(:request, fn req -> req |> Map.from_struct() … end)
  #     … Enum.map(exception_list, &render_exception/1)   # which also from_structs
  #
  # so handing it a plain string-keyed map for `:sdk` raises
  # `FunctionClauseError` inside the SDK's own serialiser, the envelope is never
  # built, and `capture_exception/2` reports `:ok`. **The event was silently
  # discarded, and the only symptom was a test waiting for bytes that were never
  # going to arrive.**
  #
  # So the policy is free to speak in plain maps — it has to, because the wire is
  # maps — and this function is the adapter back into the SDK's structs. The rule
  # is taken from the **original** event rather than from a list written down
  # here: whatever type the SDK put in a field is the type it expects back, and a
  # field the original left as a plain map (`:tags`, `:contexts`, `:extra`) stays
  # a plain map.
  defp retyped(merged, original) do
    Map.new(merged, fn {field, value} -> {field, retype(Map.get(original, field), value)} end)
  end

  # `struct/2` converts **one level**, so the recursion has to walk the whole
  # chain. Two things about that chain are not guessable and are the reason the
  # `original` is threaded through rather than a map of defaults:
  #
  #   * `Sentry.Client.render_event/1` calls `Map.from_struct/1` on `:sdk` and
  #     `:request` **unconditionally**, and `render_exception/1` pattern-matches
  #     `%Interfaces.Exception{}` with a
  #     `%Interfaces.Stacktrace{frames: [_ | _]}` inside it. A plain map in any
  #     of those positions raises or is silently dropped, and `capture_exception/2`
  #     still answers `:ok`. The only way to see it is to assert on the bytes.
  #   * The types have to come from the **original's** values. `Sentry.Interfaces.
  #     Exception` is written `defstruct [:type, :value, :module, :stacktrace,
  #     :mechanism]`, so the *default* for `:stacktrace` is `nil`, and a recursion
  #     driven off defaults types the plain map the policy produced as `nil`,
  #     leaves it unchanged, and the renderer deletes the stacktrace.
  #
  # Built and reduced as a **plain map**, turned back into a struct at the end.
  # `Map.new/2` over a struct raises `protocol Enumerable not implemented` — a
  # struct is a map, but not one this protocol is implemented for.
  #
  # The field list is the struct's own, via `Map.from_struct/1` on the instance
  # the SDK built — not `module.__struct__/0` and not `struct(module)`, because
  # the former is a map rather than a field list and the latter raises for a
  # struct declaring `@enforce_keys`. None of the SDK's interface structs does
  # (checked in `deps/sentry/lib/sentry/interfaces.ex`), so this avoids the
  # question entirely by never needing the defaults.
  defp retype(%module{} = original, value) when is_map(value) and not is_struct(value) do
    original
    |> Map.from_struct()
    |> Map.keys()
    |> atomise(value)
    |> Map.new(fn {field, field_value} ->
      {field, retype(Map.get(original, field), field_value)}
    end)
    |> then(&struct(module, &1))
  end

  # A list of structs — `:exception` and `:threads`. `unwrap_exception/1` has
  # already removed the wire shape's `"values"` wrapper by the time this runs, so
  # both sides are lists here.
  #
  # It has to come **before** the catch-all and after the struct clause, and both
  # of those positions are load-bearing. A list is not a map, so the struct
  # clause cannot take it; and without this clause the list falls to the catch-all
  # and every exception in it stays a **plain string-keyed map**, which the SDK's
  # `render_exception/1` then refuses to pattern-match — `no function clause
  # matching in Sentry.Client.render_exception/1`, inside the SDK's own renderer,
  # with `capture_exception/2` answering `:ok` and no envelope on the wire.
  #
  # `Enum.zip/2` **truncates to the shorter list and pads with `nil`**, and `nil`
  # is not a struct, so a redacted list shorter than the original (which is what
  # the policy produces for a frame that did not survive) would otherwise reach
  # the renderer as a `nil` and take the whole exception with it. The nils are
  # dropped rather than retype'd: a redacted entry that is not a map is a value
  # the policy removed, not a value to convert.
  defp retype([%_module{} | _] = originals, values) when is_list(values) do
    originals
    |> Enum.zip(values)
    |> Enum.reject(fn {_original, redacted} -> is_nil(redacted) end)
    |> Enum.map(fn {original, redacted} -> retype(original, redacted) end)
  end

  # `nil` where a struct is expected: the policy removed it, so it stays removed.
  # Without this clause the value fell through to the catch-all and survived as a
  # `nil` inside a `%Stacktrace{frames: nil}` — and the SDK's
  # `render_or_delete_stacktrace/1` then deletes the whole stacktrace, taking the
  # exception's frames with it. A removed field must be removed *completely*; a
  # half-removed one is a crash report with no crash in it.
  defp retype(%_module{}, nil), do: nil

  # Anything else — a plain map, a list of plain maps, a string — is already the
  # type the SDK put there.
  defp retype(_original, value), do: value

  # The wire shape `{"values" => [...]}` becomes the list the SDK wants. Both
  # shapes arrive here: the policy produces the wrapper, and a caller that
  # hand-built an event may have a bare list.
  defp unwrap_exception(%{"values" => values}) when is_list(values), do: values
  defp unwrap_exception(%{__struct__: _} = exception), do: [exception]
  defp unwrap_exception(values) when is_list(values), do: values
  defp unwrap_exception(other), do: other

  # A field the policy did not name goes back to the struct's **default**, which
  # for the fields that matter is not the same as `nil`:
  #
  #   * `:exception` defaults to `[]` and `:breadcrumbs` to `[]`, so the envelope
  #     carries an empty list rather than a key the policy removed. A JSON
  #     encoder that omits empty containers would drop them; one that does not
  #     emits `"exception":[]`, which carries nothing.
  #   * `:original_exception` is cleared to `nil` rather than restored — see the
  #     note in `rebuild/2`. Restoring it is how a message reaches the store.
  #
  # `:contexts` and `:tags` are the two the policy *does* set, so they never
  # reach this function, and `:event_id` is always kept because it is the event's
  # own identity — without it the store has nothing to group on.
  # Read the defaults from the struct's **own definition** rather than building
  # one. `struct(Sentry.Event, [])` is not a way to get defaults: `Sentry.Event`
  # declares `event_id` and `timestamp` as `required: true`, so building one
  # without them raises — which it did, in the middle of a `before_send`
  # callback, for every event courier reported.
  #
  # `%Sentry.Event{event_id: "", timestamp: ""}` is the value that has every
  # default and satisfies the requirement, and the two required fields are then
  # overwritten by `kept` because the policy allowlists both.
  @defaults %Sentry.Event{event_id: "", timestamp: ""}

  defp default_for(_original, :exception), do: []
  defp default_for(_original, :breadcrumbs), do: []
  defp default_for(_original, field), do: Map.fetch!(@defaults, field)

  # `atomise(fields, redacted)`, with the struct's field list **first**. Written
  # the other way round it reads fine and compiles fine and is a `Map.update/3`
  # with one argument missing, which is a warning at build time and a
  # `FunctionClauseError` at run time — inside a `before_send` callback, so the
  # symptom is courier reporting nothing and saying `:ok`.
  defp atomise(fields, redacted) do
    Enum.reduce(fields, %{}, fn field, acc ->
      case Map.fetch(redacted, Atom.to_string(field)) do
        {:ok, value} -> Map.put(acc, field, value)
        :error -> acc
      end
    end)
  end

  # `Sentry.Event`'s fields are **atoms** (`:event_id`, `:exception`, `:tags`) and
  # the policy's allowlist is **strings**, because strings are what the wire
  # carries. `Map.from_struct/1` on its own keeps the atoms, so the policy's
  # `take/2` found nothing to keep, produced an event with every field at its
  # default, and the merge in `rebuild/2` then put the *original* — unredacted —
  # values straight back.
  #
  # The result was the worst possible failure for this module: every
  # `refute body =~ canary` passed, because the filter had thrown the whole event
  # away and the merge had handed the original back. The leak was real and every
  # leak assertion was green. It is caught by the assertions that check the crash
  # is *still* a crash, which is the third half of the test and the reason it is
  # there at all.
  #
  # `Atom.to_string/1` on the struct's own field names — never `to_string/1` on a
  # caller-supplied key, and never `String.to_atom/1` on the way back, which is
  # what `atomise/2` exists to avoid.
  defp plain_map(%Sentry.Event{} = event) do
    event
    |> Map.from_struct()
    |> stringify()
  end

  # **Deeply**, because the nesting is where the leak is.
  #
  # `Sentry.Event`'s top-level fields are atoms, and so is everything inside them:
  # the `exception` list holds maps keyed `:type`, `:value`, `:stacktrace`, and a
  # stack frame is `%{filename:, function:, lineno:, in_app:, vars:}`. So
  # converting only the top level leaves the exception looking like a map with no
  # `"values"` key, the policy concludes there is no exception to reduce, and the
  # **message and the frame variables go through untouched**.
  #
  # That is not hypothetical: it is what this function did first, and the leak
  # assertion that caught it was the JWT one, which arrived inside the exception
  # `type` the same way a credential does in the real world.
  #
  # `nil` values are dropped at every level. They are what an unset SDK field looks
  # like, and carrying them through would put `"server_name": null` in the
  # envelope — the name of a key the policy removed, which is its own small leak of
  # the schema.
  # A struct nested inside the event — `Sentry.Interfaces.Exception.t/0`, a
  # `Stacktrace`, a frame, a `Request`, the `SDK` block, and `:original_exception`
  # which is a plain `RuntimeError` rather than a `Sentry.Interfaces.*` struct.
  #
  # **This clause comes first**, and that ordering is the whole bug this comment
  # exists to record. With the plain-map clause first and this one second, the
  # guard `not is_struct(value)` made them mutually exclusive and both correct —
  # and then `is_struct/1` stopped matching anything, because the value reaching
  # it was an **exception struct whose module was never loaded** in the calling
  # process. `is_struct/1` on a map whose `__struct__` names a module that does not
  # exist raises inside the guard, and the guard is not a rescue.
  #
  # The fix is not a cleverer guard. It is to ask the **shape**: a map with a
  # `__struct__` key is a struct whatever its module, and `Map.from_struct/1`
  # works on it without needing the struct to be compiled into this process. So
  # the struct clause is matched on the key rather than through `is_struct/1`, and
  # the plain-map clause is the fallback.
  defp stringify(%{__struct__: _module} = value) do
    value |> Map.from_struct() |> stringify()
  end

  defp stringify(value) when is_map(value) do
    value
    |> Enum.reject(fn {_key, inner} -> is_nil(inner) end)
    |> Map.new(fn {key, inner} -> {key_name(key), stringify(inner)} end)
  end

  defp stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)
  defp stringify(value), do: value

  # An atom key becomes its string; a string key is already what the policy wants.
  # Nothing else can appear: the only maps reaching here are the SDK's own event
  # and the structures inside it, and a map with an unexpected key type would be
  # stringified as `to_string/1` of it, which is a loud failure rather than a
  # silent skip.
  defp key_name(key) when is_atom(key) and not is_nil(key), do: Atom.to_string(key)
  defp key_name(key) when is_binary(key), do: key
  defp key_name(key), do: inspect(key)
end
