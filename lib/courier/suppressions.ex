defmodule Courier.Suppressions do
  @moduledoc """
  What courier knows about an address's deliverability, and what it does about it.

  This is the question SMTP never answers. A submission protocol's whole reply is
  "accepted for delivery", so a courier that sends and hears nothing will mail a
  mailbox that stopped existing three months ago, forever — and a sending domain
  that keeps writing to dead addresses is a domain that gets suspended. The
  provider tells us; this module is what courier does with being told.

  ## The states, and the decision behind them

      :undeliverable   a HARD bounce. RFC 5321 §5.1.1 permanent failure — no such
                       user, a null reverse path. A fact about the MAILBOX.
      :suppressed      a COMPLAINT. RFC 2142 §5, an abuse report, a "report spam".
                       An instruction from the PERSON, about the MAIL.

  Both stop the send, and that is the decision rather than the fallback. Mailing a
  dead address costs a sending domain its reputation; mailing somebody who
  marked you as spam costs more than that. The argument is the asymmetry: being
  wrong towards sending is expensive and cumulative, being wrong towards not
  sending costs one message to one person who was about to mark you as spam
  anyway.

  They are kept as two values rather than one boolean because they mean different
  things and an operator's response to each is different. A pile of
  `:undeliverable` is list hygiene. A pile of `:suppressed` is a content and
  sender-reputation problem, and a per-address suppression does not fix it — so an
  operator who can only see "true" cannot tell which of the two they are looking
  at.

  **`:suppressed` outranks `:undeliverable`.** A complaint is the recipient's
  instruction; a bounce is a fact about a mailbox, and a later fact does not
  withdraw an instruction.

  ## Nothing is ever updated, which is why the precedence cannot be got wrong

  Rows are immutable. The state is a fold:

      nothing at all                  -> `nil`
      rows, none carrying a state     -> `nil`
      any row `:suppressed`           -> `:suppressed`
      otherwise any row               -> `:undeliverable`

  So "a later bounce cannot undo a complaint" is not a rule in a `case` somebody
  has to remember; it is a consequence of there being no `Repo.update/2` on this
  table. `Courier.SuppressionsTest` asserts it from both directions for exactly
  that reason — a design whose correctness lives in an UPDATE is a design whose
  correctness a future edit can remove.

  ## A soft bounce records nothing, on purpose

  RFC 5321 §4.2.2 temporary failure — mailbox full, greylisted, "try again in
  four hours". Suppressing on one is how a suppression list starts eating live
  addresses: one provider's bad afternoon becomes a thousand addresses courier
  will never write to again, with nothing in the data to say which of them were
  ever real. `ingest/2` accepts a soft bounce, stores **no row**, and answers
  `{:ok, :ignored}`.

  The answer is deliberately a different shape from `{:ok, :new, row}`. A caller
  that counted `:ignored` as a failure would retry forever; one that counted it as
  `:new` would be counting a row that does not exist.

  ## Idempotency is the unique index

  `(provider, provider_event_id)` is unique, and a delivery that loses it is
  answered `{:ok, :duplicate, row}` — the row that won, so the caller can report a
  consistent answer either way. Real providers retry: Postmark retries on a timeout
  and on any 5xx, and a courier restarting with a batch in flight will see that
  batch again. A "have I seen this?" check in Elixir would be a race; the index
  cannot be.

  ## Tenancy: there is none, and that is deliberate

  A suppression has no `account_id`. An address is an address, and courier's
  send-path question — "may I write to this mailbox?" — has no tenant in it: one
  account's hard bounce for `ops@example.com` is just as true of every other
  account's mail to `ops@example.com`, and the damage a dead address does is to
  the shared sending domain. Scoping the row to an account would make a
  cross-tenant leak available (a list of somebody else's addresses) to fix a
  problem that is not a cross-tenant one.

  What this costs is worth stating: **the table is never exposed through any
  route**, so no caller can read an address out of it, and a suppression can only
  ever be observed as its effect on courier's own sends. That is the same posture
  as the send path — the answer is "no mail went out", never "here is a list".

  ## `normalize/1` is called on both sides of every comparison

  Writing lowercases and trims; `suppressed?/1`, `state/1`, `find/1` and
  `history/1` lowercase what they are given. Both halves matter and they are
  separate: a row stored mixed-case is invisible to a lowercasing lookup, and a
  caller that spells an address differently between the ingest and the send would
  get a different answer for the same mailbox.
  """

  import Ecto.Query

  alias Courier.Repo
  alias Courier.Suppression

  # The kinds courier accepts from a provider. **Closed on purpose**: an event
  # courier cannot classify is not an event courier acts on, which is the same
  # fail-closed instinct as `Courier.ErrorReporting.Filter` returning nil rather
  # than emitting something it cannot redact. Storing an unclassifiable event as
  # "not suppressed" would be a decision courier could not defend.
  @kinds [:hard_bounce, :soft_bounce, :complaint]

  @typedoc """
  One report from a provider, in courier's own vocabulary.

  `:kind` is what the provider called it, normalised; `:state` is what courier
  takes from it, and a soft bounce has no state because courier takes nothing.
  """
  @type event :: %{
          required(:provider) => String.t(),
          required(:provider_event_id) => String.t(),
          required(:email) => String.t(),
          required(:kind) => atom(),
          optional(:reason) => String.t() | nil,
          optional(:message_id) => String.t() | nil,
          optional(:occurred_at) => DateTime.t() | nil
        }

  @doc false
  def kinds, do: @kinds

  @doc "The states a suppression can carry."
  def states, do: Suppression.states()

  @doc """
  The address courier stores and looks up: downcased and trimmed, nothing else.

  Not lowercased *further* than that. Stripping `+tag` or dots would be a
  deliverability heuristic belonging to a provider's address hygiene, and applying
  one here would make courier suppress a mailbox the provider never reported — the
  one direction this whole table is written against.
  """
  @spec normalize(String.t() | nil) :: String.t() | nil
  def normalize(nil), do: nil

  def normalize(email) when is_binary(email) do
    email |> String.trim() |> String.downcase()
  end

  def normalize(other), do: other

  @doc """
  Records one provider report.

  `{:ok, :new, row}`, `{:ok, :duplicate, row}`, or `{:error, changeset}`.
  """
  @spec record(map()) ::
          {:ok, :new | :duplicate, Suppression.t()} | {:error, Ecto.Changeset.t()}
  def record(attrs) do
    %Suppression{}
    |> Suppression.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, row} ->
        {:ok, :new, row}

      {:error, %{__struct__: Ecto.Changeset} = changeset} ->
        if duplicate?(changeset), do: duplicate(attrs), else: {:error, changeset}
    end
  end

  # The row that won, read back rather than reconstructed. A caller being told
  # "this event was already ingested" needs the SAME row courier stored, not a
  # struct assembled from the attributes the duplicate happened to carry — two
  # deliveries of one event can differ in whitespace or field order, and handing
  # back the loser's view of it would make "idempotent" mean "answers the same
  # thing" rather than "is the same thing".
  defp duplicate(attrs) do
    Suppression
    |> where(
      [s],
      s.provider == ^attrs[:provider] and s.provider_event_id == ^attrs[:provider_event_id]
    )
    |> limit(1)
    |> Repo.one()
    |> case do
      %Suppression{} = row -> {:ok, :duplicate, row}
      # Unreachable: the insert lost the unique index, so a row with this pair
      # exists. Handled rather than matched away because the alternative is a
      # `nil` reaching a caller that pattern-matches a struct, and the symptom
      # would be three files away from this one.
      nil -> {:error, :duplicate_without_a_row}
    end
  end

  @doc """
  Acts on one provider report: the HTTP surface's entry point.

  Returns `{:ok, :new | :duplicate, row}` for a kind courier suppresses on,
  `{:ok, :ignored}` for a kind it deliberately does nothing about, and
  `{:error, :unsupported_kind}` for one it will not guess at.
  """
  @spec ingest(event()) ::
          {:ok, :new | :duplicate, Suppression.t()} | {:ok, :ignored} | {:error, term()}
  def ingest(%{kind: kind} = event) when kind in [:hard_bounce, :complaint] do
    # `Map.put/3`, not `Map.merge(event, state: ...)`. The second argument of
    # `merge/2` is a MAP, and a bare `state: :undeliverable` at the call site is a
    # keyword LIST — so the two-line version raises `BadMapError` on every hard
    # bounce and every complaint, which is to say on every event courier exists to
    # act on. `record/1` drops `:kind` because the changeset does not cast it.
    record(Map.put(event, :state, state_for(kind)))
  end

  def ingest(%{kind: :soft_bounce}), do: {:ok, :ignored}

  def ingest(%{kind: other}) do
    # The refusal carries the value because it is courier's own vocabulary being
    # rejected, from a provider courier asked to configure — never caller text.
    _ = other
    {:error, :unsupported_kind}
  end

  @doc "Whether courier will refuse to write to `email`."
  @spec suppressed?(String.t() | nil) :: boolean()
  def suppressed?(email) when is_binary(email) do
    Suppression
    |> where([s], s.email == ^normalize(email))
    |> where([s], not is_nil(s.state))
    |> limit(1)
    |> Repo.exists?()
  end

  def suppressed?(_email), do: false

  @doc """
  The address's state, or `nil` when nothing suppresses it.

  The fold, in full: any `:suppressed` wins, otherwise any row wins.
  """
  @spec state(String.t() | nil) :: :undeliverable | :suppressed | nil
  def state(email) when is_binary(email) do
    email = normalize(email)

    cond do
      has_state?(email, :suppressed) -> :suppressed
      has_state?(email, :undeliverable) -> :undeliverable
      true -> nil
    end
  end

  def state(_email), do: nil

  @doc """
  The row the state was decided from, or `nil`.

  Chosen with the same precedence as `state/1`, so an operator reading a row is
  not shown a bounce for an address that was actually suppressed by a complaint.
  """
  @spec find(String.t() | nil) :: Suppression.t() | nil
  def find(email) when is_binary(email) do
    Suppression
    |> where([s], s.email == ^normalize(email))
    |> where([s], not is_nil(s.state))
    |> order_by([s], desc: fragment("? = 'suppressed'", s.state), asc: s.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  def find(_email), do: nil

  @doc """
  Every report courier holds about `email`, oldest first.

  Sorted by `inserted_at` rather than left to PostgreSQL: an unordered `Repo.all/1`
  returns rows in the server's order, and a caller that compares two lists without
  sorting both sides is making a claim about the server.
  """
  @spec history(String.t() | nil) :: [Suppression.t()]
  def history(email) when is_binary(email) do
    Suppression
    |> where([s], s.email == ^normalize(email))
    |> order_by([s], asc: s.inserted_at, asc: s.id)
    |> Repo.all()
  end

  def history(_email), do: []

  # The two kinds courier suppresses on, mapped to what it calls them. One
  # function so the ingest path and the test cannot disagree about the mapping.
  defp state_for(:hard_bounce), do: :undeliverable
  defp state_for(:complaint), do: :suppressed

  defp has_state?(email, state) do
    Suppression
    |> where([s], s.email == ^email and s.state == ^state)
    |> limit(1)
    |> Repo.exists?()
  end

  # A duplicate and a malformed event are both an insert that did not happen, and
  # they are told apart by whether the unique index is what stopped it — matched
  # BY NAME for the reason in `Courier.Idempotency.refusal/1`.
  defp duplicate?(changeset) do
    Enum.any?(changeset.errors, fn {_field, {_message, opts}} ->
      Keyword.get(opts, :constraint) == :unique and
        to_string(Keyword.get(opts, :constraint_name)) ==
          "email_suppressions_provider_idempotency_index"
    end)
  end
end
