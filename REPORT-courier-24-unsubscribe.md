# courier-24 — one-click unsubscribe, the deliverability gate

## What this packet is

Gmail's and Yahoo's bulk-sender requirements, enforced since June 2024, are about
[RFC 8058](https://www.rfc-editor.org/rfc/rfc8058): a bulk message carries a
`List-Unsubscribe` header whose HTTPS URI a mail client `POST`s to on the
recipient's behalf, with no session, no cookie, no authorization and no
confirmation page. courier had none of it — `grep -rn "unsubscribe" lib/` was
empty — so this is the deliverability gate rather than a feature.

Three things shipped:

| what | where |
| --- | --- |
| the two headers, and the kind that decides whether they are there | `lib/courier/mailers.ex`, `lib/courier/unsubscribes.ex` |
| the door, on two verbs and one opaque token | `lib/courier_web/controllers/unsubscribe_controller.ex`, `lib/courier_web/router.ex` |
| the consequence, and the announcement | `lib/courier/suppression.ex`, `lib/courier/suppressions.ex`, `lib/courier/deliver.ex`, `lib/courier/events.ex` |

`openapi.yaml` is at **2.3.0** — one additive path with two operations, a new tag,
one new path parameter, one new schema, one new reusable response and one new
`errors[].code`. No existing path, verb, request field or response shape changed.

## The three questions the brief asked

### 1. What counts as bulk in courier's model

**A closed table in `Courier.Mailers`, and it is not a caller's to set.**
`Courier.Mailers.kinds/0` maps every notification type courier can send to
`:transactional` or `:bulk`; `Courier.Deliver` calls exactly one function,
`Courier.Unsubscribes.decorate_for/3`, and that is where the conditional lives so it
cannot drift from the table. Not configuration, not a request field, not a provider
attribute.

**All three types are `:transactional` today, and that is a measurement rather than
an omission.** courier's catalog is `welcome`, `password_reset`,
`team_invitation`, and every payload courier publishes carries
`notification_type`. `core/schemas/events/courier/email/*.schema.json` freezes that
field to an enum of exactly those three names, so **a fourth type in
`Courier.Mailers.types/0` would put a value on the bus that four payload schemas
reject** — and `test/courier/events_test.exs` asserts courier's list against that
transcription precisely so the shortcut is visible. Adding courier's first bulk
type is therefore **one row in `kinds/0` plus one enum value in core**, and this
repository does not own the second half. That is the one thing this packet could
not close, and it is reported rather than worked around.

Two decisions inside the table:

- **The default for a type with no row is `:transactional`.** The direction is the
  whole decision. A type nobody classified would otherwise grow an unsubscribe
  link, and an account-management email carrying one is its own defect: a person
  who resets their password and then finds an unsubscribe link has learned the link
  does something they did not expect. Failing towards "no header" is the direction a
  person notices; failing towards "header" is the direction they do not notice until
  they need the mail.
- **The table is a list of pairs, not a map, and the reason is the compiler.**
  Every value in it is `:transactional`, so a map literal infers
  `%{String.t() => :transactional}` and the type checker then correctly reports that
  an arm matching `:bulk` can never run. Right about the literal, wrong about the
  code, and `mix precommit` turns it into a red build. The comment on the table says
  so, because the "simplification" back to a map is invisible in a diff.

The **positive** case is therefore not reachable through `Courier.Deliver` today, and
`test/courier/unsubscribe_headers_test.exs` says so in its own moduledoc rather than
leaving a reader to assume it. What *is* proved is proved where it can be honestly
proved: a real composed message through the real `decorate/2`, and the raw SMTP
`DATA` a real `:gen_smtp_server` received, with the negative asserted on the wire
too so "the header was there" and "no header is" are both measurements.

### 2. The endpoint's auth shape

**The token in the path is the whole of the authorization.** 32 bytes of
`:crypto.strong_rand_bytes/1`, URL-safe base64 with no padding, so 43 characters
and no `+` or `/` for a proxy and a mail client to disagree about.

- **RFC 8058 §3.1 forbids the request from carrying authorization at all** — "The
  POST request MUST NOT include cookies, HTTP authorization, or any other context
  information." A mail client holds no bearer token, so the route is outside `/v1`
  and behind no auth plug. Behind `CourierWeb.Plugs.Principal` every one-click
  unsubscribe in the world would be a 401.
- **The token is stored as a SHA-256 and never as itself.** The plaintext exists in
  exactly two places: the header, and the recipient's mail client. So a database
  dump is not a list of mailboxes anybody can unsubscribe — which is the same
  reasoning identity uses for its opaque tokens and the *opposite* of
  `Courier.SecretBox`'s, because a signing secret has to be read back to sign with
  and an unsubscribe token never does anything but be looked up. The test reads the
  column as raw SQL and asserts the digest does not *contain* the token, not merely
  that it differs.
- **An unknown token is a 404, not a 401.** It is a resource's address rather than a
  credential presented at a door, and one answer covers a token of the wrong shape
  and one that is not a string — so the endpoint is not an oracle that can be used
  to test tokens. `openapi.yaml` declares no 401 for either verb.
- **The token is read from `conn.path_params`, never from `params`.** `Plug.Parsers`
  merges the body into `conn.params`, so a one-click POST whose body carried its own
  `token` could name a different mailbox. The test sends exactly that request, with
  two real tokens, and asserts the path won.
- **The POST never redirects.** §3.1: "The mail sender MUST NOT return an HTTPS
  redirect, since redirected POST actions have historically not worked reliably."
  A redirect is the one thing here that would work for a browser and silently break
  the mail client that matters, so the test asserts the absence of a `Location`.
- **Both verbs, one path**, because §3.2 says the POST target is "the same as the one
  in the GET action for a manual unsubscription". The `GET` returns JSON rather than
  a confirmation page because courier renders no HTML at all — stated as a
  consequence, not sold as a choice.

The URL comes from `CourierWeb.Endpoint.url/0`, i.e. from `PHX_HOST`, which
`config/runtime.exs` already turns into `https://$PHX_HOST`. **No new environment
variable**: a second one could be right for the endpoint and wrong for the header,
and §3.1's "MUST contain one HTTPS URI" is a requirement about the header. The
scheme is asserted by evaluating `config/runtime.exs` as a boot in
`test/courier/unsubscribes_test.exs` — with the variables a boot needs — so the
requirement is measured rather than asserted about a comment.

### 3. The refusal, and where it is recorded

**`email_suppressions`, with `provider: "unsubscribe"` and NO `state`.** The absent
state is the mechanism, not a detail:

- A bounce and a complaint carry a state and refuse **every** type courier sends,
  because they are facts about the MAILBOX. `Courier.Deliver` consults that table
  for a password reset exactly as firmly as for a newsletter. **A stateful
  unsubscribe row would be a person who stops receiving product updates and then
  cannot reset their password.**
- So `Courier.Suppression.unsubscribe_changeset/2` is a separate changeset that
  never casts `state`, `state` became nullable, and
  `Courier.Suppressions.unsubscribed?/2` reads those rows by `(email,
  notification_type)`. `Courier.Deliver` asks it as a step of its own, between the
  preference check and the address check, and answers `{:error, {:unsubscribed,
  type}}` — a 422 with its own `errors[].code`, because a declined preference
  (reversible through a `PUT`) and an unsubscribe (not) are the same status and
  opposite remedies.
- `state/1`'s fold has always had a "rows, none carrying a state" case. The middle
  line of that fold was unreachable while the column was `NOT NULL`, because the
  only state-less writer was a soft bounce and it records no row. **The migration is
  what makes a documented fold true**, and `suppressed?/1` and `find/1` already
  filtered on it.
- The two-value vocabulary is untouched: still an `Ecto.Enum` of two values, no
  database CHECK. The original migration argued against a third "suppressed: true"
  *boolean*, which `nil` is not.

The **observable** half: `courier.notification.suppressed` with
`reason: "preference_off"`, written in the same transaction as the row. That type
has had a builder and no caller since courier-01 and is already declared in
`cafaye.yml` — **no new event type and no manifest change** were needed, and the
manifest's comment now records that it has a caller and that the refused-*send*
case is still open. The payload is core's frozen shape: subject the user id, four
`data` fields, no `message_id`, because no message was rendered.

Idempotency is the unique `(provider, provider_event_id)` index the table already
had, keyed on the token's id — so a second `POST` is a `:duplicate` and the same
200 with the same body, and no second event.

### The alternative, and why it lost

The first draft wrote a `notification_preferences` row (`email_enabled: false`),
which sounds right — it is courier's own per-type answer, it is visible through
`GET /v1/notification_preferences/{user_id}` and reversible through the `PUT` beside
it, and the refusal it produces was already implemented. **It does not work**, and
the reason is a column: `notification_preferences.account_id` is `NOT NULL`, and it
records *which account is entitled to a user's answers*. An unsubscribe has no
principal, so the row would have to carry the account that **sent** the mail — and
that is a tenancy claim made for a user id an authenticated caller chose, because
`POST /v1/messages` does not and cannot check that a user belongs to the caller.
Two accounts could then disagree about who owns a person's settings, and the
account that actually owns them would get a 404 from a route that worked yesterday.

**The cost of the chosen design is the mirror image and is smaller: the answer is
immutable and no route clears it.** A recipient who unsubscribes in error has to be
reached at another address. That only affects a feature that does not exist yet
(courier sends no bulk mail), where the tenancy claim would break one that does.

## The four proofs

| the brief asks for | where |
| --- | --- |
| real HTTP against the real endpoint | `test/courier_web/controllers/unsubscribe_controller_test.exs` — 19 tests through the real router, including RFC 8058 §8.1's own urlencoded POST and a multipart one |
| signature/auth on the endpoint | the same file plus `test/courier_web/router_test.exs`: the token IS the auth, a bad token is a 404, the path wins over the body, and the route is **not** behind `:authenticated` — with the reason quoted from §3.1 |
| header assertions on real message bytes, transactional negative included | `test/courier/unsubscribe_headers_test.exs` — the negative for all three types on a real composed message **and** on the raw SMTP `DATA`; the positive on the raw `DATA` too, with the token in the URI resolved back to its row |
| idempotent double POST, and the refusal after | the controller test (byte-identical second body, one row, one event, no `Location`) and `test/courier/deliver_test.exs` + `unsubscribes_test.exs` (the type is refused with its own code; a different type still goes out) |

Plus the rollback proven by breaking it: a token whose address the changeset now
refuses, asserted to have published **no event**.

## Deliberately not done

- **DKIM. RFC 8058 §4 requires a valid DKIM signature covering
  `List-Unsubscribe` and `List-Unsubscribe-Post` and listed in the `h=` tag, and
  §3.2 says a receiver that finds none "SHOULD NOT offer a one-click unsubscribe
  for that message".** courier submits through `Swoosh.Adapters.SMTP` to a relay
  and holds no private key for the sending domain, so signing is the relay's — the
  same place SPF, DMARC and everything else about the domain lives. The
  consequence is operational and is stated in the module: **if the relay does not
  sign, the header is on the wire and the mail client ignores it.**
- **ESP-side handling of `List-Unsubscribe`.** Nothing here forwards the header to
  a provider, strips it, or asks a provider to honour it. courier composes, hands
  the message to the adapter, and the bytes on the wire are the whole contract.
- **Retry or backoff on the provider for an unsubscribe.** The endpoint has no
  provider to retry: it writes two rows in one transaction, and the 503 it answers
  when it cannot is the whole of the failure story. The same applies to the
  backoff machinery courier has for webhooks, which exists because a customer's
  endpoint can be down for days — a local `INSERT` either lands or does not.
- **A route that clears an unsubscribe.** The rows are immutable as every row in
  that table is, and a `DELETE` on an immutable table is a decision about what
  "immutable" means. It belongs with the first bulk type, in a packet whose
  subject is the remedy.
- **A fourth, bulk notification type**, for the core-side reason above. Inventing
  one would put a value on the bus that four frozen payload schemas reject, and
  `test/courier/events_test.exs` exists to make that visible.
- **A `COURIER_PUBLIC_URL`.** One setting already says what courier's public URL is.
- **Rate limiting on the endpoint.** A 2^256 token is the control; a limiter is a
  later packet, and `429` is on the list of statuses courier cannot send.
- **An expiry on the token.** A `List-Unsubscribe` header is read for as long as
  somebody keeps the message, and an endpoint that answers 404 for a mail read
  eight months later is a broken deliverability promise.

## Two things the repository's own gates caught, and said so

- **`test/courier_web/openapi_document_test.exs` and
  `test/courier/backup_tables_test.exs` went red the moment the route and the
  migration existed**, which is the mechanism working: the route the router serves
  and the document does not describe, and a table in the database with no entry in
  the list of tables a dump carries. Both were fixed in the same commit rather than
  by adding a carve-out.
- **`test/courier_web/openapi_error_responses_test.exs` provoked every status the new
  route can send against the document, in both directions**, and required a `400`
  on the `POST` and *not* on the `GET` — a distinction the code gets for free from
  `Plug.Parsers` ignoring bodies on other verbs and which the document would
  otherwise have had to guess.
- **`cafaye-contract lint` reports `openapi.paths-are-versioned` and
  `openapi.idempotency-key` for the two new operations**, which it already reported
  for `POST /inbound/resend` at `2.2.0`. Same two rules, same two grounds: the
  harness cannot know that a mail client is not a tenant, or that RFC 8058 §3.1
  forbids a mail client from sending a header. That is recorded in the document's
  own header, and the two rules are worth the violation rather than a compromise.

## The numbers

| | before | after |
| --- | --- | --- |
| whole suite (`bin/prime`) | 1218 | **1282** (floor 1212 → 1276) |
| no-database tier | 623 (28 files) | **619** (27 files) |
| database tier | 595 (29 files) | **663** (33 files) |
| SSRF table | 62 | 62 |

**The no-database tier went DOWN, and the reason is the packet rather than a
regression.** `test/courier/telemetry_canary_test.exs` — the redaction boundary's
proof — became a `Courier.DataCase`, because every request it drove was refused
before it reached a controller that touches a database and the one-click
unsubscribe's 404 is the first that does not. A canary could have been planted on a
request the `:accepts` plug refuses and the file would have stayed in the tier — and
the tier's own claim, "these tests never touch `Courier.Repo`", would have quietly
become false. **A floor is a decrease detector; a tier is a statement about what the
tests do**, and a statement that holds only because a request was answered early is
a lie with a number on it. 1282 is 619 + 663, which is the consistency check worth
making.

## The flake: attributed, reproduced, and named

**The brief says `Courier.TelemetryCanaryTest` has a known flake recorded in
[`REPORT-courier-15-flaky.md`](REPORT-courier-15-flaky.md), and that is not what
that report says.** It documents six tests that counted whole tables (fixed, 6/6
deterministically reproduced), it names `deliver_test.exs:115` as the only
sporadic failure it ever saw (**2 in 50 whole-suite runs**), and it flags the
remaining whole-table counts as unfixed in §9. It never mentions the canary file.
So the flake the brief attributes to the canary file is real but **recorded
elsewhere or not at all**; below is what I measured on this tree, so the record
is this packet's and not an inherited claim.

**It reproduced, once, in 8 whole-suite `bin/prime` runs:**

```
1) test a request PATH never reaches a span an id in an unmatched path reaches
   nothing at all (Courier.TelemetryCanaryTest)
   a 404 produced a span with a route. ...
```

**The mechanism is the one that file's own moduledoc and comments already
describe**, and it is not this packet's code:

- `request_spans/0` reads **every** `courier.web.request` span in a shared ETS
  table, filtered only by name. The failing assertion is
  "this 404 produced a span with a `http.route`", but the loop is over the whole
  table, so a `courier.web.request` span from a **concurrently finishing
  `async: true` test in another file** is read as this test's.
- The `setup` `clear/1` narrows the window and the name filter narrows it
  further, and neither closes it. The comment on `request_spans/0` says as much:
  "it failed against a span the 'parameterised route' test above had exported,
  because both are `courier.web.request` and the filter cannot tell them apart."
  That is a *within-file* collision. The one I hit is the *cross-file* version,
  and the file has no defence against it because it cannot have one — the table
  is shared by the whole VM.

**Isolated, it is stable**: 12/12 runs of `mix test
test/courier/telemetry_canary_test.exs` green, including the canary this packet
adds. Whole-suite, 1 failure in 8 runs on this tree.

**Not chased, and the two things I could have done about it, and why I did
neither:**

  - **Filter the assertion to this test's own span.** The robust fix is to read
    spans by trace id, or to give each test a distinguishing path and filter on
    it. That is a change to a test this packet did not write, about a race the
    brief told me to attribute rather than chase — and a narrower `request_spans/0`
    would weaken the presence assertion that every other test in the file leans
    on, which is the "a check over nothing passes" failure the file's own moduledoc
    is built against.
  - **Take the new canary out of that file.** It would have kept my packet from
    adding a request to a racy file, at the cost of the token not being proved not
    to reach a span — and the token is the sharpest value in this service after a
    signing secret. The right home for that proof is the file that owns the
    redaction boundary, and the flake is not a reason to move a test somewhere it
    does not belong.

**What this packet did do about the one thing it *did* change**, and the honest
cost: this packet **added a test to that file** and **moved it from the
no-database tier to the database tier**, both of which change the timing around
the shared span table. It does not make the race reachable that was not already
reachable — the failing assertion predates this packet and runs against spans this
packet's tests do not produce — but a reader counting runs should know the file has
one more request in it than it did. That is stated here rather than discovered by
whoever hits it next.

And the file the courier-15 report *does* name, `deliver_test.exs`, is a file this
packet also touches: it gains four tests and a `sends/0` helper. The helper exists
because the one-click unsubscribe in the setup block announces itself, so
`outbox/0` is not empty and "no send was recorded" is not "the outbox is empty" —
asserting the second would be asserting something false, and clearing the table to
make it true would be asserting something else. `sends/0` has no `order_by` and
every assertion on it is a single-row match, which is the row-order dependence §4
of that report describes.

## What a reader should check first

1. `Courier.Unsubscribes`'s moduledoc table of RFC 8058 sections against
   §3.1, §3.2, §4, §5, §6 and §8.1. Every claim courier makes about the spec is
   quoted rather than paraphrased, so it can be checked against the RFC.
2. `Courier.Mailers`' comment on `@kinds`, and
   `test/courier/unsubscribe_headers_test.exs`'s "the honest limit" section — those
   two together say exactly which half of the gate is proved and which half is
   waiting on core.
3. The migration's moduledoc in
   `priv/repo/migrations/20261002090000_create_unsubscribe_tokens.exs`, because it
   is the one change here that touches a table three shipped packets built and it
   argues the `state` nullability at length.
