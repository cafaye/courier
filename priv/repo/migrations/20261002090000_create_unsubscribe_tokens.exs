defmodule Courier.Repo.Migrations.CreateUnsubscribeTokens do
  use Ecto.Migration

  def change do
    create table(:unsubscribe_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true
      # **A digest, never the token.** The value in this column is a SHA-256 of the
      # 32 random bytes courier put in the `List-Unsubscribe` header, hex-encoded,
      # and it is the only half courier ever stores. RFC 8058 §3.1 asks the URI to
      # "contain an opaque identifier or another hard-to-forge component" and §6
      # says the same thing again about abuse; a digest is how courier answers
      # "hard to forge" AND "a database dump cannot unsubscribe anybody".
      #
      # The token itself is never written anywhere: it exists in the header of one
      # message and in the recipient's mail client, and courier can look one up but
      # never print it back. This is the same reasoning identity uses for its
      # opaque API tokens, and it is the reason the column is not named `token`.
      add :token_digest, :string, null: false
      # The three facts the unsubscribe acts on. `user_id` is an `Ecto.UUID` and
      # not a string because it is the very key `notification_preferences` is
      # indexed on, and it is also the subject core's `courier.notification.
      # suppressed` schema requires — so this row is where an unsubscribe can be
      # attributed to a person at all. `email_suppressions` has no `user_id`
      # because a provider does not know one; courier does.
      add :user_id, :uuid, null: false
      add :notification_type, :string, null: false
      add :email, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    # The lookup the endpoint does, and the only lookup: `find/1` is one indexed
    # equality on the digest, so a wrong token is a miss rather than a scan.
    create unique_index(:unsubscribe_tokens, [:token_digest])

    # Not for the endpoint. It exists so an operator can answer "which tokens did
    # this send mint, and what happens if one leaks" without scanning, and so the
    # row set for one user and one type is contiguous — the shape the suppression
    # table's new index uses for the same key.
    create index(:unsubscribe_tokens, [:user_id, :notification_type])

    # -------------------------------------------------------------------------
    # `email_suppressions` gains two nullable columns and `state` loses its NOT
    # NULL, because a one-click unsubscribe (RFC 8058) is a report about an
    # address that courier wrote itself rather than one a provider sent.
    #
    # **THE NULLABILITY IS THE WHOLE MECHANISM, and it is not a weakening of the
    # two-value vocabulary.** `create_email_suppressions` made this column NOT
    # NULL and the argument there is one this migration keeps: "a hard bounce marks
    # the address `undeliverable`, a complaint marks it `suppressed`, and there is
    # no third 'suppressed: true' boolean that cannot say which." That is still
    # exactly what is true — `state` is still an `Ecto.Enum` of two values
    # resolved in the changeset, with no database CHECK and no third value.
    #
    # What changes is that a row may now carry **no** state, which is a different
    # statement from carrying a third one: it says this row is not a fact about
    # the mailbox at all.
    #
    #   * **A bounce and a complaint are facts about the MAILBOX** and refuse every
    #     type courier sends. `Courier.Deliver` consults this table for a password
    #     reset as firmly as for a newsletter, so a *stateful* unsubscribe row
    #     would be a person who stops receiving product updates and then cannot
    #     reset their password.
    #   * **An unsubscribe is an instruction about ONE type**, and it is read back
    #     by `Courier.Suppressions.unsubscribed?/2` against `notification_type`.
    #
    # **`state/1` has always had this case.** Its own moduledoc spells the fold out
    # as "nothing at all -> `nil`; **rows, none carrying a state** -> `nil`; any row
    # `:suppressed` -> `:suppressed`; otherwise any row -> `:undeliverable`" — and
    # the middle line has been unreachable since the column was made NOT NULL,
    # because the only writer with no state was a soft bounce and it records no row
    # at all. This migration is what makes that line true, and `suppressed?/1` and
    # `find/1` already filter on `not is_nil(state)` for the same reason.
    #
    # `modify/3` with `from:` rather than an `execute/0`, so `change/0` stays
    # reversible — the convention `add_account_to_notification_preferences` set out
    # at length, and the reason a `down` here returns the table to what it was
    # instead of raising halfway.
    #
    # The two new columns are nullable for the same reason `state` now is: a
    # provider does not know whose address bounced, and a row that guessed would
    # put a stranger's uuid on a fact about a mailbox.
    # -------------------------------------------------------------------------
    alter table(:email_suppressions) do
      add :notification_type, :string
      add :user_id, :uuid
      modify :state, :string, null: true, from: {:string, null: false}
    end

    # **PARTIAL, and the `where` clause is the whole point.** `state IS NULL` is
    # the only value an unsubscribe row ever has, so the index covers exactly the
    # rows `Courier.Suppressions.unsubscribed?/2` looks for and none of the bounce
    # and complaint rows the address-level fold reads. A full index on
    # `(email, notification_type)` would be correct and would put every provider
    # report into the index a bulk send reads on every message.
    create index(:email_suppressions, [:email, :notification_type],
             where: "state IS NULL",
             name: :email_suppressions_unsubscribe_index
           )
  end
end
