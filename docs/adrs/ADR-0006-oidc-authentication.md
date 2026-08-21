---
status: proposed
date: 2026-08-21
decision-makers: [joestump]
extends: [ADR-0004]
governs: [SPEC-0003]
---

# ADR-0006: Native OIDC authentication against Pocket ID, in the Phoenix server

> **Renumbered and rewritten (2026-08-21).** This ADR was originally filed as a second ADR-0004, colliding with the Elixir full-stack base ADR of that number, and it reasoned throughout from the Gren stack that ADR-0004 superseded. It is now ADR-0006 and extends ADR-0004. The **decision** it recorded — a native OIDC confidential client rather than the shared oauth2-proxy — survives intact. Its **implementation reasoning** did not, and the reversals are recorded explicitly below rather than quietly deleted, so a later reader can tell a considered change from an accident.

## Context and Problem Statement

binnacle is deployed at `https://binnacle.stump.rocks` on ie02 and has no authentication: no redirect, no forward auth, no session. That name is a CNAME to `ie02.stump.rocks` → `192.168.100.213`, an RFC1918 address, so the console is **unauthenticated and LAN-only** rather than open to the internet. The DNS record is the entire boundary.

StumpCloud has exactly one identity provider — Pocket ID v2 at `identity.stump.rocks`, passkey-only — and `stumpcloud/ansible` ADR-0018 sanctions two ways to use it: delegate to the shared oauth2-proxy at `auth.stump.rocks` via Caddy `forward_auth`, or register a native OIDC client. How does binnacle authenticate its users on the Elixir/Phoenix base that ADR-0004 established?

The question the original ADR asked — *given that the Gren ecosystem ships no cryptography, how is this implementable at all?* — is gone. On the BEAM, `:crypto` is in OTP, `Plug.Crypto` is already a transitive dependency, and the JOSE ecosystem is mature. Nothing about OIDC is hard to implement here. What remains is choosing correctly.

## Decision Drivers

* **Control actions need per-user attribution** — an audit line naming the human who restarted a container. A yes/no gate at the proxy cannot supply one.
  * **Honest state of that driver: no control actions exist yet.** `server/lib/binnacle_web/router.ex` today defines two LiveView routes, four `GET` API routes, `GET /healthz`, and a `match :*` catch-all that answers `405`. There is **not one mutating route in the application**. The attribution driver is therefore *anticipatory*: it is the reason to build the identity-bearing shape now rather than the proxy shape, but it is not a problem binnacle has today. The driver that is live today is narrower — the console discloses the fleet's topology to anything on the LAN.
* ADR-0018's own guidance: native OIDC is preferred where a service can support it; oauth2-proxy is the fallback for services that cannot. binnacle is first-party code, so "cannot" would be a choice.
* One identity provider, one login ritual. Passkeys mean binnacle never sees, stores, or resets a password.
* The identity must be usable as **data** — a value a LiveView can render and a future authorization rule can read — not merely as a verdict that a request passed a gate.
* Credentials live in OpenBao and clients are provisioned by `joestump.pocket_id`, not registered by hand in a UI.
* **The application is LiveView.** Authentication that only runs in a router pipeline is authentication that does not run on a websocket reconnect. Any design here has to survive that, and it is the constraint most likely to be got wrong.

## Considered Options

* **A. Native OIDC confidential client in the Phoenix server** — authorization code flow with PKCE, server-side session, identity in `conn.assigns` and `socket.assigns`
* **B. Shared oauth2-proxy forward auth** — `oauth2_proxy.enabled: true` in dub.yaml, identity arrives as `X-Auth-Request-*` headers
* **C. Public client in the browser** — client-side code flow with PKCE, tokens held in browser storage
* **D. No authentication; restrict at the network layer** — keep the LAN-only boundary and add nothing

## Decision Outcome

Chosen option: **A — a native OIDC confidential client in the Phoenix server**, because binnacle needs the authenticated identity as data it can act on rather than a gate it passed; because ADR-0018 names native OIDC the preferred pattern for services that can support it; and because on the Elixir base there is no longer any implementation cost that would argue otherwise.

The substance of the decision is the sub-decisions below. Each one that reverses the Gren draft says why the old position existed.

### 1. Confidential client, authorization code flow with PKCE. No token reaches the browser.

The server holds the `client_secret`, exchanges the code server-to-server, and hands the browser only a session cookie. Implicit and hybrid flows MUST NOT be used.

Three parameters are pinned against what Pocket ID advertises, because in each case the provider offers a weaker option that must not be negotiated into:

* **`response_type=code`.** Pocket ID's `response_types_supported` is `["code", "id_token"]`; `id_token` would deliver a token through the browser.
* **PKCE with `S256`, and `plain` MUST be rejected.** `code_challenge_methods_supported` is `["plain", "S256"]`, and `plain` is no protection at all. PKCE is not strictly required of a confidential client, but it costs nothing and closes code-injection independently of the secret. Note that `joestump.pocket_id.oidc_client` defaults `pkce_enabled: false`, so the Ansible side must set it `true` explicitly — `playbooks/services/beszel.yaml` is the pattern.
* **`response_mode=query`, not `form_post`.** This is not a style preference. `form_post` returns the authorization response as a **cross-site POST** from `identity.stump.rocks` to binnacle; with `SameSite=Lax` the cookie carrying `state`, `nonce`, and the PKCE verifier is not sent on that request, so the callback cannot correlate it — and `protect_from_forgery` on the `:browser` pipeline would reject the POST as forgery before that even mattered.

Client authentication to the token endpoint is pinned to `client_secret_basic`. Pocket ID's `token_endpoint_auth_methods_supported` includes `none`, which must never be negotiated.

### 2. The OIDC client library is `oidcc` + `oidcc_plug`. The flow is not hand-rolled.

**Chosen: `oidcc` 3.8.0 with `oidcc_plug` 0.5.1** (Apache-2.0). It is the only **OpenID-Certified** relying party in the ecosystem — certified by the Erlang Ecosystem Foundation — and the only option that handles **JWKS key rotation** correctly: `Oidcc.ProviderConfiguration.Worker` caches the discovery document and JWKS in ETS and installs `refresh_jwks_for_unknown_kid` by default. Pocket ID publishes a single RS256 key today; when that key rotates, this is the difference between logins continuing and logins breaking at 3am with no deploy having happened.

The dependency delta is small. `plug`, `plug_crypto`, and `telemetry` are already in `server/mix.lock`; the genuinely new dependencies are `jose` and `telemetry_registry`. No new HTTP client — `req` stays for the fleet pollers.

Two build-time constraints that belong in the decision rather than in a code comment:

* **`backoff_type: :exponential` on the provider-configuration worker.** The default is `:stop`, which gives up **permanently** if Pocket ID is unreachable at boot. For a fleet monitor whose entire job is being up while other things are down, a boot-order dependency that fails closed forever is the wrong failure mode.
* **Pin `oidcc_plug ~> 0.5.1`.** Version 0.5.0 is retired on hex.

**Runner-up: `assent` 0.3.1.** Genuinely good — zero-dependency, correct ID-token validation. It lost on four things: no caching at all, so discovery and JWKS are refetched on every login; PKCE off by default; no RP-initiated logout; and a refresh path that falls back to a hardcoded `/oauth/token` instead of consulting discovery — which against Pocket ID points at nothing, since its token endpoint is `/api/oidc/token`.

**Explicitly rejected: `openid_connect` (DockYard).** Despite 807k downloads and a January 2026 release, its validation is materially incomplete: no `iss` check, no `nonce` check, no `azp`, no `iat`, and **no `kid` matching** — it tries every key in the JWKS and accepts the token if any of them verifies. It is recorded here by name because it is the popular-but-unsafe option someone will otherwise reach for.

### 3. ID-token signature validation is REQUIRED. The §3.1.3.7 exemption is deleted.

**Why the exemption existed:** the Gren draft invoked OIDC Core 1.0 §3.1.3.7 item 6, which permits a client receiving the ID token by direct communication with the token endpoint to substitute TLS server validation for signature verification. That clause is real and the draft's use of it was defensible — but the *reason* it was invoked was that the Gren ecosystem shipped no cryptography at all, so RS256 and JWKS could not be put on the critical path. It was a workaround wearing a specification citation.

That constraint is gone, and carrying the exemption onto Phoenix would be a real weakness rather than an obsolete one: it makes the TLS chain to `identity.stump.rocks` the token's sole integrity guarantee, forever, for a check that `oidcc` performs by default.

Therefore:

* The ID token's signature SHALL be verified against a key from the issuer's JWKS.
* **`RS256` is the pinned allowlist**, matching Pocket ID's `id_token_signing_alg_values_supported`.
* **`alg: none` and every HMAC algorithm MUST be rejected before any key lookup occurs** — not matched against a key and found wanting. An HMAC algorithm reaching key selection is the classic confusion attack in which the RSA public key is used as an HMAC secret.
* Key selection SHALL match on **`kid`**. Trying every key and accepting any that verifies is precisely the `openid_connect` defect rejected above.
* JWKS SHALL be cached with a bounded lifetime and re-fetched on an unknown `kid`, with the re-fetch itself rate-limited so an attacker cannot drive unbounded requests at the IdP.
* `iss`, `aud`, `exp`, `iat`, and `nonce` are all still checked, and TLS verification MUST NOT be disabled by configuration, environment variable, or build flag.

### 4. Cryptography comes from OTP. There is no task port.

`:crypto.strong_rand_bytes/1` for every random value, `Plug.Crypto.secure_compare/2` for every comparison that decides authentication, and JOSE (via `oidcc`) for signature verification.

**Why the port existed:** Gren had no CSPRNG and no hashing, so a two-function task port to Node's `crypto` was the only way to obtain `randomBytes` and `sha256`. The port's narrowness was a virtue given the constraint, but the constraint is gone and the port would now be a hole in the runtime for no benefit. `gren-lang/core`'s seeded `Random` remains a cautionary note only: the equivalent mistake here is `:rand`, which MUST NOT be used for `state`, `nonce`, or the PKCE verifier.

### 5. Sessions are Phoenix `Plug.Session` cookies. This trades revocation for simplicity, and the trade is recorded.

`BinnacleWeb.Endpoint` already configures `Plug.Session` with `store: :cookie`. That store stays, hardened. There is **no bespoke opaque-identifier session store** and no ETS-backed session table.

**Why the opaque-identifier store existed:** Gren could not sign or encrypt a cookie, so a self-contained cookie was impossible and an opaque random identifier pointing at server-held state was the only shape available. Its server-side revocation was a *consequence* of that constraint, not the reason for it — but it is a genuine property, and dropping it is a real loss that must not be smuggled through.

**What is lost: a cookie session cannot be revoked before it expires.** `POST /auth/logout` clears the cookie in the browser, and that is the whole of it. A cookie value captured before logout and replayed afterwards remains cryptographically valid until its `max_age` elapses. Nothing in this design changes that; the mitigations bound the window instead of closing it:

* **An `exp` claim inside the session payload, checked on every request and every mount** — including every LiveView reconnect. The cookie's own `max_age` is enforced by the browser and by `Plug.Session`, but the application must not depend on the client to enforce expiry, so the expiry is also carried in the signed payload and checked server-side. **Session lifetime is capped at 1 hour.**

  The cap is short precisely *because* it is the only real bound. In a design with server-side revocation, session length is a convenience question — a long session is fine because it can always be cut. Here it is the entire security boundary: it is simultaneously the window in which a stolen cookie works, the window in which a logged-out cookie still works, and the window in which a disabled Pocket ID account still reaches binnacle. Twelve hours was drafted as a working-day convenience; that reasoning belongs to a design that could revoke. One hour is the deliberate trade for not building a session store.
* **`live_socket_id` plus `Endpoint.broadcast/3`** to disconnect live sockets on logout. This is the one revocation-shaped tool the cookie store does offer: it terminates the user's connected LiveView sessions immediately. It does not invalidate the cookie — a fresh HTTP request with a replayed cookie still authenticates until `exp` — and the ADR is explicit that it is a disconnect, not a revocation.
* **`encryption_salt`** as well as `signing_salt`, so the payload is encrypted rather than merely signed. The session carries claims, not an opaque identifier, and a signed-only cookie is readable by anyone holding it.
* **`max_age`** matching the 1-hour cap, plus **`secure: true`** — which is **missing today** — `http_only: true`, `same_site: "Lax"`, `Path=/`, and no `:domain`, so the cookie stays host-scoped rather than shared across `.stump.rocks`.
* **`signing_salt` and `encryption_salt` come from configuration**, not from the hardcoded literal presently in `endpoint.ex`.

If a hard revocation requirement ever appears — a shared workstation, a lost device, a per-user authorization model where demotion must take effect immediately — this is the decision to revisit, and the revisit is a server-side session store. It is deliberately not being built ahead of that need.

### 6. `live_session` + `on_mount` is mandatory, in addition to the router plug.

This is the single most important implementation constraint in this ADR, and it is a trap rather than a preference.

**A router pipeline does not run on the LiveView websocket.** `pipe_through :browser` runs for the initial dead HTTP render and then never again. When the socket connects — and on every reconnect after a deploy, a network blip, or a laptop waking from sleep — LiveView re-runs `mount/3` with only what was captured in `connect_info[:session]`, and no plug is involved. A `RequireAuth` plug alone therefore leaves every LiveView reachable over the socket by anyone holding a cookie the plug would have rejected, for as long as the socket keeps reconnecting.

Authentication is therefore enforced in **two** places that must agree:

1. `BinnacleWeb.Plugs.RequireAuth` in the router pipeline — for the dead render and all controller routes.
2. `on_mount {BinnacleWeb.Auth, :require_authenticated}` attached to a **`live_session`** — for the connected mount and every reconnect.

`live_session` is not decoration around `on_mount`: it is what makes the session data available to the hook, and what forces a **full page reload** rather than a live navigation when crossing an auth boundary, so an expired session cannot be live-patched around.

### 7. The kickoff and callback routes are plain controller routes, outside every `live_session`.

`GET /auth/login` and `GET /auth/callback` are actions on a plain `BinnacleWeb.AuthController` on a dedicated `:auth` pipeline.

The reason is mechanical: **a LiveView process cannot set a cookie.** By the time a LiveView is mounted over the websocket, the HTTP response is long since sent; `Plug.Conn` is not in play. Since `state`, `nonce`, and the PKCE verifier are persisted in the session cookie (sub-decision 5), the endpoint that generates them must be a controller action. The callback likewise must write the authenticated session into a cookie, which again requires a `conn`.

These two routes are the only routes that may sit outside a `live_session`, along with `GET /healthz` and `Plug.Static`.

### 8. Identity comes from the validated ID token alone. There is no userinfo call.

Pocket ID places `groups` in the **ID token** when the `groups` scope is requested, so a userinfo round-trip buys nothing. `sub`, `email`, `name`, `preferred_username`, `picture`, and `groups` all arrive in one hop, already signature-verified.

`Binnacle.Auth.Identity` is an Elixir struct defined once and assigned to both `conn.assigns.current_identity` and `socket.assigns.current_identity`. Its fields are **bounded by Pocket ID's `claims_supported`** — `sub`, `given_name`, `family_name`, `name`, `display_name`, `email`, `email_verified`, `preferred_username`, `picture`, `groups`, `auth_time`, `amr` — so the struct cannot drift into inventing fields the provider never sends.

It MUST NOT carry any token or provider credential. Socket assigns are serialized into the LiveView's process state, and anything in them is one `inspect/1` away from a log line.

`groups` is captured because it is free and because a future authorization ADR will want it. It grants nothing today.

### 9. Logout is RP-initiated. The IdP cannot push a logout to binnacle.

`POST /auth/logout` clears the local session, broadcasts on `live_socket_id` to disconnect live sockets, and redirects to Pocket ID's `end_session_endpoint` (`https://identity.stump.rocks/api/oidc/end-session`) with the ID token as `id_token_hint`, so the user is signed out at the provider too rather than being silently re-admitted on the next login attempt.

Pocket ID's discovery document advertises **neither `frontchannel_logout_supported` nor `backchannel_logout_supported`**. There is therefore no mechanism by which a sign-out at the IdP, or an account disable, propagates into binnacle. Combined with sub-decision 5, this means a binnacle session outlives an IdP sign-out for up to its remaining lifetime. **A disabled account keeps working in binnacle until its session expires**, and nothing binnacle can build changes that while the IdP cannot push. That is the concrete reason the cap is one hour and is a cap rather than a starting point for negotiation.

Logout MUST be `POST`-only. A `GET` logout is forgeable from any page.

### 10. Access and refresh tokens are not persisted.

binnacle calls no provider API on the user's behalf. The ID token is validated, its claims are copied into the identity struct, the ID token itself is retained only as the `id_token_hint` needed for RP-initiated logout, and the access and refresh tokens are discarded. `offline_access` is not requested.

### 11. Two authentication schemes, no crossover.

`/api/**` already authenticates with a static bearer token — `BinnacleWeb.Plugs.ApiAuth` comparing `BINNACLE_API_TOKEN` in constant time — because it serves **machine integrations, not browsers**. That stays exactly as it is, and this ADR records it as a deliberate second scheme rather than a leftover:

* The **browser session** authenticates HTML and LiveView routes.
* The **bearer token** authenticates `/api/**`. It is a machine credential belonging to an integration, not to a person; it carries no identity and can attribute nothing.
* **Neither grants the other.** A logged-in browser MUST NOT authenticate `/api/**`, so that a page the user visits cannot use their browser as a confused deputy against the API. A valid bearer token MUST NOT authenticate the UI.
* The `:api` pipeline **MUST NOT** call `fetch_session`. This is the enforcement, not a convention: a pipeline that never reads the session cannot accidentally honour one.

The `:api` pipeline is already `[:accepts, RateLimit, ApiAuth]` with no `fetch_session`, so this sub-decision ratifies the shipped code. **SPEC-0003 is what changes here** — its access-boundary table says `/api/**` requires a session, and that is now wrong.

When per-user API access is eventually wanted, it is a new decision (token exchange, or per-user API tokens), not a loosening of this one.

### 12. Three deployment preconditions this ADR owns.

Each of these breaks OIDC at **runtime**, not at compile time, and none of them is visible in the application code that this ADR's stories will write. They are decisions, not implementation notes:

1. **`SECRET_KEY_BASE` becomes a real OpenBao-provisioned secret.** `server/config/runtime.exs` currently does `System.get_env("SECRET_KEY_BASE") || :crypto.strong_rand_bytes(64) |> Base.encode64(...)`, justified by a comment stating that binnacle *"has no authenticated sessions."* This ADR kills that premise. A regenerated key on every boot means **every session is invalidated by every restart and every redeploy** — with a cookie session store, the cookie simply fails to verify. The fallback MUST be removed, the variable MUST be provisioned from OpenBao like `BINNACLE_API_TOKEN`, the release MUST fail to boot loudly if it is absent in `:prod`, and that comment MUST be rewritten rather than left to mislead.
2. **`PHX_HOST` MUST be set.** It is unset today, so `runtime.exs` falls back to `"example.com"`. The deployed container's environment carries only `BINNACLE_API_TOKEN`, `BINNACLE_BASELINE`, `PHX_SERVER`, `PORT`, `PUID`, `PGID`, and `TZ` — binnacle's `dub.yaml` entry has no `environment:` block at all. This is latent today because LiveView uses relative URLs; it becomes a hard failure the moment an absolute `redirect_uri` has to be generated.
3. **The Dockerfile `HEALTHCHECK` MUST move from `/` to `/healthz`.** It currently probes `http://127.0.0.1:${PORT}/`, which is the LiveView route that gating will close. The moment authentication merges, the probe follows a `302` to a login it can never complete and the container is permanently unhealthy. `/healthz` is already public and already outside the `:api` pipeline.

### Consequences

* Good, because the authenticated user becomes a value the application can act on — rendered in the shell today, attributed to a control action tomorrow, authorized by a future ADR — rather than a header binnacle must trust.
* Good, because ID tokens are signature-verified, which removes the Gren draft's dependence on the TLS chain as a sole integrity guarantee.
* Good, because `oidcc` is certified and handles JWKS rotation, so the most likely 3am failure — a rotated signing key — is handled by a library rather than by binnacle.
* Good, because no token, refresh token, or client secret is ever reachable from browser JavaScript.
* Good, because passkey-only Pocket ID means binnacle has no password, reset flow, or credential store to defend.
* Good, because the session mechanism is Phoenix's own: no bespoke store to supervise, no ETS table to own, no purge to schedule, and no novel security-critical code.
* **Bad, because logout is not revocation.** A replayed cookie authenticates until `exp`. Documented above with its mitigations; it is the price of sub-decision 5 and the thing to revisit first if the threat model changes.
* Bad, because Pocket ID supports no front- or back-channel logout, so a sign-out or account disable at the IdP does not propagate to binnacle within the session lifetime.
* Bad, because authentication is now enforced in two places (plug and `on_mount`) that must be kept in agreement. A test that only exercises `get(conn, "/")` does not cover the socket path, and a reviewer who does not know sub-decision 6 will not notice the gap.
* Bad, because binnacle gains a boot-time dependency on Pocket ID's discovery endpoint. The exponential backoff bounds it to degraded logins rather than a dead container, but a fleet monitor that cannot start when the IdP is down is a worse fleet monitor.
* Bad, because three deployment changes must land alongside the code, and two of them (`SECRET_KEY_BASE`, `PHX_HOST`) live in `stumpcloud/ansible` rather than in this repository.
* Neutral, because authorization stays coarse: every authenticated Pocket ID user is a full binnacle user. Roles over the ADR-0002 taxonomy are deliberately **out of scope** and want their own ADR once control actions define what needs restricting. `groups` is captured in the identity struct so that ADR has something to build on.
* Neutral, because the shared oauth2-proxy remains available as a fallback. Issue #18 closed it as won't-do on the bet that native OIDC lands first; it is a handful of inventory lines if that bet goes wrong.

### Confirmation

* A full login against the real Pocket ID at `identity.stump.rocks` succeeds end to end and produces a **signature-verified** ID token.
* An ID token signed by a key absent from the JWKS is rejected, and rejected *for the signature reason* — not incidentally on `nonce` or `exp`.
* An ID token presenting `alg: none` or an HMAC algorithm is rejected before any key is selected.
* A callback whose `state` matches no pending request is rejected; a consumed `state` presented twice is rejected.
* A LiveView **socket connect** carrying an expired session redirects to `/auth/login` and pushes no fleet data — verified with `LiveViewTest` against a socket, independently of any controller test.
* `Set-Cookie` on a successful login carries `Secure`, `HttpOnly`, `SameSite=Lax`, `Path=/`, a `Max-Age`, and no `Domain`.
* A browser holding a valid session receives `401` from `GET /api/sites` with no `Authorization` header; a valid bearer token receives `302` from `GET /`.
* `GET /healthz` answers `200 ok` unauthenticated, and the Dockerfile `HEALTHCHECK` targets it.
* The OIDC client exists in Pocket ID via `joestump.pocket_id.oidc_client` with `pkce_enabled: true`; no secret appears in the repository, the image, rendered HEEx, socket assigns, or a crash report.
* `SECRET_KEY_BASE` is supplied from OpenBao and a session survives a container restart.
* Realized by SPEC-0003 (`docs/specs/oidc-authentication/`).

## What this ADR reverses from the Gren draft, and why each existed

Every reversal below was **correct given Gren's constraints**. None of them was arbitrary, and none survives ADR-0004.

| Gren-era position | Why it existed then | Position now |
|---|---|---|
| ID-token signature verification skipped under OIDC Core §3.1.3.7 item 6 | Gren shipped no cryptography; RS256 and JWKS could not be on the critical path at all | **Signature verification required.** RS256 pinned, `alg: none` and HMAC rejected before key lookup, `kid` matched |
| Two-function task port to Node's `crypto` (`randomBytes`, `sha256`) | Gren had no CSPRNG and no hashing; the port was the only route to either | **No port.** `:crypto`, `Plug.Crypto`, JOSE — all in OTP or already in `mix.lock` |
| Opaque 256-bit session identifier in a cookie, mapping to server-held state | Gren could not sign or encrypt a cookie, so a self-contained cookie was impossible | **Phoenix `Plug.Session` cookie**, encrypted and signed. Loses server-side revocation; mitigations recorded in sub-decision 5 |
| Session and pending-request state in a bespoke store with a scheduled purge | Follows from the opaque identifier — the state had to live somewhere | **No store.** `state`, `nonce`, and the PKCE verifier ride in the session cookie; nothing to purge |
| Identity type shared through `packages/core` | ADR-0001's one-language rule put the wire contract in a shared Gren package | **No `packages/core`.** `Binnacle.Auth.Identity` is one Elixir struct used by both the plug and the `on_mount` hook |
| SPA fetches `GET /api/session` to learn who it is | The Gren SPA was a separate client and needed an endpoint to ask | **No endpoint, no SPA.** A LiveView reads `socket.assigns.current_identity`, established at mount |
| `oauth2_proxy.enabled: true` as an interim gate | `server/` did not exist, so binnacle could not gate itself at all | **Obsolete.** `server/` is a running Phoenix app; issue #18 closed the interim gate as won't-do in favour of going native |
| Route gating in a single request-path classifier | Gren's server was request/response only; there was no websocket to miss | **Gated twice**: router plug *and* `on_mount` inside a `live_session` |

Two things that were **not** reversed, and should not be re-litigated:

* **Native OIDC over the shared oauth2-proxy.** The reasoning — attribution, and identity as data rather than a verdict — is unchanged.
* **Per-user authorization is out of scope.** Still deliberately excluded, still wants its own ADR.

## Pros and Cons of the Options

### A. Native OIDC confidential client in the Phoenix server

* Good, because the identity is available to application logic as typed data, not just as an access verdict.
* Good, because it is the pattern ADR-0018 prefers, and the one Grafana, Gitea, Mealie, and Open-WebUI already use on this fleet.
* Good, because it leaves room for per-user authorization without re-architecting.
* Good, because on Elixir the implementation cost is a supervised worker, two controller actions, a plug, and an `on_mount` hook — small enough that the Gren draft's "cannot ship until the server exists" objection has evaporated.
* Bad, because binnacle owns session lifecycle, logout, and expiry code it would otherwise not write.
* Bad, because it adds a boot-time dependency on the IdP's discovery endpoint.

### B. Shared oauth2-proxy forward auth

* Good, because it is one inventory line and needs no application code; it could gate binnacle today.
* Good, because domain-wide `.stump.rocks` cookies give SSO with every other protected service.
* Good, because it is proven on this fleet and maintained outside binnacle.
* Bad, because identity arrives as a header the application must trust implicitly; anything reaching the container port directly, bypassing Caddy, can simply assert it — and on the LAN that is not a hypothetical.
* Bad, because it gates but does not authorize — ADR-0018 says so itself — and every authenticated Pocket ID user is equivalent with no way to tell them apart in an audit line.
* Bad, because auth for binnacle on ie02 would depend on oauth2-proxy on ie01, adding a cross-host failure mode to a tool whose job is telling you when hosts are down.

Retained as the **fallback**, not the destination: if native OIDC slips and binnacle's exposure changes, #18 is reopened.

### C. Public client in the browser (PKCE)

* Good, because it needs no server-side secret handling.
* Bad, because tokens live in browser-reachable storage, which is the exact exposure option A eliminates.
* Bad, because it fits the application badly: LiveView holds server-side state per connection, so the natural place for the identity is the socket's assigns, not `localStorage`.
* Bad, because the server would still need its own boundary — a public client authenticates the browser to the IdP, not the socket to binnacle.

### D. No authentication; restrict at the network layer

* Good, because it costs nothing and is the *de facto* current state — the LAN-only DNS record is a real boundary, not an accident.
* Bad, because it is flat network trust: every device on the LAN is an administrator of the fleet console, including guests, IoT devices, and anything compromised on it.
* Bad, because it provides no attribution whatsoever for the control actions the roadmap adds.
* Bad, because the boundary is a DNS record, which is one convenience change away from disappearing.

## Architecture Diagram

```mermaid
sequenceDiagram
    autonumber
    participant B as Browser
    participant C as Caddy
    participant A as AuthController<br/>(plain routes)
    participant L as FleetLive<br/>(live_session)
    participant P as Pocket ID<br/>identity.stump.rocks

    B->>C: GET /
    C->>L: GET / (dead render)
    Note over L: RequireAuth plug: no session
    L-->>B: 302 /auth/login
    B->>A: GET /auth/login
    Note over A: :crypto.strong_rand_bytes<br/>state · nonce · PKCE verifier<br/>written to the session cookie
    A-->>B: 302 authorize?response_type=code<br/>&code_challenge_method=S256<br/>&response_mode=query
    B->>P: authenticate (passkey)
    P-->>B: 302 /auth/callback?code&state
    B->>A: GET /auth/callback (cookie carries state)
    A->>A: compare state (constant time)
    A->>P: POST /api/oidc/token<br/>code + verifier + client_secret_basic
    P-->>A: id_token
    A->>P: GET /.well-known/jwks.json (cached, ETS)
    A->>A: verify RS256 signature by kid<br/>then iss · aud · exp · iat · nonce
    A-->>B: 302 / + Set-Cookie: encrypted session<br/>Secure; HttpOnly; SameSite=Lax; Max-Age
    B->>L: GET / then websocket connect
    Note over L: on_mount :require_authenticated<br/>runs on connect AND every reconnect
    L-->>B: fleet data over the socket
```

## More Information

* Extends ADR-0004, the Elixir full-stack base — Elixir + Phoenix + LiveView is the base this design sits on, and the reason nearly every implementation decision here differs from the draft this ADR replaces.
* Governed spec: SPEC-0003 (`docs/specs/oidc-authentication/`).
* Fleet precedent: `stumpcloud/ansible` ADR-0018, *OAuth2-Proxy as Shared Forward Auth Layer* — its "when to use oauth2-proxy vs native OIDC" table is the direct basis for choosing A.
* Identity provider: Pocket ID v2, https://identity.stump.rocks — passkey-based, provisioned via the `joestump.pocket_id` Ansible collection. Provider facts in this ADR were read from its live `/.well-known/openid-configuration` on 2026-08-21.
* Library: `oidcc` — https://hex.pm/packages/oidcc — and `oidcc_plug` — https://hex.pm/packages/oidcc_plug. OpenID certification by the Erlang Ecosystem Foundation.
* OIDC Core 1.0 §3.1.3.7, ID Token Validation — item 6 is the clause the Gren draft relied on, and which this ADR deliberately declines to use.
* Related defects found while auditing this area, tracked separately: `RateLimit` is a no-op in production (#60), and the shipped CSP blocks the theme bootstrap and font stack (#61).
* Deliberately deferred to a future ADR: per-user authorization over the ADR-0002 taxonomy, and whether binnacle keeps its own audit log or writes to an existing one.
