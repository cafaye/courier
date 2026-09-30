defmodule Courier.Repo.Migrations.CreateIdempotencyKeys do
  use Ecto.Migration

  @moduledoc """
  One row per `(account, endpoint, key)`: the answer courier already gave, kept so
  the caller who timed out can ask again and get the same one.

  Core's `docs/openapi-conventions.md` §Idempotency is the specification, and
  every column here is one of its sentences:

  | column | core's sentence |
  | ------ | --------------- |
  | `account_id` + `endpoint` + `idempotency_key` | "Scope: the `(endpoint, principal, key)` triple" |
  | `request_hash` | "Replay with the same key **and** the same request body returns the original response" — and "Replay with the same key but a different body returns 409 `idempotency_key_reused`". The hash is what tells those two apart, so it is courier's, not the client's |
  | `state` | the request that is *running*. core does not describe the concurrent case, and without it two simultaneous requests with one key would both execute and both insert — the exact duplicate this table exists to prevent |
  | `response_status` / `response_body` / `response_content_type` | "returns the original response" — the response has to be stored whole, because the 201 on this endpoint carries a signing secret that exists nowhere else and cannot be re-derived |
  | `expires_at` | "Retention: 24 hours" |

  `unique (account_id, endpoint, idempotency_key)` is what makes the claim at the
  database rather than in a check a caller might forget. Two requests with one key
  arriving together both try to insert, one of them loses on this index, and the
  loser is told so by the constraint rather than by a read-then-write it could
  lose between.

  `endpoint` is the **concrete** request path, not the route pattern, and that is
  a decision rather than an oversight: `POST /v1/webhook_endpoints/{id}/test` is a
  different endpoint for every id, and keying on the pattern would make a client
  that reuses one key to test four endpoints get a 409 on the second — which
  reads as courier losing a key it never had.

  There is no index on `state` and no index on `account_id` alone: the only two
  queries this table serves are the unique lookup above and the expiry sweep, and
  an index for a query nobody runs is a write cost on every insert.
  """

  def change do
    create table(:idempotency_keys, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :account_id, :uuid, null: false
      add :endpoint, :text, null: false
      add :idempotency_key, :string, null: false
      add :request_hash, :string, null: false

      add :state, :string, null: false, default: "in_flight"
      add :response_status, :integer
      add :response_body, :binary
      add :response_content_type, :string

      add :expires_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:idempotency_keys, [:account_id, :endpoint, :idempotency_key],
             name: :idempotency_keys_account_id_endpoint_key_index
           )

    # The expiry sweep. Partial on the rows that are still inside their retention
    # window would be useless here — this is the query that finds the ones that
    # are *not*, and they are a shrinking fraction of the table, so the index
    # earns itself on the rows the sweep skips.
    create index(:idempotency_keys, [:expires_at], name: :idempotency_keys_expires_at_idx)

    create constraint(:idempotency_keys, :idempotency_keys_state_check,
             check: "state IN ('in_flight', 'completed')"
           )
  end
end
