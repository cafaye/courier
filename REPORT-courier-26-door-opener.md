# courier-26 — courier's door has no key, and the key already exists

`worker/courier-26-door-opener`. **1218 tests, `bin/prime` green, 62 added.** Two
findings in here are more important than the code that came out of them, and one
of them means this packet does not fully unlock the door in a deployed courier.
Both are written down rather than fixed, because fixing them is not courier's to
do.

---

## What landed

`Courier.Principal.Introspection` is what `config :courier, :principal` names
outside test. It reads the caller's token from `Authorization: Bearer`, asks
identity `POST /v1/introspections` about it, and turns the answer into one of
three things:

| identity says | courier says | caller sees |
| --- | --- | --- |
| `200` active, with a parseable `account_id` | `{:ok, principal}` | the route, scoped to that account |
| `200 {"active": false}` | `:error` | `401` `unauthorized` |
| `200` active with no `account_id` | `:error` | `401` |
| `200` courier cannot read | `{:error, :unavailable}` | `503` `unavailable` |
| `401`, `403`, `404`, `422`, `5xx` | `{:error, :unavailable}` | `503` `unavailable` |
| unreachable, refused, timed out | `{:error, :unavailable}` | `503` `unavailable` |
| no bearer on the request | `:error`, **without dialling** | `401` |

The plug gained exactly one clause (`{:error, :unavailable}` → 503). Its 401 is
untouched, and that is a test rather than a promise: the same request through both
resolvers produces the same envelope field for field.

Every `/v1` operation now declares the 503 in `openapi.yaml`, and
`test/courier_web/plugs/principal_config_test.exs` holds that to the router in
both directions.

## The four judgement calls

**1. What courier presents.** `COURIER_IDENTITY_TOKEN` — courier's own scoped API
token, from the environment, never in argv and never in a committed file, never
logged, never part of a reason string. Required in prod and refused at boot on
the same rule as `COURIER_SECRET_BOX_KEY`. Rotation is identity's: mint, redeploy,
revoke — and there is no cache to invalidate, because a cached introspection
answer is an `account_id` grant that survives the operator revoking the
credential.

**2. What courier does with the answer.** `active: false` → 401 through the
existing `CourierWeb.Problem` shape, unchanged. `active: true` → assign
`current_account` from `account_id`.

**3. Scopes: parsed, and deliberately not enforced.** Both claim names are read
(`scopes` and `scope`, byte-identical from identity because MD7 is open), the
union is carried on `Courier.Principal.scopes`, and **nothing enforces it**. The
reason is measured, not a shrug: identity's scope vocabulary is a closed set of
six, and **not one of the five scopes `openapi.yaml` declares** — `webhooks:read`,
`webhooks:write`, `notifications:read`, `notifications:write`, `messages:write` —
can be minted by it. A scope check written today would refuse every credential
identity is able to issue. `openapi.yaml`'s `bearerAuth` says all of this where a
client author reads it, and it lost its `bearerFormat: JWT`, which was simply
wrong: courier never parses a JWT.

**4. Failure is a closed door.** 503, never "allow". And identity's own **401 and
403 are courier's problem, not the caller's** — identity answers 401 when the
credential *courier* presented is not one it accepts, and 403 when that credential
may not ask about the token it named. Reporting either as a 401 tells a customer
to rotate a token that was never the problem, and an operator reads a wall of
"invalid credentials" when the fault is one environment variable.

---

## Finding 1 — identity's contract has no credential a service can use

**This is the one that stops the packet from fully landing, and I did not fix it
because identity is not mine to edit.**

`identity/internal/httpapi/apikeys.go:500`, `mayIntrospect`, reads:

```go
// A token caller: itself, and only itself.
if claims.TokenID != caller.Key.ID.String() {
    problemFor(w, r, http.StatusForbidden, CodeForbidden,
        "an api key may only introspect itself")
    return false
}
```

and the session branch requires `role.AtLeast(accounts.RoleOwner)` in the token's
own account. So the two credentials `bearerToken`/`sessionCookie` accept resolve
to exactly two caller kinds — a **scoped API token**, which may read only itself,
and a **session**, which may read a token in an account it **owns**. There is no
service credential and no scope that permits it.

RFC 7662 §2.1 permits a resource server to introspect using the presented token
itself, and identity implements that affordance — so the option that needs **no
second secret at all** exists. It covers only the token identity is holding,
which makes it a door shut for every real tenant and open for exactly the one
account that owns courier's own service token. courier does not do it.

**What a deployed courier does today, with the packet as shipped:**

  * a caller whose token identity answers `{"active": false}` for → **401** (this
    is the dead-token path, and it works);
  * a caller whose token is **live** → identity resolves it, then the standing
    check runs and answers **403** → courier answers **503**.

So an invalid token gets a 401 and a *valid* one gets a 503. That is the correct
fail-closed direction and it is deliberately not disguised — but it means **in
production the door is still shut, loudly**, and the operator's dashboard shows
503s with courier's own log line naming identity's 403. The alternative —
mapping a 403 onto a 401 — would have made this packet look finished and would
have been a lie told to a customer about their own credential.

**What would close it** (identity's packet, not this one): a caller kind that is
a service, with a scope that permits reading an arbitrary token. The smallest
version is one more branch in `mayIntrospect`:

```go
// A service caller: any token, because a resource server has to be able to ask
// about somebody else's credential.
if caller.IsService {
    return true
}
```

which needs a way to *be* a service. The existing `(account_id, :accounts:read)`
pair already couples a token to one account, so a service caller should not be one
— it wants to be a credential with no account of its own, which is precisely the
case identity's own `account_id`-is-required rule currently answers
`{"active": false}`. **So the two rules are in tension**: "a token with no account
is unusable" is right for a tenant token and wrong for a service one.

I did not touch identity. If identity wants the scope vocabulary to grow
anyway, `AllScopes/0` gains one name and `COURIER_IDENTITY_TOKEN` is minted with
it — courier's code does not change, because a scope it does not enforce is
already parsed and carried.

## Finding 2 — core's conventions forbid what courier now does on the hot path

`core/docs/openapi-conventions.md:132`: *"Services verify locally against the JWKS
URL … **no per-request call to identity on the hot path**."* That rule is written
for the OIDC **JWT** access token, which courier cannot use today: verifying one
needs a JWS library courier does not have, and **adding one needs approval**
(`AGENTS.md`: "No dependency without approval"). The alternative that needs no new
dependency is the introspection endpoint, which is what this packet uses.

So the choice was: a documented fleet rule that needs a dependency nobody has
approved, against the only authentication courier can implement with what it
already ships. I took introspection, stated the cost in three places (module
doc, README, `openapi.yaml` header), and did not pretend the rule does not say
what it says. **It is a decision for the fleet, not for courier**: either core
amends the rule for opaque first-party tokens, or courier grows a JWS dependency
and verifies locally with a bounded `kid` cache.

Also worth recording, because it shaped the same choice: courier's
`openapi.yaml` declared `bearerFormat: JWT` and "the token carries `account_id`
for tenancy and `scopes` for capability; **courier checks both**". That was a
contract courier was not keeping — it checked neither, because there was no
verifier. Both halves are corrected in this commit rather than left as a
description of something that does not happen.

---

## Smaller things found and not fixed

- **`identity`'s own OpenAPI example carries a `sub` that is not a uuid.**
  `identity/openapi/v1.yaml:2467` writes `sub: ab000000-0000-0000-0000-0000000000u1`
  and `u` is not a hex digit, so the string is not a uuid any implementation could
  cast. It cost this packet a fixture that read as `nil` for a reason that had
  nothing to do with courier. Worth correcting in identity for the same reason
  every payload in `resend_test.exs` is copied from a named page: a documentation
  example that cannot be true is one a reader copies.
- **`identity` has no `/oidc/introspect`.** Its `openid.yaml` lists it among the
  routes deliberately not built. Not courier's problem today (courier does not
  verify JWTs) and noted only because it is the obvious place someone will look
  next.
- **`test/courier/error_relay_test.exs` is flaky, and it is not this packet's.**
  `:sys.get_state/1` times out on the 10 000-message test under load. It was first
  recorded in `878f559` ("3 of 16 seeds on master, 1 of 16 here") and left there
  deliberately: fixing it here would mean loosening an assertion in tests this
  packet did not touch. I re-measured it rather than assuming, stashing the whole
  packet and running the **base tree** six times:

  | tree | runs | green |
  | --- | --- | --- |
  | base (`a8f15cc` + `878f559`) | 6 | **2** |
  | courier-26 | 7 | **5** |

  The base tree failed the same test four times out of six on an unloaded
  machine, which is the measurement that settles the attribution: the flake is
  load-dependent, pre-existing, and roughly as frequent without this packet as
  with it. Every gate run recorded below is a green one, and each was preceded by
  a red one that was this test and nothing else.

---

## Two bugs the tests caught in this packet's own code

Worth listing because they are both the shape of mistake this repository's rules
are about:

  * `Document.claim/2`'s first draft matched a bare `_absent` where it needed
    `:error`, which matches everything after it — so a `["accounts:read"]` array
    read as "no scopes", which is the exact silent failure the clause order
    exists to prevent. The rule now says so at the line.
  * `Transport.Req` relied on `Req`'s JSON decoder and then called
    `to_string/1` on the result, which raises `String.Chars` on a map. Fixed with
    `decode_body: false`, and the fix is the better boundary anyway: courier makes
    one decoding decision, in `Document`, where the rules about an unreadable
    answer are written down.

## The numbers

| | before | after |
| --- | --- | --- |
| whole suite | 1156 | **1218** (+62) |
| no-database tier | 577 / 25 files | **623** / 28 files (+46) |
| database tier | 579 / 28 files | **595** / 29 files (+16) |
| `gate.yml` floor | 1150 | **1212** |
| CI floors | 1150 / 577 / 579 | **1212 / 623 / 595** |

1218 is 623 + 595, which is the consistency check the CI tiers exist to make. The
split is the design, not an accident: **authentication touches no `Courier.Repo`
and has to be checkable on a runner with no database at all**, so 46 of the 62 are
in the no-database tier. The other 16 are a `ConnCase` because their subject is
the *responses* — the 401, the 503, the halt, and the document's declaration —
and a status asserted on the plug rather than over a real request is a status no
client ever receives.

## What a reviewer should check first

1. That a **503** for "identity cannot be reached", rather than a 401, is the call
   you want made. It is the packet's instruction and I believe it is right, but it
   is the decision with the most blast radius on courier's clients.
2. That requiring `COURIER_IDENTITY_TOKEN` **at boot** is better than letting
   courier start and answer 503. I took boot because the same rule is already
   applied to `COURIER_SECRET_BOX_KEY` and `COURIER_INBOUND_RESEND_SECRET`, and
   because a deployment that means to run courier and has not set it is silently
   unable to serve anyone.
3. **Finding 1**, which is the honest answer to "did this unlock the door": the
   resolver is correct against identity's contract, and identity's contract does
   not yet let a service authenticate an arbitrary tenant. Nothing in courier can
   fix that.