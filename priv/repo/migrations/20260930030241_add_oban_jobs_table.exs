defmodule Courier.Repo.Migrations.AddObanJobsTable do
  use Ecto.Migration

  @moduledoc """
  courier's only queue is the outbox relay. Oban owns this table's shape; this
  migration is the versioned copy of Oban's own DDL, so a courier deploy and an
  Oban upgrade never disagree about the jobs table.
  """

  def up, do: Oban.Migrations.up(version: 14)

  def down, do: Oban.Migrations.down(version: 13)
end
