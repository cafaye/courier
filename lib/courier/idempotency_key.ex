defmodule Courier.IdempotencyKey do
  @moduledoc """
  One `(account, endpoint, key)` triple, and the answer courier gave it.

  Two states, and the distinction is the whole mechanism:

    * `in_flight` — the request holding this key is **running**. The row exists so
      that a second request carrying the same key knows to wait rather than start
      a duplicate. It is written before the controller runs and completed after,
      which is the only ordering in which two concurrent requests with one key
      cannot both execute.
    * `completed` — the response is stored and a later request with the same key
      gets it back with `Idempotency-Replayed: true`.

  `request_hash` is courier's, over the decoded body, and it is what separates a
  retry (same key, same body → the original response) from a reuse (same key,
  different body → 409 `idempotency_key_reused`). The hash is taken over the
  *decoded* params rather than the raw bytes on purpose: two bodies that mean the
  same thing are the same request, and a client that reformats its JSON should
  get a replay rather than a conflict it did nothing to cause.

  `response_body` is a binary rather than text because it is stored verbatim. On
  `POST /v1/webhook_endpoints` it is the 201 that carries the signing secret, and
  a re-serialized copy of a response containing a credential is a second copy of
  the credential. It is read back exactly as it was sent, and nothing logs it.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @states [:in_flight, :completed]

  @primary_key {:id, Ecto.UUID, autogenerate: true}

  @type t :: %__MODULE__{}

  @doc false
  def states, do: @states

  schema "idempotency_keys" do
    field :account_id, Ecto.UUID
    field :endpoint, :string
    field :idempotency_key, :string
    field :request_hash, :string

    field :state, Ecto.Enum, values: @states, default: :in_flight
    field :response_status, :integer
    field :response_body, :binary
    field :response_content_type, :string
    field :expires_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  The changeset for a claim on a key. Every field is courier's or the client's
  verbatim — a caller can choose the key and the body, and nothing else.
  """
  def changeset(key, attrs) do
    key
    |> cast(attrs, [:account_id, :endpoint, :idempotency_key, :request_hash, :expires_at])
    |> validate_required([:account_id, :endpoint, :idempotency_key, :request_hash, :expires_at])
    |> unique_constraint([:account_id, :endpoint, :idempotency_key],
      name: :idempotency_keys_account_id_endpoint_key_index
    )
  end

  @doc """
  The changeset that stores the response on a claim that was already made.
  """
  def completion(changeset, status, body, content_type) do
    changeset
    |> change(%{
      state: :completed,
      response_status: status,
      response_body: body,
      response_content_type: content_type
    })
  end
end
