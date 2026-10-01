defmodule Courier.Deliver do
  @moduledoc """
  Where courier's three promises meet: the user's preference wins, the
  provider's answer is recorded, and the event describing the send is written in
  the same transaction as the send.

      iex> welcome(%{user_id: user_id, email: email, name: name, url: url})
      {:ok, %{notification_type: "welcome", message_id: message_id, event_id: event_id}}

  The order of the checks is the contract:

    1. **The type is one courier sends.** `:unknown_notification_type` — courier
       does not guess what a caller meant.
    2. **The payload names a user.** `:missing_user_id` — there are no
       preferences to check without one, and no user to attribute the send to.
    3. **The payload can be rendered.** `{:error, {:invalid_payload, changeset}}`
       — refused *before* the provider is asked, because a provider that accepts
       a mail courier cannot build has now sent something to a person.
    4. **The user wants it.** `:suppressed` — no mail, no event, no record of a
       send that did not happen.
    5. **The mailbox can receive it.** `{:error, {:suppressed_address, state}}` —
       a hard bounce (RFC 5321 §5.1.1, `:undeliverable`) or a spam complaint
       (RFC 2142 §5, `:suppressed`) recorded by a provider. Also before the
       provider is asked, and also no mail, no event, no record.
    6. **The message has something in it.** `{:error, :empty_message}` — a
       rendered message with neither a text nor an HTML body. `Swoosh` would
       accept it and answer a provider-shaped id, so this is the last check before
       the transaction rather than an afterthought inside it.

  Steps 4 and 5 are two different questions and the order is deliberate: "does
  this person want this mail?" is asked before "can this mailbox still receive
  it?", because the user's own answer is the one they can act on. Both stop the
  send — mailing a dead address costs a sending domain its reputation, and mailing
  somebody who marked you as spam costs more.

  What is left is one transaction: the provider is called and the outbox row is
  written. If the provider refuses, the transaction rolls back and there is
  nothing claiming a mail went out; if it accepts, the row is there to be
  published and the caller gets the message id and the event's id.

  Nothing here touches NATS. The relay that publishes is
  `Courier.Workers.ProcessOutboxWorker`.
  """

  alias Courier.Events
  alias Courier.Mailer
  alias Courier.Mailers
  alias Courier.NotificationPreferences
  alias Courier.OutboxEvent
  alias Courier.Repo
  alias Courier.Suppressions

  @doc """
  Sends the `welcome` mail — the payload of the platform's user-created event.
  """
  @spec welcome(map()) :: {:ok, map()} | {:error, term()}
  def welcome(payload), do: deliver(:welcome, payload)

  @doc """
  Sends the `password_reset` mail.
  """
  @spec password_reset(map()) :: {:ok, map()} | {:error, term()}
  def password_reset(payload), do: deliver(:password_reset, payload)

  @doc """
  Sends the `team_invitation` mail.
  """
  @spec team_invitation(map()) :: {:ok, map()} | {:error, term()}
  def team_invitation(payload), do: deliver(:team_invitation, payload)

  @doc """
  Sends the mail for `type`, for a caller that has the type as data rather than
  as a function to call.
  """
  @spec email(atom() | String.t(), map()) :: {:ok, map()} | {:error, term()}
  def email(type, payload), do: deliver(type, payload)

  defp deliver(type, payload) do
    with {:ok, type} <- fetch_type(type),
         {:ok, user_id} <- fetch_user_id(payload),
         {:ok, email} <- Mailers.build(type, payload),
         :ok <- fetch_preference(user_id, type),
         :ok <- fetch_address(email),
         :ok <- fetch_body(email) do
      send_and_record(type, user_id, email)
    end
  end

  defp fetch_type(type) do
    if to_string(type) in Mailers.types() do
      {:ok, to_string(type)}
    else
      {:error, :unknown_notification_type}
    end
  end

  defp fetch_user_id(payload) do
    case Mailers.user_id(payload) do
      nil -> {:error, :missing_user_id}
      user_id -> {:ok, user_id}
    end
  end

  defp fetch_preference(user_id, type) do
    if NotificationPreferences.enabled?(user_id, type, :email) do
      :ok
    else
      {:error, :suppressed}
    end
  end

  # **After** the preference and not before, which is the order
  # `Courier.Suppressions`'s own moduledoc states: "does this person want this
  # mail?" is asked before "can this mailbox still receive it?". Both stop the
  # send; the order decides which refusal a caller is told about, and the user's
  # own answer is the one they can act on — changing an address they no longer
  # want mail at would be a strange remedy to offer.
  #
  # It is here rather than in an HTTP controller because a hard-bounced mailbox
  # does not get mail *whatever the caller asked for*, and every caller of this
  # module is a caller of that promise. `Courier.Suppressions` answers
  # `suppressed?/1` and `state/1`; the state is read rather than the boolean
  # because the two mean different things to whoever reads the refusal — a pile of
  # `:undeliverable` is list hygiene, a pile of `:suppressed` is a content and
  # sender-reputation problem — and a boolean would have thrown that away.
  #
  # `state/1` costs one `EXISTS` per state it tests, up to two, on the path every
  # send takes. That is a deliberate trade for a reason that is not performance: the
  # fold is documented as the precedence, and calling it is how a caller cannot
  # reimplement the precedence wrongly.
  defp fetch_address(email) do
    case Suppressions.state(recipient(email)) do
      nil -> :ok
      state -> {:error, {:suppressed_address, state}}
    end
  end

  # The last thing checked before the provider, and the cheapest thing to get
  # wrong: `Swoosh` delivers a bodiless email and answers a provider-shaped id, so
  # without this a message with nothing in it would be recorded as delivered and
  # published as `courier.email.delivered`. See `Courier.Mailers.body?/1`.
  defp fetch_body(email) do
    if Mailers.body?(email), do: :ok, else: {:error, :empty_message}
  end

  # The provider call is inside the transaction on purpose. The send is the state
  # change and the row records it, and a row that exists for a send that did not
  # happen is a lie the platform will act on. The cost is that courier holds a
  # transaction open across a network call; that is the outbox's price, not a
  # mistake, and a send is one HTTP request.
  defp send_and_record(type, user_id, email) do
    message_id = "courier-" <> Ecto.UUID.generate()

    case Repo.transaction(fn ->
           case Mailer.deliver(tag(email, message_id)) do
             {:ok, _metadata} -> record(type, user_id, message_id, email)
             {:error, reason} -> Repo.rollback({:provider, reason})
           end
         end) do
      {:ok, result} ->
        {:ok, result}

      # The two failures are kept apart on the way out: a provider that said no
      # is worth retrying, and a row that could not be written is an incident.
      {:error, {:provider, reason}} ->
        {:error, {:delivery_failed, reason}}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, {:event_not_recorded, changeset}}
    end
  end

  defp record(type, user_id, message_id, email) do
    case %OutboxEvent{}
         |> OutboxEvent.changeset(%{
           type: Events.delivered_type(),
           subject: message_id,
           data: data(user_id, type, message_id, email)
         })
         |> Repo.insert() do
      {:ok, event} ->
        %{notification_type: type, message_id: message_id, event_id: event.id}

      {:error, changeset} ->
        Repo.rollback(changeset)
    end
  end

  # The send's own fields, and nothing from the payload: this goes to every
  # subscriber on the bus, and a verification token or an invitation id in there
  # would be a credential leak into a fan-out. The recipient is here because a
  # consumer that has to ask "who got this?" in order to act on it will not.
  defp data(user_id, type, message_id, email) do
    %{
      "message_id" => message_id,
      "user_id" => user_id,
      "notification_type" => type,
      "email" => recipient(email)
    }
  end

  defp recipient(%Swoosh.Email{to: [{_name, address} | _]}), do: address

  # A real Message-ID header carrying the id courier returns and records, so a
  # bounce or a complaint that quotes it can be tied back to the row.
  defp tag(email, message_id) do
    Swoosh.Email.header(email, "message-id", "<#{message_id}@cafaye.com>")
  end
end
