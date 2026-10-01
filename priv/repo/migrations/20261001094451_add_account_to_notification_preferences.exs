defmodule Courier.Repo.Migrations.AddAccountToNotificationPreferences do
  use Ecto.Migration

  @moduledoc """
  Records **which account is entitled to a user's preferences**, which is what
  turns `GET`/`PUT /v1/notification_preferences/:user_id` from an open surface
  into a tenant-scoped one.

  ## Why the column rather than a question courier asks identity

  `user_id` is a uuid from identity and courier holds no foreign key to it, so
  courier cannot look a user up and learn which account they belong to. Until
  this column there was no tenancy on this table at all: the row was keyed by
  `(user_id, notification_type)` and nothing else, so any caller who could write
  a `user_id` into a path could read and overwrite every other tenant's answers.

  So the account is recorded at write time, and read time compares it. That is
  the same shape `webhook_endpoints` already has, and it is deliberately the
  *only* place a user is ever attributed to an account in courier: when identity's
  membership question is answerable on the hot path, this column is what a
  verified answer would be reconciled against rather than a second source of
  truth.

  ## The uniqueness is unchanged, on purpose

  The index stays on `(user_id, notification_type)` rather than gaining an
  `account_id`. A user has **one** set of preferences, not one per account, and
  `Courier.NotificationPreferences.enabled?/3` — the delivery path, which is
  addressed by user and has no account in it — reads this table without one.
  Adding `account_id` to the index would let two accounts hold contradictory
  answers for the same person and leave that read choosing between them. The
  account is the row's **owner**, not part of its identity.

  ## The rows this migration removes

  Every existing row was written through a route with no authentication at all,
  so there is no honest way to say which account any of them belongs to. They are
  deleted rather than backfilled, and the three alternatives were all worse:

    * **Backfill to a placeholder account** puts every user's opt-outs under an
      account nobody owns, which is one `where account_id != ^caller` away from
      being readable by every tenant at once.
    * **Leave `account_id` nullable and treat `NULL` as "nobody's"** has the same
      answer and a worse shape: a nullable tenancy column invites the next query
      that forgets to filter on it, which is the exact bug this column exists to
      make impossible.
    * **Keep them and show them to whoever asks** is the cross-tenant hole.

  The direction the loss falls in is the safe one, and it is courier's own
  documented invariant rather than a hope: *silence is not consent*. A removed
  preference reads as no preference, which reads as **on**, so a user this
  migration forgets is a user courier mails — never a user's mail going to
  somebody else. Re-issuing an opt-out is one `PUT` from the account that owns
  the user, and there are no customers yet to have one to lose.
  ## Rolling back

  `down` drops the column and does not put the rows back, because they are gone
  and nothing in this repository kept a copy. That asymmetry is why the deletion
  is stated three times above rather than once: a rollback here is not a return to
  the previous state, it is the same state with one column fewer.
  """

  # `up/0` and `down/0` rather than `change/0`, because a `change/0` cannot
  # reverse a bare `execute/1` and Ecto says so by raising
  # `Ecto.MigrationError` **after** it has already run the statements it could
  # reverse. A reversible-looking `change/0` here is a rollback that half-applies
  # and then aborts, and `Courier.Release.rollback/2` is a real entrypoint rather
  # than a generated leftover — the version it is called with is somebody's
  # decision during an incident, which is the worst time to discover it raises.
  def up do
    # Two statements because Postgrex's extended query protocol refuses more than
    # one per call — and both inside the migration's own transaction, so the
    # column is never `NULL`: not even between them. A moment in which a row
    # exists with no owner is a moment a query written against the new code could
    # read one, and the whole reason this migration deletes first is that no such
    # moment exists.
    execute("DELETE FROM notification_preferences;")

    execute("ALTER TABLE notification_preferences ADD COLUMN account_id uuid NOT NULL;")
  end

  # Drops the column and does not put the rows back, which is what the moduledoc
  # above says a rollback is: the same state with one column fewer, not a return
  # to the previous one.
  def down do
    execute("ALTER TABLE notification_preferences DROP COLUMN account_id;")
  end
end
