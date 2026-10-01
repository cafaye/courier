# REPORT — courier-23: courier's backups are configured

## What this is

`config/kamal-backup.yml` exists, matches courier's real database, is reachable
from a deployment, and README states what it covers, what it does not, the
SecretBox answer, and the data-loss window. 22 tests hold all four.

**The gate ran.** `mise run prime` → `Result: 1156 passed`. `mix precommit` green
(warnings-as-errors). `core/harness/bin/gate-check --prove .` → 0 failures, and
`bin/gate-self-test` → 11 passed, 0 failed. Committed on this branch, not pushed.

---

## 1. The config I wrote

### `config/kamal-backup.yml` — rendered, not a template

kit's `templates/kamal/kamal-backup.yml.erb` requires `KIT_SERVICE` and emits
`app: <%= service %>`. What lands here is the **rendered** output with
`app: courier` as a literal.

That is not tidiness. Kamal evaluates ERB in `config/deploy.yml` because Kamal owns
that file. `kamal-backup` does not evaluate ERB anywhere:
`KamalBackup::ConfigFile#data` reads the path with `YAML.safe_load` and nothing
else (kamal-backup 0.5.2, `lib/kamal_backup/config_file.rb:57`). So an
unrendered `app: <%= service %>` is **not a syntax error** — YAML reads it as a
literal scalar — and the failure is a restic repository whose snapshots are
written under `databases/<%= service %>/primary/postgres.pgdump` and tagged
`app:<%= service %>`, which no `kamal-backup list` filtered on `app:courier` will
ever find. A backup nobody can find is a backup nobody reads.

The other keys, all verified against the gem's source rather than recalled:

| Key | Value | Where I verified it |
| --- | --- | --- |
| `app` | `courier` | snapshot path + `app:` restic tag |
| `accessory` | `backup` | `config_file.rb:78` → `KAMAL_BACKUP_ACCESSORY` |
| `databases[0].name` | `primary` | LABEL for the path and tag; **not** a database name |
| `databases[0].adapter` | `postgres` | `Courier.Repo` is the only database courier has |
| `databases[0].url` | `{secret: DATABASE_URL}` | same variable `config/runtime.exs` requires |
| `databases[0].password` | `{secret: DATABASE_PASSWORD}` | `PGPASSWORD`, never argv |
| `restic.repository` | `{secret: RESTIC_REPOSITORY}` | whole URL is a secret; a guessed bucket is a guessed dump destination |
| `restic.password` | `{secret: RESTIC_PASSWORD}` | |
| `restic.init_if_missing` | `true` | creates the *repository inside* the bucket, not the bucket |
| `restic.retention` | 7/7/4/6/2 | written out, ≈26 snapshots |
| `restic.check_after_backup` | `true` | |
| `backup.schedule` | `1d` | 86,400s → the data-loss window |
| `paths:` | **absent** | courier keeps nothing on local disk — asserted from the schema |

No key I could not verify was written. Two keys kit's accessory needs
(`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`) are **deliberately absent from this
file**: `ConfigFile::TOP_LEVEL_KEYS` is `app accessory databases paths
restore_from restic backup state`, and there is no key anywhere in it for an AWS
credential — restic reads them from its own environment, which is the
accessory's. A test asserts both directions, so a future reader does not "tidy"
the asymmetry away.

### `config/deploy.yml` — kit's template, courier's facts

Copied from `templates/kamal/deploy.yml.erb` at kit `d201080` (the kit-20 merge
that replaced kit's own backup toolchain). Differences from the template: **three
— two changes and one absence.**

1. **The proxy healthcheck is `/readyz`, not `/up`.** `CourierWeb.Router` serves
   `/healthz` and `/readyz` and nothing else at the root. `/up` is a 404 on every
   probe the proxy makes, so the container never becomes healthy and
   `kamal deploy` tears the rollout back after `deploy_timeout` — on a release
   that is otherwise fine. `/readyz` rather than `/healthz` because liveness
   answers whenever the VM can dispatch: a database outage would look healthy and
   courier would keep taking traffic it cannot serve.
2. **`env.secret` carries courier's boot contract**, read off `config/runtime.exs`'s
   `raise`s rather than from memory: `SECRET_KEY_BASE`,
   `COURIER_SECRET_BOX_KEY`, `COURIER_INBOUND_RESEND_SECRET`,
   `COURIER_ERROR_RELAY_TOKEN`, `COURIER_SMTP_USERNAME`, `COURIER_SMTP_PASSWORD`.
   A deploy omitting any of them does not degrade — it does not start.
   `COURIER_ERROR_REPORTING_DSN` and `COURIER_ERROR_SINK_DSN` are **deliberately
   not listed**: they are optional, and Kamal refuses a name in `env.secret` with
   no value in `.kamal/secrets`.
3. **There is no `migrate:` key — in either file.** See §6.

Verified against the real binaries:

```
$ kamal config --version latest        # kamal 2.12.0
:repository: ghcr.io/cafaye/courier
:accessories:
  backup:
    image: ghcr.io/crmne/kamal-backup:0.5.2
    files:
    - config/kamal-backup.yml:/app/config/kamal-backup.yml:ro
    ...
(exit 0)

$ kamal-backup validate -c config/deploy.yml   # kamal-backup 0.5.2
ok
(exit 0)
```

The image resolution is the check kit's own test makes deliberately: a doubled
registry host is valid YAML *and* a working `kamal config` run, and only the
resolved `:repository` shows it.

---

## 2. Reachability

**One line makes it reachable**, and it is in `config/deploy.yml`:

```yaml
accessories:
  backup:
    image: ghcr.io/crmne/kamal-backup:0.5.2
    files:
      - config/kamal-backup.yml:/app/config/kamal-backup.yml:ro
    env:
      secret:
        - DATABASE_URL
        - DATABASE_PASSWORD
        - RESTIC_REPOSITORY
        - RESTIC_PASSWORD
        - AWS_ACCESS_KEY_ID
        - AWS_SECRET_ACCESS_KEY
    volumes:
      - <%= service %>_backup_state:/var/lib/kamal-backup
```

Nothing in courier reads the file. `kamal-backup` opens it inside that container,
which is why the mount is the whole of reachability, and why
`Courier.BackupConfigTest` reads **both** files and asserts the mount by its
destination path rather than by "a file is mounted somewhere".

**The two files are one contract, and neither can check itself.** `kamal-backup
validate` builds the accessory's environment from the deploy config's
`env.secret` list and from nothing else, so a secret named in one and missing
from the other is a valid file in each, internally consistent in each, and a
**rejected pair**. That was measured, not asserted: the real binaries accept the
pair courier ships, and reject it with `RESTIC_REPOSITORY or RESTIC_REPOSITORY_FILE
is required` when one line is deleted.

**No change was needed in kit** to make this reachable. The mechanism kit ships
works as documented — `config/deploy.yml`'s `files:` mount, the accessory's
`env.secret` list, the tool's own config reader — and courier's adoption of it
needed no change to any of them. Two kit-side observations are in §6, neither of
which blocks this.

I also added `.kamal/secrets` and `.kamal/secrets-*` to `.gitignore`. courier's
`.gitignore` had neither, and `config/deploy.yml` now names a dozen credentials
whose *values* `kamal init` writes into `.kamal/secrets`. The ignore is narrowed
to those two paths rather than the whole directory, because `.kamal/hooks/` holds
a committed script and `git add .kamal/` would have made it invisible.

---

## 3. What it covers, and what it does not

### Covered — one Postgres database, `pg_dump`, restic in R2

Every table courier owns is content, so the dump is the whole of courier's durable
state. Seven tables from the migrations plus `oban_jobs` from Oban's DDL:
`notification_preferences`, `webhook_endpoints`, `webhook_deliveries`,
`outbox_events`, `email_suppressions`, `idempotency_keys`, `oban_jobs`.

### Not covered

- **Object storage and anything held in it.** There is none today — no bucket, no
  attachment table, no `bytea` column for uploaded content. Checked rather than
  assumed: `information_schema` on the connected database, every run. There is
  exactly one `bytea` column, `idempotency_keys.response_body`, which is a cached
  HTTP response body *inside* Postgres, expired on `expires_at` — not an upload.
  No column name contains `bucket`/`object`/`storage_key`/`blob`/`file`, no
  `config/*.exs` configures an object store, and `openapi.yaml` declares no
  multipart operation.
- **Anything in a container's ephemeral filesystem.** Deliberately nothing: no
  `paths:` key, no data volume on the accessory, and the release writes nothing
  to a volume. `evidence` reporting `latest_file_backup: null` is the correct
  answer here, not a gap.
- **Postgres roles and tablespaces.** The dump is one database with
  `--no-owner --no-privileges`, so the role comes from how the `postgres`
  accessory was provisioned.
- **The sealing key.** See §4.

---

## 4. The SecretBox answer

**A restore brings every signing secret back as ciphertext, and courier cannot
read its own rows until `COURIER_SECRET_BOX_KEY` is supplied unchanged.** The
rows come back; the ability to sign with them does not.

The key cannot be in the backup, and that is the reasoning rather than an
omission: `webhook_endpoints.secret` is sealed with AES-256-GCM under
`COURIER_SECRET_BOX_KEY` (`Courier.SecretBox`), and `config/runtime.exs` **raises
at boot without it** — so it is not in the database, and it cannot be in a dump of
the database. It lives in `.kamal/secrets` and in the deployment's environment.

So a restored courier is a courier that cannot verify a customer can verify it:
every signature it produced before the restore opens with the old key, and one
produced after a key change opens with neither. Every tenant whose endpoints are in
that dump has to re-receive their signing secret until the key is back.

This is asserted, not asserted-in-prose. `COURIER_SECRET_BOX_KEY` is asserted
**absent** from `config/kamal-backup.yml` and from the accessory's `env.secret`,
and **present** in `config/runtime.exs`. The presence half is what stops the
absence from being a boundary that deletes everything — the rule this repository
has been bitten by three times in telemetry alone.

Keeping it out of the backup is a *storage* decision, not a rotation one. Rotating
it still means every stored secret has to be re-sealed under the new key, and
losing it means every stored secret has to be re-issued to its customer, because
the plaintext cannot be recovered from the ciphertext.

The second key, in the other direction: **`RESTIC_PASSWORD` encrypts the repository
and nothing else, so lose it and every snapshot in it is permanently unreadable** —
including the ones you have not lost yet. It is not in this repository, not in the
database, and not in the backup (a test asserts no credential value appears in
any line `config/kamal-backup.yml` hands the tool).

---

## 5. The exact data-loss window

**Up to 24 hours of committed transactions are lost** if courier's database is
destroyed. With the shipped `schedule: 1d` that is 86,400 seconds, read out of
the tool's own `normalize_duration` rather than assumed.

Three refinements, all from the runbook and none of them making the number better:

- **It is measured from when the previous backup FINISHED**, not to a wall-clock
  deadline. The scheduler's loop is *run a backup, then sleep the interval*, so
  one cycle is the interval **plus that run's duration**.
- **`pg_dump` opens a single repeatable-read transaction**, so the snapshot is
  taken at the **start** of the dump. The gap between two snapshot points is that
  whole cycle, never exactly 24 hours.
- **A failed backup is not retried until the next interval.** The loop catches the
  failure, logs it, sleeps. A dump failing for six hours has not been retried six
  times. **The alert is the backup.**

Also stated in README: no WAL shipping and no base backup, so this is not PITR;
retention reaches back roughly a year and forward no more than a day; and **R2 has
no object versioning and no Object Lock**, so a snapshot `prune` deletes is gone.

`Courier.BackupConfigTest` reads `schedule:` from the config and asserts README
quotes the matching window, so changing the cadence without changing the README
goes red. Verified: `schedule: 6h` fails it.

---

## 6. Kit changes I did NOT make

Two observations, both dispatchable, neither blocking. I did not touch kit.

**(a) `kit.ref` predates the template it now vendors.** `kit.ref` pins `a095992`,
and `templates/kamal/*` landed in `d201080` (kit-20). `bin/dev`'s
`stack_is_usable` only checks `templates/compose/`, so nothing detects that the
pinned ref has no Kamal templates at all — a service following kit's own
"Adopting this" step 1 would fetch the pinned ref, look for
`templates/kamal/kamal-backup.yml.erb`, and not find it.

*Suggested change, in kit:* either add `templates/kamal/deploy.yml.erb`,
`templates/kamal/kamal-backup.yml.erb` and `templates/kamal/drill.sh` to
`stack_is_usable`, or state the minimum kit ref in `templates/kamal/README.md`'s
"Adopting this" and have courier's `kit.ref` bumped. I rendered by hand from a
kit checkout and recorded the ref in the file's own header, so the file says where
it came from — but a service should not have to know that.

**(b) `templates/kamal/README.md` promises a `migrate` command that does not
exist.** Its "Adapting per language" table says an Elixir service should "set the
`migrate` command in `deploy.yml.erb` to yours", and its "Adopting this" step 4
says `kamal setup`. But the shipped `deploy.yml.erb` has **no `migrate:` key at
all**, and Kamal 2.12.0 rejects the document if you add one:

```
$ kamal config --version latest
ERROR (Kamal::ConfigurationError): unknown key: migrate
```

Kamal 2 runs migrations from `.kamal/hooks/pre-deploy`. So a service that follows
kit's README has nowhere to put its migration command and a deploy that never
runs one.

*Suggested change, in kit:* correct the README's per-language table to name the
`.kamal/hooks/pre-deploy` hook (and say what it receives), and either add the
hook to `templates/kamal/` or say plainly that a service writes its own.

**Consequence in courier, stated rather than fixed:** **`bin/migrate` is not run by
a `kamal deploy`.** `bin/migrate` ships in this repository's release
(`Courier.Release.migrate/0`, `rel/overlays/bin/migrate`) and the compose stack
uses it, but a Kamal 2 deploy has nowhere to put it. I did not add
`.kamal/hooks/pre-deploy`: silently changing what a deploy does is the thing this
repository's rules keep refusing, and a hook is a decision with its own failure
modes (it runs on the deploy host, needs the database reachable, and a migration
that fails there fails the deploy). It is courier's file to add, deliberately.

---

## 7. Tests, and proof they can fail

22 tests, **1156 whole suite** (was 1134).

| File | Count | Tier | Why there |
| --- | --- | --- | --- |
| `test/courier/backup_config_test.exs` | 16 | no database (577, was 561) | reads two files off disk; holds the cross-file secret contract |
| `test/courier/backup_tables_test.exs` | 6 | database (579, was 573) | its subject is the SCHEMA, read from `information_schema` |

The split is the claim, not a convenience. A backup configuration checkable only
against a live postgres is one a database-less runner silently skips — and the
no-database tier exists precisely to catch that. The schema check is a
`DataCase` because "nothing on local disk" is a statement about courier's
**columns**, and asserting it from the comment beside `paths:` would be asserting
the comment.

Reader: `test/support/kamal_config.ex`, in courier's own `test/support` (copied
per service, like `openapi_paths.ex`). No YAML dependency — courier has none and
adding one is not a decision this repository has made — so it reads the handful of
keys by indentation and **refuses rather than under-reads**: missing file, empty
file, absent key, a `databases:` with no entries, an accessory with no
`env.secret`, and a `secret:` whose value is not a NAME all raise with a message
naming what was found.

### The mutations, because a check that cannot fail is not a check

Seven, each run against the real files:

| # | Injected | Caught by |
| --- | --- | --- |
| 1 | deleted the `files:` mount | mount assertion |
| 2 | dropped `RESTIC_PASSWORD` from the accessory's list only | the one-directional secret contract |
| 3 | `app: <%= service %>` (unrendered) | three tests, including the ERB-tag assertion |
| 4 | wrote an `s3:https://…r2…` URL where a name belongs | reader raises: a value, not a name |
| 5 | added a `paths:` list | the no-paths assertion |
| 6 | `schedule: 6h` with README unchanged | the schedule/window pair |
| 7 | `CREATE TABLE _mutation_probe (payload bytea)` on the live database | the bytea assertion **and** the unexplained-table assertion |

Mutation 7 is the one worth noting: a `bytea` column for uploads trips **both**
the "no file bytes" check and the "every table is courier's own" check, which is
what stops the omission from staying silent.

### The suite is not seed-stable, and that predates this packet

Running the whole suite across 26 seeds on this branch and on `a8f15cc` (the merge
before it) found failures in `Courier.ErrorRelayTest` and
`Courier.TelemetryCanaryTest` — **3 of 16 seeds on master, 1 of 16 on this
branch**, and `TelemetryCanaryTest`'s 404 case failed on 14 of 14 master runs at
seed 55433. Both are pre-existing order-dependence in tests this packet did not
touch, and the branch is not the cause: same seeds, same tests, master fails more
often. The 22 tests added here were run across 10 seeds on their own and are
**22/22 every time**.

Not fixed, and stated rather than absorbed: `eventually/3` in
`error_relay_test.exs` is a 200-iteration busy poll with no deadline, and
`TelemetryCanaryTest` reads spans from a shared ETS table that an `async: false`
test in another file can still be writing into. Both are real defects and both
belong to a packet about them, not to one about backups. Fixing them here would
have meant loosening an assertion, which is the one thing this repository's rules
refuse.

Three bugs were found and fixed while building the reader, all of the same family
— a reader that under-reads and agrees with nothing:

- `length/1` on a string is `List.length/1`, which raises. Every line, every file.
- `{table, column, type} <- rows` does not match a **list** row, so three
  assertions silently reported "no bytea column anywhere" about a database that
  has one. `List.to_tuple/1` on each row, with the failure recorded.
- `MapSet.new/1` over a **map** builds a set of `{key, value}` tuples, so every
  table read as unexplained.

---

## 8. Floors, moved in the same commit

| Where | Was | Now |
| --- | --- | --- |
| `gate.yml` `proof.minimum` | 1128 | **1150** (measured 1156, margin 6 as before) |
| `.github/workflows/ci.yml` whole suite | 1128 | **1150** |
| no-database tier | 561 (24 files) | **577** (25 files) |
| database tier | 573 (27 files) | **579** (28 files) |
| `README.md` prose | 1134 / 561 / 573 | **1156 / 577 / 579** |
| `AGENTS.md` tier paragraph | 918-era counts | **1156 / 577 / 579** |

`1156 = 577 + 579`, which is the consistency check worth making: a whole suite
that is not the sum of its own tiers is one where a file has been left out of
both. The `AGENTS.md` paragraph had drifted to 918/405/513 for several packets —
the failure `AGENTS.md` itself documents, where the floor stayed green (it is a
decrease detector) while the number beside it stopped describing the tree. It is
corrected here along with the floors, not instead of them.

## 9. Not done, deliberately

- **No push, no merge, no tag.** One commit on this branch.
- **`mix.lock` unchanged** (`git diff --exit-code -- mix.lock` is clean; no
  dependency was added).
- **No change to identity, kit, docs, or any other repository.**
- **No `.kamal/hooks/pre-deploy`** — §6(b).
- **No drill run against a deployed host.** `kamal-backup evidence` needs a
  reachable accessory (`kamal accessory exec` over SSH); the local machine has no
  deployed host, so the verification here is `kamal-backup validate` on the pair
  plus the suite. The drill is kit's `bin/drill`, which courier has not copied —
  it is a separate adoption step, and README points at the runbook for it.