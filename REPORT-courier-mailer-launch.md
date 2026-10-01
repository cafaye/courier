# REPORT — courier-mailer-launch

The brief's headline: *courier is one of the three things a buyer can purchase,
and out of the box it delivers nothing.*

That was accurate, and the mechanism was worse than the brief described. See
**Contradictions with the brief** below for the part of the premise that turned
out to be wrong.

---

## What changed

| File | What |
|---|---|
| `mix.exs` | `{:gen_smtp, "~> 1.0"}` declared, in every environment |
| `lib/courier/mailer_adapter.ex` | **new** — adapter resolution from the environment, the refusals, the credential-safe description |
| `lib/courier/application.ex` | second boot gate on the *effective* adapter |
| `lib/courier/mailer.ex` | moduledoc rewritten; the "no adapter ships" note was the defect, not the documentation |
| `config/runtime.exs` | the `adapter: Swoosh.Adapters.Local` line replaced by `Courier.MailerAdapter.adapter!(:prod)` |
| `config/config.exs` | `environment: config_env()` (the adapter gate needs to tell prod from test); `api_client: false` comment corrected |
| `config/dev.exs` | committed `adapter: Swoosh.Adapters.Local` **removed** |
| `config/test.exs` | `Swoosh.Adapters.Test` kept, with why it is right for a suite and wrong for a deployment |
| `test/support/smtp_server.ex` | **new** — a real `:gen_smtp_server` |
| `test/courier/smtp_delivery_test.exs` | **new** — 6 tests, the round trip |
| `test/courier/mailer_adapter_test.exs` | **new** — 33 tests, the refusals |
| `test/courier/mailer_adapter_credentials_test.exs` | **new** — 11 tests, the credential boundary |
| `gate.yml`, `.github/workflows/ci.yml` | floors ratcheted in the same commit |

---

## 1. The silent default: what I chose, and why

I chose the brief's **first** option — **refuse to boot in `:prod` when the
adapter is unset or `Local`** — and made the brief's **third** option the
*mechanism*: the adapter is a required config with no default.

These are not two choices, they are one. An adapter with no default is a
deployment that cannot start unless somebody chose one, which makes "refuse to
boot" the ordinary behaviour of a required setting rather than a special case
bolted on. There is no `Local` fallback anywhere in the prod path to remove
later, because there is nothing there.

**Why refusal and not a loud warning.** The failure and the fix are not
symmetric. A warning is one line in a log nobody reads; the deployment looks
healthy in the dashboard that matters. Worse, the damage is *already done* by the
time anyone could read the line: courier has accepted the send, written an
outbox row, and published a `delivered` event for mail that was never delivered.
Every downstream consumer of those events believes a person was told something.
A refusal at boot is a deploy that visibly fails — caught before the first
customer mail, which is the cheapest possible incident.

**Two gates, not one, and they read different things.**

1. `Courier.MailerAdapter.adapter!/1`, called from `config/runtime.exs`. Raises
   on an unset adapter, an unknown name, a module name, or `none` in prod.
2. `Courier.MailerAdapter.verify_boot!/0`, called from
   `Courier.Application.start/2`. Reads `Application.get_env(:courier,
   Courier.Mailer)` — the **effective** configuration — and raises if that cannot
   deliver.

The second reads a different input on purpose. Gate 1 judges the *environment*;
gate 2 judges what courier will actually *send through*. Re-checking the
environment twice would catch nothing.

In this tree gate 1 alone is sufficient, and I say so rather than implying
otherwise. What gate 2 adds is that it holds when gate 1 is bypassed or removed:
`runtime.exs` edited to name `Swoosh.Adapters.Local` directly (one line, no
environment variable — and the previous state of this repository was exactly
that), or any future path that configures the mailer without going through
`Courier.MailerAdapter` at all.

**Two places I went past the brief, both deliberate, both flagged:**

* `none` is refused in **dev** too, not only prod. Dev is where a developer
  proves to themselves that it works, and `Local` is what you point dev at to do
  exactly that. The escape hatch is `COURIER_MAIL_ADAPTER=none` — explicit,
  greppable, impossible to reach by forgetting a variable.
* `COURIER_MAIL_ADAPTER` takes a **name from a fixed set**, never a module. So
  `COURIER_MAIL_ADAPTER=Swoosh.Adapters.Local` cannot spell the silent adapter
  through the front door the refusal was built to close.

The refusal is **silent in `:test`**, because `config/test.exs` uses
`Swoosh.Adapters.Test` on purpose and `assert_email_sent/1` depends on it. Both
halves are asserted: prod refuses the silent adapters, test does not.

---

## 2. The SMTP round-trip test

**Server: `:gen_smtp_server`, shipped by `gen_smtp` itself, on `ranch`.**
Callback module: `Courier.TestSupport.SmtpServer.Callback` (Elixir, implementing
`:gen_smtp_server_session`).

**I did not use Bamboo, and I did not use a hand-rolled socket.** Bamboo is a
heavy dependency for a `only: :test` addition. Better: `gen_smtp` ships an SMTP
*server* alongside the client courier already needs, so this cost **zero new
dependencies**. That also matters for what the test can catch — a raw
`:gen_tcp` loop replying `"250 ok\r\n"` to anything would pass against a
structurally broken client, because it never parses the conversation. This one
parses it, enforces the reply codes, and hands back a real RFC-5322 body.

**Port: none is written down.** The listener is started with `port: 0` and the
assigned port is read back with `:ranch.get_port/1`, so the kernel picks a free
ephemeral port. The brief asked for an unusual high port; an ephemeral one is
strictly better, because two workers running this suite cannot collide. This
mattered in practice — courier's other workers and services were running while I
was.

**What each test drove, and what it asserted:**

| Test | Asserts |
|---|---|
| the message the provider received is the message courier composed | `from == "no-reply@cafaye.com"`, `to == ["roundtrip@example.com"]`, body contains `Subject: Welcome to caFaye` and the rendered greeting, `Content-Type: multipart/alternative`, and a `Message-ID: <…>` header |
| the adapter authenticates with the credentials it was configured with | the server **requires** a specific username/password and rejects anything else, so an arriving message proves courier put them into a real `AUTH` exchange; asserts `message.authenticated` |
| a relay that rejects the credentials fails the send, loudly | wrong password ⇒ `{:error, _}` **and** `messages(server) == []` — the refusal really is at the relay, not a reported failure after acceptance |
| a relay that is not listening is an error | bind a listener, take its port, stop it, then send ⇒ `{:error, _}` |
| a relay hostname that does not resolve is an error | `.invalid` (RFC 2606, can never resolve) ⇒ `{:error, _}` |
| an adapter missing its relay raises rather than reporting a send | `assert_raise ArgumentError` — **as written, not as I expected**, see below |

Every test calls `Courier.Mailers.deliver/2`, the same two lines production runs.
Building a `%Swoosh.Email{}` by hand would prove the adapter works while saying
nothing about whether courier composes a message it can send.

**Mutation check — the tests are not vacuous.** This is the part that makes the
rest of the brief's "very good tests" section meaningful.

| Adapter configured | Result |
|---|---|
| `Swoosh.Adapters.SMTP` (real) | **6/6 pass** |
| `Swoosh.Adapters.Local` | **1/6 pass — 5 fail** |
| `Swoosh.Adapters.Test` | **1/6 pass — 5 fail** |

Both silent adapters fail exactly the tests they should. Neither could ever have
passed these assertions.

**Not exercised, stated plainly.** The round trip runs with `tls: :never`,
because the test server speaks plaintext and does not offer `STARTTLS`. The
*production default* is `tls: :always`, and that default is asserted at the
configuration level (`smtp_adapter()` returns `tls: :always`; a wrong value is a
boot failure). So the TLS upgrade itself — the STARTTLS negotiation and
certificate validation, which is where SMTP credentials are actually exposed on
the wire — is **not** covered by a round trip here. It is configured and asserted;
it is not exercised against a TLS peer. Genuinely verifying it needs a server with
a certificate, which is a larger piece of test infrastructure than this packet
justified. `auth: :never` and `no_mx_lookups: true` are likewise set per-test for
the same reason: the first because a plaintext server, the second because without
it `gen_smtp` makes a real DNS MX query, which a suite should not do.

---

## 3. The credential-leak test

**File: `test/courier/mailer_adapter_credentials_test.exs`, 11 tests.**

Each captures real log output via `ExUnit.CaptureLog` and asserts a sentinel
secret is **absent**. The sentinel is `pw-courier-canary-4e1b-DO-NOT-LOG` (and
`user-courier-canary-4e1b`) — short, in no expected output, present only in this
file.

**What it captured and what it asserted absent:**

1. **The startup line.** `capture_log` around a line built from
   `MailerAdapter.describe/1` with both credentials in the config; asserts the
   password is absent. Paired with a **presence** assertion that host, port and
   `adapter=smtp` *are* present — a `describe/1` that printed nothing would pass
   the refusal and be useless.
2. **The username is absent too.** At SMTP a "username" is very often the API key.
   This is why `describe/1` prints host, port and `auth=on` and nothing else.
3. **A real failed authenticated send.** A real `gen_smtp` server that *rejects*
   the password, the real adapter, the real failure output captured across the
   whole call. Not a stub — the credential is genuinely in the config Swoosh
   hands to `gen_smtp_client`.
4. **A real failed send to an unreachable relay** — the more likely shape in
   practice (DNS or refused connection rather than a provider refusing us).
5. **A successful send**, because a green path is exactly where somebody adds a
   debug-level "sent via `<adapter config>`" line six months from now.
6. **The boot refusals.** A missing-password refusal, and a missing-username
   refusal where password and username *are* set — asserting the message quotes
   the variable that is missing and **not** the values of the ones that are
   present.
7. **No committed config file carries `username:`/`password:`** inside a
   `config :courier, Courier.Mailer` block, and **none names a `relay:`.**

On (7): the scan is scoped to the mailer's own block rather than to every
`password:` in `config/`, because `config/test.exs` and `config/dev.exs`
legitimately commit `password: "postgres"` for the test database. A scan loosened
until it goes green is a scan that has stopped looking. The block extractor is
bracket-balanced so it catches a credential several lines down a multi-line block,
and a companion test asserts the extractor **finds** the mailer blocks in
`test.exs` and `dev.exs` — so "no credential found" means "looked and found none",
not "did not look".

**Mutation check.** I appended a `config :courier, Courier.Mailer, [...]` block
with `relay:`, `username:` and `password: "injected-secret-value"` to
`config/dev.exs`. **Both scans went red and named the offending line.** Removed;
tree clean.

**Verified end-to-end outside the suite.** A real `MIX_ENV=prod` boot with
`COURIER_MAIL_ADAPTER=smtp` and full credentials printed:

```
[info] mailer: adapter=smtp host=smtp.example-provider.test port=587 auth=always
```

No username, no password. The startup line is the real one, from
`config/runtime.exs`.

**One thing worth flagging to whoever picks this up:** Swoosh's
`Swoosh.Adapter.raise_on_missing_config/2` builds its message with
`inspect(config)` — the **entire adapter config**. So a half-configured SMTP
adapter raises an `ArgumentError` containing the password. courier does not log
that path, and `Courier.MailerAdapter`'s refusals fire before it is reachable in
any deployment courier supports. But it is a latent leak inside a dependency, and
a future change that logged adapter exceptions would walk into it.

---

## 4. The measured counts and the floors

Measured with `bin/prime` on this branch, and each tier measured in the same run:

| Tier | Before | Measured now | Floor set |
|---|---|---|---|
| whole suite (`bin/prime`) | 678 | **728** | CI: 678 → **728** |
| no database | 306 (15 files) | **356** (18 files) | CI: 306 → **356** |
| database | 372 (19 files) | **372** (19 files) | unchanged — correct |
| SSRF table | 62 | **62** | unchanged — correct |
| `gate.yml` `minimum` | 672 | — | **672 → 722** |

**50 new tests**, all in files that never touch `Courier.Repo`: 6 round-trip,
33 adapter/refusal, 11 credential. `356 + 372 = 728` exactly — the tiers still
partition the suite with nothing unaccounted for. That is why the database tier
and the SSRF table did not move, and it is the reason rather than a coincidence.

`gate.yml`'s floor uses the repository's established **margin of 6** below the
measured number (630→624, 678→672), so 728 → **722**. A raise, measured, never a
number I did not measure.

**Coverage: 83.4% → 83.6%.** Floor is 80. Note the `(86.3% measured)`
annotation in the CI summary table was **already stale** before this change — I
measured 83.4% at HEAD — and I corrected it to 83.6% since I had just edited the
table above it.

---

## 5. Verified — commands and their actual output

- `mix precommit` (warnings-as-errors compile, `deps.unlock --unused`, format,
  suite) → **728 passed**
- `./bin/prime` → **728 passed**
- `bin/assert-suite … 728` → `728 passed (floor 728)`
- `bin/assert-suite … 722` → `728 passed (floor 722)`
- no-database tier → **356**, database tier → **372**, SSRF → **62**
- `bin/gate-self-test` → **11 passed, 0 failed**, control green, reporting
  `Result: 728 passed`
- `bin/toolchain-pins --check .github/workflows/ci.yml` → agree
- `mix.lock` → **exactly +2 lines** (`gen_smtp` 1.3.0, `ranch` 2.3.0), nothing
  removed
- Four real `MIX_ENV=prod` boots, each refusing or configuring correctly:
  | Environment | Outcome |
  |---|---|
  | adapter unset | raises `COURIER_MAIL_ADAPTER is missing` |
  | `COURIER_MAIL_ADAPTER=none` | raises `none is not permitted in production` |
  | `smtp`, no host | raises `COURIER_SMTP_HOST is missing` |
  | `smtp`, fully configured | startup line printed, no credential in it |

In every refusal the sentinel `REACHED-APPLICATION-CODE` never printed, so the
refusal happens during boot and not after.

---

## 6. Contradictions with the brief

**1. "`swoosh` is not even present" — this is false.** `git log -S swoosh --
mix.exs` points at `382bbe9` (courier-02); `mix.exs` has carried
`{:swoosh, "~> 1.28"}` since, and it is in `mix.lock`. The brief's *conclusion* is
right — nothing shipped that could reach a provider — but the premise is not, and
the difference matters for what had to be fixed.

**2. What was actually missing is `gen_smtp`, and that is a sharper defect than
the brief describes.** `swoosh` declares `gen_smtp` **optional** and
`Swoosh.Adapters.SMTP` declares it **required**. So a courier that "added
`Courier.Mailer` and the `use Swoosh.Mailer` line without the dep" is not the
state — the dep was there. The state is worse in one specific way: naming
`swoosh` alone **compiles cleanly** into a courier whose only shipped adapter is
the silent one. It is a latent `RuntimeError` waiting for the first person to
configure SMTP, not a compile error. That is why the fix is the pair
(`swoosh` + `gen_smtp`) and not one name.

**3. "A raw socket that speaks enough SMTP to accept a message is acceptable."**
There is a third option the brief did not mention: `gen_smtp` ships a **server**
(`gen_smtp_server`, on `ranch`) as well as the client. It is a real, parsing SMTP
server that courier already depends on transitively. I used it. It costs no
dependency, and it catches structurally-broken clients that an
accept-everything socket would not.

**4. "Consider whether a second one earns its place." I decided it does not, and
that is a judgement you may want to overturn.** No second adapter shipped.

* **No new dependency would have been needed** — an HTTP-API adapter
  (Postmark, Resend, SendGrid) uses `Swoosh.ApiClient.Req`, and `req` is already
  declared for the webhook pipeline. It would have been flipping
  `config :swoosh, api_client: false`.
* **It closes zero customer-visible gaps.** The brief's own argument for SMTP is
  the argument against a second adapter: SES, Postmark, Mailgun, SendGrid and
  Resend *all ship an SMTP front*. One adapter reaches all of them.
* **It doubles the credential-handling surface** with a second credential shape to
  keep out of logs and a second config axis to get wrong — against a brief whose
  security constraints are the strictest part of it.
* **I could not have tested it as honestly.** A second adapter would need its own
  real-server round trip or it would ship as a declared-but-unexercised path,
  which is exactly the sin this packet exists to remove.

Adding one later is now a ~15-line change: add the dep, add a branch to
`adapter!/1`, add one round-trip test against a local HTTP listener. That is the
actual deliverable of making the adapter configuration-driven.

**5. Two of my own tests initially passed for the wrong reason, and I fixed them
rather than the assertion.**
* The `describe/1` presence assertion used `Logger.info` while `config/test.exs`
  sets `level: :warning` — so `capture_log` captured nothing and the two *refusal*
  assertions in that file were passing vacuously. Moved to `Logger.warning`.
* The repository-wide credential scan initially failed on `password: "postgres"`.
  Scoping it to the mailer's own block is the fix; loosening the pattern to stop
  matching would have been the wrong one.

**6. One assertion I wrote was wrong about Swoosh's contract.** I expected a
missing `:relay` to return `{:error, _}`. It **raises** `ArgumentError`, because
Swoosh validates `required_config` by raising. The test now asserts that, and the
moduledoc says why — a half-configured adapter is a deployment fault, and
courier's own refusal is what stops it reaching that point at all.

---

## 7. Unverified, stated plainly

* **TLS / STARTTLS is not exercised by a round trip.** Configured and asserted at
  the configuration level; the wire handshake is not covered. See §2.
* **No send against a real external provider.** The server is `gen_smtp`'s own,
  not SES/Postmark/Mailgun. Real providers enforce SPF, DKIM and rate limits, so
  a message this suite delivers could still land in spam. That needs a staging
  deployment, not a test.
* **No DKIM signing.** `Swoosh.Adapters.SMTP` supports `dkim:`; courier does not
  configure it. Not in scope, and it should be a separate decision.
* **The `database` tier floor and the SSRF floor were not raised** — correctly, and
  I verified why (356 + 372 = 728, with no test in a `DataCase` file). I did not
  re-run the tiers in CI itself, only locally with the identical commands.
* **The second boot gate (`verify_boot!/0`) is verified by unit test and by
  reading the source of `Courier.Application`, not by a real prod boot firing
  it.** I could not trigger it end-to-end without hand-editing a config file to
  set the silent adapter, and doing that would have meant committing the very
  defect it prevents. The first gate *is* verified by four real prod boots.

---

## 8. One pre-existing defect found, not introduced, not fixed

`Courier.TelemetryCanaryTest` — *"an id in an unmatched path reaches nothing at
all"* — is **flaky: 1 failure in about 10 full-suite runs.**

I attributed it rather than assuming. With all four of my new files moved out of
the tree and my `lib`/`config`/`mix.exs` changes stashed, at plain HEAD
`717cd5d`, it still failed **1 run in 10**. It is not mine, and it is not the
`deliver_test.exs:128` row-order flake `bin/gate-self-test` already documents —
`bin/gate-self-test`'s own header calls that one out as known and pre-existing;
this is a second one, in a different file.

It matters for this packet in one specific way: **`bin/assert-suite` rejects a
fractional line**, so a red run of that test turns the gate red regardless of any
floor I set. That flakiness pre-exists and is not introduced here, but it is
live on `master` and it will make courier's gate intermittently red for whoever
merges next. The file's own comments describe a related ordering hazard — spans
from an earlier test in the same file being read as this test's, which is why it
filters by name — and that is where I would start looking. I did not fix it: it
is `Courier.TelemetryCanaryTest`, it is the redaction boundary, and it belongs to
whoever owns courier-17 rather than to a packet about SMTP.

---

## 9. Not done, on purpose

* **No HTML-API adapter** (Postmark/Resend/SendGrid) — §6.4.
* **No DKIM signing** — §7.
* **No `mix deps.get` guidance for consumers**, no change to `cafaye.yml`: the
  adapter is deployment configuration, not part of the manifest's contract
  surface, and `core` asserts the manifest and the API document agree. Nothing in
  the HTTP or event contract moved.
* **The coverage floor (80) was not touched.** It did not need to move; the brief's
  ratchet is about test-count floors and I have moved those.