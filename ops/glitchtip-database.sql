-- The error store's database and role, on courier's own postgres:17-alpine.
--
-- Mounted into `db` by docker-compose.errors.yml. The postgres image runs every
-- file in /docker-entrypoint-initdb.d against a freshly initialised data
-- directory and nowhere else, so:
--
--   * on a FRESH volume (the usual first run) this runs by itself;
--   * on an EXISTING volume it does not run, because the directory is not empty.
--
-- For the second case, apply it by hand once:
--
--   docker compose exec -T db psql -U postgres -d courier_dev \
--     -f /docker-entrypoint-initdb.d/10-glitchtip.sql
--
-- Every statement here is idempotent, so applying it twice — by hand and then
-- through the init hook, or by two people following this file at once — is not an
-- error. That is a deliberate choice over `DROP ... IF EXISTS` + `CREATE`: this
-- script is never destructive, so running it against a populated store cannot
-- lose recorded crashes.
--
-- WHY `\gexec` RATHER THAN `IF NOT EXISTS`
--
-- PostgreSQL has no `CREATE ROLE IF NOT EXISTS` and no `CREATE DATABASE IF NOT
-- EXISTS`. The obvious replacement, a `DO $$ ... EXCEPTION WHEN duplicate ... $$
-- block, does not work either and the reason is worth writing down because it
-- cost a run here: **`CREATE DATABASE` cannot execute inside a transaction
-- block**, and a `DO` block is always inside one, so the statement fails with
-- `ERROR: CREATE DATABASE cannot run inside a transaction block` *every time* —
-- including on a fresh server where the database genuinely does not exist. The
-- role half of that version worked, which is what made it worse than a plain
-- failure: the script appeared to do half its job.
--
-- `\gexec` is the portable answer. A `SELECT` returns the statement text only when
-- the object is missing, `\gexec` runs whatever came back, and on a populated
-- store the query returns no rows and nothing executes. It runs in autocommit
-- mode, so `CREATE DATABASE` is legal — which the image's invocation guarantees,
-- because `docker-entrypoint.sh` calls `psql -v ON_ERROR_STOP=1 -f "$f"` without
-- `--single-transaction`.
--
-- The `1 = 1` in the `SELECT` is noise that makes the intent explicit: this is a
-- conditional whose condition is "does not already exist", not a value being read
-- from anywhere.
--
-- WHY A SEPARATE ROLE AND A SEPARATE DATABASE, ON THE SHARED SERVER
--
-- The platform allows one postgres image and the isolation that matters is the
-- data, not the server. Crash reports are worth reading to an attacker — they
-- carry file paths, dependency versions and the shape of a system's internals —
-- so the error store gets a role that cannot read `courier_dev`. A separate
-- container on a second image string would break the fleet-wide
-- `postgres:17-alpine` pin and would not buy that: it separates the *process*, and
-- the compromise being modelled here is a SQL credential, which a second process
-- on the same server does not contain.
--
-- WHAT THIS DOES AND DOES NOT ISOLATE — measured, not assumed
--
-- Verified against a live server by creating a row in `courier_dev` and reading it
-- as this role: `ERROR: permission denied for table ...`. The store's role cannot
-- read courier's data.
--
-- It is **one-directional**, and saying so matters. This stack's courier role is
-- `postgres`, which is a superuser, so courier can read the error store. That is
-- pre-existing — the base `docker-compose.yml` has always run courier as
-- `postgres` — and a production deployment should use a role that is not. It is
-- also the acceptable direction: the error store holds no credential courier needs
-- to do its job, while courier's `postgres` role holds courier's whole database.
--
--
-- The credentials below are a local development constant for a stack that is
-- never published. Production sets its own; nothing reads this file but the
-- compose stack.

-- The role that owns the error store. LOGIN so GlitchTip can connect, and
-- `NOSUPERUSER NOCREATEDB NOCREATEROLE`: a migration bug inside the store should
-- not be able to reach the rest of the server. The role is also never granted
-- membership in anything, so those braces hold.
SELECT 'CREATE ROLE glitchtip LOGIN PASSWORD ''glitchtip'' NOSUPERUSER NOCREATEDB NOCREATEROLE'
WHERE 1 = 1
  AND NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'glitchtip')
\gexec

-- Its own database, owned by that role so GlitchTip's own migrations can create
-- tables in it.
SELECT 'CREATE DATABASE glitchtip OWNER glitchtip'
WHERE 1 = 1
  AND NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'glitchtip')
\gexec