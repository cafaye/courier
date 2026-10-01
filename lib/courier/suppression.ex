defmodule Courier.Suppression do
  @moduledoc """
  One provider's report about one address, and the state courier took from it.

  A row is **immutable**. Nothing in courier updates one, which is the whole
  reason the packet's precedence rule cannot be got wrong: `Courier.Suppressions`
  derives an address's state by folding over the rows that exist rather than by
  mutating one to a stronger value, so "a complaint is never downgraded by a later
  bounce" is not a rule somebody has to remember in a `case` — it is a property of
  there being nothing to update. See that module's moduledoc.

  `state` is courier's own vocabulary and not the provider's: a Postmark
  `HardBounce` and an SES `Permanent` are both `:undeliverable` here, because the
  question courier asks is not "what did Postmark call it" but "can this mailbox
  receive mail". `reason` keeps the provider's own words, bounded, because when an
  operator asks courier why an address is suppressed the useful answer is the
  provider's sentence and not courier's enum.

  ## What is deliberately absent

  There is no column for the provider's payload. A bounce report carries
  addresses, reasons, and sometimes a message snippet, and the four facts courier
  acts on are the four it stores. A schema that had a `payload` map would be a
  copy of somebody's inbox held for no operational reason, and
  `Courier.SuppressionsTest` asserts the field list so adding one is a decision
  somebody reads.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Courier.Suppressions

  @states [:undeliverable, :suppressed]

  # Bounded on the three free-text columns, and the bound is HERE rather than in a
  # `size:` on the column. A provider's reason is a sentence and a provider's
  # event id is an opaque identifier, but neither is courier's to size: a provider
  # that puts a payload in the reason should not be able to write a megabyte into
  # a table the send path reads, and a provider whose event id is 300 characters
  # should be refused by a changeset error rather than by a `varchar(255)`
  # truncation at runtime. Both columns are `text` in the migration so that this
  # is the only bound — see its moduledoc.
  @reason_length 500
  @message_id_length 512
  @provider_event_id_length 512

  @primary_key {:id, Ecto.UUID, autogenerate: true}

  @type t :: %__MODULE__{}

  @doc false
  def states, do: @states

  @doc false
  def reason_length, do: @reason_length

  schema "email_suppressions" do
    field :email, :string
    field :state, Ecto.Enum, values: @states
    field :provider, :string
    field :provider_event_id, :string

    field :reason, :string
    field :message_id, :string
    field :occurred_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  The changeset for one provider report.

  Every field is courier's or the provider's verbatim. Nothing here is
  caller-settable in a way that bypasses the vocabulary: `state` is
  `Ecto.Enum`, so a value outside `@states` is a cast error rather than a row that
  reads as something courier decided.

  `email` is normalised on the way in, and the address format is checked at the
  boundary rather than trusted — an event with an unparseable address is not an
  event courier can act on, and storing it would create a row that
  `suppressed?/1` could never match.

  `message_id` loses RFC 5322's angle brackets for the same reason `email` is
  downcased: providers quote the same identifier in more than one spelling, and two
  spellings must not be two rows.
  """
  def changeset(suppression, attrs) do
    suppression
    |> cast(attrs, [
      :email,
      :state,
      :provider,
      :provider_event_id,
      :reason,
      :message_id,
      :occurred_at
    ])
    |> validate_required([:email, :state, :provider, :provider_event_id])
    |> put_change(:email, normalize_email(attrs))
    |> put_change(:message_id, normalize_message_id(attrs))
    |> validate_email()
    |> validate_length(:reason, max: @reason_length)
    |> validate_length(:message_id, max: @message_id_length)
    |> validate_length(:provider_event_id, max: @provider_event_id_length)
    # Matched BY NAME rather than on `:unique`, for the reason
    # `Courier.Idempotency.refusal/1` gives: a future unique index on this table
    # must not be able to silently become a refusal courier is asking about.
    |> unique_constraint([:provider, :provider_event_id],
      name: :email_suppressions_provider_idempotency_index
    )
  end

  defp normalize_email(%{email: email}), do: Suppressions.normalize(email)
  defp normalize_email(_attrs), do: nil

  # RFC 5322 §3.6.4's angle brackets are HEADER syntax, not part of the identifier.
  # `Courier.Deliver.tag/2` writes `<courier-<uuid>@cafaye.com>` on the wire, and
  # providers quote that value back in whichever form their own parser hands them:
  # Postmark's `MessageID` carries the brackets, SES's `originalHeaders` carries
  # them, and a raw SMTP bounce's `In-Reply-To` sometimes does not. Storing the two
  # spellings as two rows would make "did this bounce tie back to that send" a
  # question about the provider rather than about the send.
  #
  # The `@cafaye.com` suffix is left in place, and that is deliberate: it is part of
  # the identifier, and stripping it would be a heuristic that collapses
  # `courier-x@cafaye.com` and `courier-x@elsewhere.test` into one value. The
  # bounce ties back through `outbox_events.message_id`, which courier stores
  # bracket-free, so the bracket is the only difference courier has to absorb.
  defp normalize_message_id(%{message_id: "<" <> rest = id}) do
    if String.ends_with?(rest, ">"), do: String.trim(rest, ">") |> String.trim(), else: id
  end

  defp normalize_message_id(%{message_id: id}) when is_binary(id), do: String.trim(id)
  defp normalize_message_id(_attrs), do: nil

  defp validate_email(changeset) do
    validate_change(changeset, :email, fn :email, email ->
      # The same shape `Courier.Mailers` validates a recipient with, and for the
      # same reason: one definition of "an address courier can send to", so the
      # ingest boundary and the compose boundary cannot disagree about it.
      if Regex.match?(~r/^[^@\s,;]+@[^@\s,;]+\.[^@\s,;]+$/, email),
        do: [],
        else: [email: "is not an email address"]
    end)
  end
end
