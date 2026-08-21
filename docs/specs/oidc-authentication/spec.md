---
status: draft
date: 2026-08-21
implements: [ADR-0006]
---

# SPEC-0003: OIDC Authentication — Pocket ID Login and Phoenix Sessions

## Overview

binnacle authenticates its users against Pocket ID v2 (`identity.stump.rocks`) as a native OIDC confidential client running in the Phoenix server, per ADR-0006. The server performs the authorization code flow with PKCE, holds the client secret, **verifies the ID token's signature**, and issues a signed-and-encrypted Phoenix session cookie. No token, refresh token, or client secret is ever exposed to browser JavaScript.

This spec covers the login and session boundary only. Per-user *authorization* — who may control which host, guest, or container — is deliberately out of scope and awaits its own ADR once control actions exist.

> **Rewritten 2026-08-21 for Elixir/Phoenix.** This spec was drafted against the Gren stack that ADR-0004 superseded, and its governing ADR was renumbered from ADR-0004 to ADR-0006 in the same pass. Requirements that reasoned from Gren's lack of cryptography — the crypto task port, the signature exemption, the bespoke session store, the `packages/core` identity type, the `GET /api/session` endpoint, and the interim oauth2-proxy gate — are removed or replaced. ADR-0006 carries a table of every reversal and why the original existed; this document states only the current requirements.

Two facts about the shipped application shape everything below and are stated once here rather than repeated:

* **The UI is LiveView, not an SPA.** A router pipeline runs on the initial dead render and never again. Every requirement that gates a route therefore has a socket half as well as an HTTP half.
* **`/api/**` is a machine surface.** It already authenticates with a static bearer token for integrations. It is not a browser API, and this spec no longer claims it requires a session.

## Requirements

### Requirement: Unauthenticated Access Boundary

The server SHALL require an authenticated session for every route except those explicitly enumerated as public. Gating SHALL be the default: a route added with no explicit public designation is gated.

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| GET | `/healthz` | Public | Container HEALTHCHECK and the deploy lane's readiness probe. MUST NOT redirect, MUST NOT set cookies, and MUST NOT be rate limited. |
| GET | `/assets/*` | Public | Hashed static assets served by `Plug.Static`. Compiled application code containing no fleet data. |
| GET | `/auth/login` | Public | Initiates the authorization request. Unauthenticated by definition. |
| GET | `/auth/callback` | Public | The IdP redirects the browser here before a session exists. Unauthenticated by definition. |
| POST | `/auth/logout` | Session | Ends the session. `POST` only. |
| GET | `/` and all LiveView routes | Session | Fleet data. Gated by the router plug **and** by `on_mount` inside a `live_session`. |
| GET | `/api/**` | **Bearer token** | Machine integrations (SPEC-0001). Authenticated by `BINNACLE_API_TOKEN`, **not** by a browser session — see "Two Authentication Schemes, No Crossover". |

An unauthenticated request to a gated **page or LiveView** route SHALL receive `302` to `/auth/login` carrying the original path as a validated return target. An unauthenticated request to `/api/**` SHALL receive `401` with a JSON body and no `Location` header. API requests MUST NOT be answered with a redirect, because a redirect to an HTML login page is indistinguishable from success to a `fetch` caller and surfaces as a JSON parse error rather than an auth failure.

On the LiveView socket, an unauthenticated or expired mount SHALL `redirect` to `/auth/login` and SHALL push no fleet data.

#### Scenario: Unauthenticated API request is rejected, not redirected

- **WHEN** a request without an `Authorization` header arrives at `GET /api/sites`
- **THEN** the server responds `401` with a JSON body and no `Location` header

#### Scenario: Unauthenticated page request is redirected to login

- **WHEN** a request without a valid session cookie arrives at `GET /`
- **THEN** the server responds `302` to `/auth/login` carrying the original path as the return target

#### Scenario: The socket is gated independently of the pipeline

- **WHEN** a LiveView socket connects or reconnects carrying a cookie whose session has expired or been signed out
- **THEN** `on_mount` halts and redirects to `/auth/login`, and no fleet data is pushed over the socket

#### Scenario: Health probe is never gated

- **WHEN** `GET /healthz` is requested with no session cookie
- **THEN** the server responds `200` with body `ok`, no redirect and no `Set-Cookie`

#### Scenario: A new route is gated by default

- **WHEN** a route is added with no explicit public designation in this table
- **THEN** it requires authentication until this spec is amended

### Requirement: Authorization Code Flow

The server SHALL implement the OIDC authorization code flow as a confidential client. The implicit and hybrid flows MUST NOT be used.

`GET /auth/login` and `GET /auth/callback` SHALL be actions on a plain controller, outside every `live_session`. A LiveView process cannot set a cookie — by the time it mounts, the HTTP response is sent and no `Plug.Conn` is in play — and both endpoints must write to the session cookie.

On `GET /auth/login` the server SHALL generate a `state`, a `nonce`, and a PKCE code verifier, each of at least 128 bits of `:crypto.strong_rand_bytes/1` output. `:rand` and any other non-cryptographic generator MUST NOT be used. These values SHALL be recorded in the session cookie against an expiry of no more than 10 minutes, and the browser SHALL be redirected to the provider's authorization endpoint with:

- `response_type=code` — pinned. Pocket ID also advertises `id_token`, which would deliver a token through the browser.
- `code_challenge_method=S256` — pinned. Pocket ID also advertises `plain`, which MUST be rejected and MUST NOT be negotiated to.
- `response_mode=query` — pinned. `form_post` returns the response as a cross-site `POST`, on which `SameSite=Lax` withholds the very cookie carrying `state`, `nonce`, and the verifier, and which `protect_from_forgery` would reject regardless.
- `scope=openid profile email groups`, the configured `client_id`, and the registered `redirect_uri`.

On `GET /auth/callback` the server SHALL reject the request unless the returned `state` matches the pending, unexpired value in the session. Comparison SHALL use `Plug.Crypto.secure_compare/2`. A `state` SHALL be single-use and MUST be cleared from the session once consumed, whether the exchange then succeeds or fails.

The authorization code SHALL be exchanged by a direct server-to-server `POST` to the provider's token endpoint over TLS with certificate-chain verification enabled, authenticating with `client_secret_basic`. Pocket ID advertises `none` among its token-endpoint auth methods; that MUST NOT be used. The code and the secret MUST NOT pass through the browser.

#### Scenario: Login redirects with state, nonce, and an S256 challenge

- **WHEN** an unauthenticated user requests `GET /auth/login`
- **THEN** the server redirects to the Pocket ID authorization endpoint with `response_type=code`, a `state`, a `nonce`, and `code_challenge_method=S256`

#### Scenario: Callback with an unknown state is rejected

- **WHEN** `GET /auth/callback` arrives with a `state` that matches no pending value in the session
- **THEN** the server responds `400`, creates no session, and logs the rejection

#### Scenario: Replayed state is rejected

- **WHEN** a `state` value that was already consumed by a prior callback is presented again
- **THEN** the server responds `400` and creates no session

#### Scenario: Expired authorization request is rejected

- **WHEN** a callback presents a `state` recorded more than 10 minutes earlier
- **THEN** the server responds `400` and creates no session

### Requirement: ID Token Validation

The server SHALL **verify the ID token's signature** against a key from the issuer's JWKS, discovered from `/.well-known/openid-configuration`. There is no exemption. The Gren-era reliance on OIDC Core 1.0 §3.1.3.7 item 6 is withdrawn: it existed because Gren shipped no cryptography, and on the BEAM `:crypto` and JOSE make verification ordinary.

The server SHALL:

- Accept only `RS256`, matching Pocket ID's `id_token_signing_alg_values_supported`. The `alg` header MUST be one the issuer advertises and MUST be asymmetric.
- Reject `alg: none` and every HMAC algorithm **before any key lookup occurs**, rather than matching them against a key.
- Select the verification key by **`kid`**. Trying every key in the JWKS and accepting the token if any of them verifies MUST NOT occur.
- Cache the discovery document and JWKS with a bounded lifetime, and re-fetch on an unknown `kid`, with the re-fetch itself rate-limited so an attacker cannot drive unbounded requests at the issuer.
- Verify `iss` exactly equals the configured issuer, `aud` contains the configured `client_id`, `exp` is in the future and `iat` not implausibly old, allowing no more than 120 seconds of clock skew, and `nonce` equals the value recorded in the session.

If any check fails the server SHALL NOT create a session and SHALL respond `401`.

TLS certificate-chain verification of the token and JWKS endpoints MUST NOT be disabled by configuration, environment variable, or build flag.

#### Scenario: Token with an unverifiable signature is rejected

- **WHEN** an ID token is presented whose signature does not verify against a JWKS key
- **THEN** no session is created and the server responds `401`

#### Scenario: Algorithm confusion is refused before key lookup

- **WHEN** an ID token is presented with `alg: none` or an HMAC `alg`
- **THEN** it is rejected before any key is selected, no session is created, and the server responds `401`

#### Scenario: Unknown kid triggers a bounded refresh

- **WHEN** an ID token carries a `kid` absent from the cached JWKS
- **THEN** the JWKS is re-fetched at most once within the configured window, and if the key is still unknown the token is rejected `401`

#### Scenario: Token with a mismatched nonce is rejected

- **WHEN** the ID token's `nonce` does not match the value recorded in the session
- **THEN** the server creates no session and responds `401`

#### Scenario: Expired token is rejected

- **WHEN** the ID token's `exp` is in the past beyond the permitted skew
- **THEN** the server creates no session and responds `401`

#### Scenario: Token for another audience is rejected

- **WHEN** the ID token's `aud` does not contain binnacle's configured `client_id`
- **THEN** the server creates no session and responds `401`

### Requirement: Session Lifecycle

On successful validation the server SHALL establish a Phoenix session via `Plug.Session`. The session is a **signed and encrypted cookie**, not an opaque identifier pointing at server-held state; there is no session store to supervise.

`@session_options` in `BinnacleWeb.Endpoint` SHALL set:

- `store: :cookie` with both a `signing_salt` and an **`encryption_salt`**, so the payload is encrypted rather than merely signed. The session carries claims, and a signed-only cookie is readable by anyone holding it.
- Both salts read from configuration. The `signing_salt` MUST NOT remain a literal in `endpoint.ex`.
- `secure: true` — **missing today** — `http_only: true`, `same_site: "Lax"`, `Path=/`, and no `:domain`, so the cookie stays host-scoped to binnacle rather than shared across `.stump.rocks`.
- `max_age` matching the session cap below.

Sessions SHALL expire no more than **1 hour** after creation. The expiry SHALL additionally be carried as a claim **inside the session payload** and checked server-side on every request and **every mount, including every LiveView reconnect** — the cookie's `max_age` is enforced by the client and MUST NOT be the only thing enforcing expiry. An expired session SHALL be treated as absent.

Session contents SHALL be limited to the subject identifier, the identity claims enumerated under "Identity in Assigns", the issue time, the expiry, and the ID token retained solely as the `id_token_hint` for RP-initiated logout. **Access and refresh tokens SHALL NOT be persisted**, and `offline_access` SHALL NOT be requested.

`POST /auth/logout` SHALL clear the session, disconnect the user's live sockets via `live_socket_id` and `Endpoint.broadcast/3`, and redirect to the provider's `end_session_endpoint` with the `id_token_hint`. Logout MUST be `POST`-only; a `GET` logout is forgeable from any page.

**Revocation limit, stated normatively so it is not discovered later.** A cookie session cannot be revoked before it expires. Clearing the cookie ends the session in *that* browser, and the socket broadcast terminates connected LiveViews immediately, but a cookie value captured before logout and replayed afterwards SHALL still authenticate until its `exp` elapses. Pocket ID advertises neither front-channel nor back-channel logout, so a sign-out or account disable at the IdP likewise does not propagate into binnacle within the session lifetime. The 1-hour cap is the bound on both exposures, and is short for exactly that reason. Any requirement for immediate revocation is a change to ADR-0006, not an implementation detail.

#### Scenario: Successful login issues a hardened cookie

- **WHEN** the ID token passes every validation check
- **THEN** the response sets a cookie carrying `Secure`, `HttpOnly`, `SameSite=Lax`, `Path=/`, a `Max-Age`, and no `Domain` attribute

#### Scenario: Logout ends the session and disconnects live sockets

- **WHEN** a user posts to `/auth/logout` while a LiveView is connected
- **THEN** the session is cleared, the live socket is disconnected by broadcast, and the browser is redirected to the provider's `end_session_endpoint`

#### Scenario: Expiry is enforced server-side, not only by the cookie

- **WHEN** a session payload whose `exp` claim has passed is presented, on an HTTP request or on a socket mount
- **THEN** the request or mount is treated as unauthenticated regardless of what the cookie's own `Max-Age` would have allowed

### Requirement: Two Authentication Schemes, No Crossover

`/api/**` authenticates with a static bearer token (`BinnacleWeb.Plugs.ApiAuth`, `BINNACLE_API_TOKEN`) because it serves **machine integrations, not browsers**. That is a deliberate second scheme, not a leftover, and this spec no longer claims `/api/**` requires a session.

- The **browser session** authenticates HTML and LiveView routes.
- The **bearer token** authenticates `/api/**`. It is a machine credential belonging to an integration, not to a person; it carries no identity and attributes nothing.
- **Neither grants the other.** A browser session MUST NOT authenticate `/api/**`, so a page the user visits cannot use their browser as a confused deputy against the API. A bearer token MUST NOT authenticate the UI.
- The `:api` pipeline **MUST NOT** call `fetch_session`. This is the enforcement rather than a convention: a pipeline that never reads the session cannot honour one by accident.

Per-user API access is a future decision, not a loosening of this one.

#### Scenario: A logged-in browser gets no API access

- **WHEN** a browser holding a valid binnacle session requests `GET /api/sites` with no `Authorization` header
- **THEN** the server responds `401`; the session is irrelevant

#### Scenario: A bearer token gets no UI access

- **WHEN** a request presents a valid bearer token but no session and requests `GET /`
- **THEN** the server responds `302` to `/auth/login`; the token does not authenticate the UI

### Requirement: Client Configuration and Secret Handling

The OIDC client SHALL be provisioned in Pocket ID by the `joestump.pocket_id.oidc_client` Ansible module, not registered by hand, and SHALL be registered with `pkce_enabled: true` — the module defaults it to `false`.

`config/runtime.exs` SHALL read `OIDC_ISSUER_URL`, `OIDC_CLIENT_ID`, and `OIDC_CLIENT_SECRET` from the environment, sourced from OpenBao by the deployment, following the existing `BINNACLE_API_TOKEN` pattern: environment only, never `config/config.exs`, never the baseline fixture. The server SHALL fail to boot loudly in `:prod`, naming the missing variable, rather than starting unauthenticated.

The client secret MUST NOT appear in the repository, the container image, rendered HEEx, LiveView socket assigns, log output, or any error message. **Crash output counts**: an Elixir stacktrace renders the arguments of the failing call, so any struct or keyword list carrying the secret SHALL be redacted before it can reach a `FunctionClauseError` report.

The `redirect_uri` SHALL be registered explicitly and SHALL exactly match the value the server sends. Wildcard redirect registration MUST NOT be used.

#### Scenario: Missing configuration fails startup

- **WHEN** the release starts in `:prod` with `OIDC_CLIENT_SECRET` unset or empty
- **THEN** `runtime.exs` raises naming the missing variable and the endpoint never binds

#### Scenario: Secret never reaches a response or a log

- **WHEN** the token exchange fails and the server renders an error or logs the failure
- **THEN** neither the response nor the log line contains any part of the client secret

#### Scenario: Secret is redacted in crash output

- **WHEN** the OIDC client configuration is inspected, logged, or rendered in a crash report
- **THEN** the secret is redacted rather than printed

### Requirement: Deployment Preconditions

Three deployment facts break authentication at **runtime** rather than at compile time. They are requirements of this spec because no amount of correct application code compensates for any of them.

- **`SECRET_KEY_BASE` SHALL be provisioned from OpenBao.** `runtime.exs` currently falls back to `:crypto.strong_rand_bytes(64)` when the variable is absent, justified by a comment stating binnacle *"has no authenticated sessions"* — a premise this spec ends. With a cookie session store, a key regenerated on boot invalidates **every session on every restart and redeploy**. The fallback SHALL be removed, the variable SHALL be required in `:prod`, and the comment SHALL be rewritten.
- **`PHX_HOST` SHALL be set** on binnacle's deployment. It is unset today, so the production `url` host falls back to `example.com`. This is latent while LiveView uses relative URLs and becomes a hard failure as soon as an absolute `redirect_uri` must be generated.
- **The Dockerfile `HEALTHCHECK` SHALL probe `/healthz`, not `/`.** It currently probes `http://127.0.0.1:${PORT}/`, which this spec gates. The change SHALL land no later than the change that gates `/`, or the container follows a redirect to a login it cannot complete and is permanently unhealthy.

#### Scenario: Sessions survive a redeploy

- **WHEN** the container is restarted or redeployed with `SECRET_KEY_BASE` supplied from OpenBao
- **THEN** a session cookie issued before the restart still authenticates afterwards

#### Scenario: The health probe survives gating

- **WHEN** authentication is enabled and the container's own HEALTHCHECK runs
- **THEN** it probes `/healthz`, receives `200`, and the container reports healthy

### Requirement: Identity in Assigns

> Renamed from **Session Identity Exposure**. There is no `GET /api/session` endpoint and no shared package; both belonged to the SPA architecture that ADR-0004 removed.

The authenticated identity SHALL be `Binnacle.Auth.Identity`, an Elixir struct defined **once** and used by both the router plug and the `on_mount` hook. `BinnacleWeb.Plugs.RequireAuth` SHALL assign it to `conn.assigns.current_identity`; the `on_mount` hook SHALL assign it to `socket.assigns.current_identity` at mount.

Its fields SHALL be drawn from the validated ID token alone and SHALL be bounded by Pocket ID's advertised `claims_supported`: `sub`, `given_name`, `family_name`, `name`, `display_name`, `email`, `email_verified`, `preferred_username`, `picture`, `groups`, `auth_time`, `amr` — plus the session expiry. **No userinfo request is made**: Pocket ID places `groups` in the ID token when the scope is requested, so every claim arrives signature-verified in one hop.

The struct MUST NOT carry any token or provider credential. Socket assigns are serialized into the LiveView's process state, and anything in them is one `inspect/1` away from a log line.

`groups` is captured because it is free and a future authorization ADR will want it. It grants nothing today: every authenticated Pocket ID user is a full binnacle user.

#### Scenario: A LiveView mount carries the identity

- **WHEN** a LiveView mounts with a valid session
- **THEN** `socket.assigns.current_identity` is a `Binnacle.Auth.Identity` struct carrying no token and no credential

#### Scenario: Identity claims do not exceed what the provider sends

- **WHEN** the identity struct is defined
- **THEN** every field maps to a claim in Pocket ID's `claims_supported`, or to the session expiry

#### Scenario: Inspecting the identity leaks nothing

- **WHEN** the identity struct is inspected or logged
- **THEN** no token or provider credential appears

### Requirement: Error Handling Standards

All error-producing operations in the authentication path MUST follow structured error handling:

- Errors MUST be wrapped with contextual information at each layer boundary, naming the operation that failed — for example "token exchange failed: connection refused to identity.stump.rocks".
- Distinct failure modes the caller must distinguish — unknown state, expired state, signature verification failure, claim validation failure, provider unreachable — MUST be distinct **tagged tuples** (`{:error, :expired_state}`, `{:error, {:token_invalid, :signature}}`), not one opaque string, and MUST be matched exhaustively so a new mode is a compile-time warning rather than a silent fallthrough.
- Silent error swallowing MUST NOT occur.
- `Logger` MUST be used with structured metadata rather than string interpolation.
- Authentication failures MUST be logged with the reason and the source address, and MUST NOT log the code, the token, the secret, or the session payload.

#### Scenario: Provider outage is distinguishable from rejection

- **WHEN** the token endpoint is unreachable
- **THEN** the failure is distinct in both type and log line from an ID token that was received and rejected

#### Scenario: Failed authentication logs no credential

- **WHEN** any authentication step fails
- **THEN** the log line names the reason and the source address, and contains no code, token, secret, or session payload

### Requirement: Supervised State Standards

> Renamed from **Session Store Standards**, which specified database mechanics — transactions, connection lifecycle, parameterized queries — for a store this design no longer has. Sessions live in the cookie and `state`/`nonce`/verifier ride with them, so there is nothing to transact and nothing to query. The one idea that survives is that ephemeral state must not accumulate without bound; it is restated here for OTP.

Any in-memory state introduced by this spec SHALL follow OTP ownership rules:

- An ETS table SHALL be created and owned by a **process supervised from `Binnacle.Supervisor`**, never by a request process. A table dies with its owner, so a table created by whichever request happens to arrive first is destroyed when that request finishes, and concurrent first requests race on creation.
- A restart of the owning process SHALL leave the application serving — the table is recreated by the supervision tree rather than silently disappearing.
- Any keyed table that grows with distinct client input SHALL evict idle entries on a schedule rather than only on access, so that abandoned entries do not accumulate indefinitely.

This applies to `BinnacleWeb.Plugs.RateLimit`, whose table is presently created by a request process — tracked as a defect in its own right — and to anything later added alongside it.

#### Scenario: A supervised table survives its first request

- **WHEN** the first request after a cold start completes
- **THEN** the table still exists and subsequent requests still see its contents

#### Scenario: Concurrent cold-start requests do not error

- **WHEN** many requests arrive concurrently on a cold start
- **THEN** none returns `500` from a table-creation race

#### Scenario: Idle entries are evicted

- **WHEN** a keyed entry goes idle past its window
- **THEN** a scheduled sweep removes it rather than it persisting for the process's lifetime

## Security Requirements

This spec defines HTTP endpoints and is web-facing. The following requirements are mandatory.

### Authentication

Every route defaults to authenticated. The public routes are enumerated in "Unauthenticated Access Boundary", each with its justification, and authentication is applied in **both** the router pipeline and `on_mount` inside a `live_session`. No route may be added without an explicit auth designation.

#### Scenario: A new endpoint without a designation fails review

- **WHEN** a route is added with no auth designation in this spec's table
- **THEN** it is treated as requiring authentication until the spec is amended

### Rate Limiting

`GET /auth/login` and `GET /auth/callback` SHALL be rate limited per source address, with their **own budget** separate from the API's, so a login burst cannot consume the API's allowance or vice versa. The limit SHALL permit ordinary interactive use — a handful of attempts per minute — while preventing `state` enumeration and callback flooding. A throttled callback SHALL be rejected **before** any state comparison, so throttling does not itself become an oracle.

The source address SHALL be derived from `x-forwarded-for`, and that header SHALL be trusted **only** from the known reverse proxy. Behind Caddy, `conn.remote_ip` is the proxy for every request, so an unadjusted limiter is global rather than per-client; trusting the header unconditionally instead hands an attacker an unlimited supply of bucket keys.

`/healthz` SHALL NOT be rate limited.

#### Scenario: Callback flooding is throttled

- **WHEN** one source address issues callback requests far beyond the configured rate
- **THEN** further requests receive `429` and no state comparison is performed for them

#### Scenario: Clients behind the proxy are limited separately

- **WHEN** two clients behind Caddy issue requests
- **THEN** they consume separate buckets, and exhausting one does not throttle the other

### Security Headers

Every response SHALL carry `Strict-Transport-Security`, `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, `Referrer-Policy: no-referrer`, and a `Content-Security-Policy` setting `frame-ancestors 'none'`, `default-src 'self'`, and `base-uri 'none'`.

> **`no-referrer`, amended 2026-08-21.** This spec previously specified `strict-origin-when-cross-origin` while `BinnacleWeb.Plugs.SecurityHeaders` sets `no-referrer`. `no-referrer` is the stricter of the two and binnacle has no cross-origin referrer it needs to send, so **the spec moved and the code did not**.

Headers SHALL be set at the **endpoint** level so they cover every response including error paths. Phoenix's `put_secure_browser_headers/1` fills only headers that are not already set, so the endpoint plug wins on browser routes; a test SHALL assert this so a Phoenix upgrade cannot silently downgrade the CSP.

The CSP MUST NOT use `'unsafe-inline'` on `script-src`. Inline scripts the application genuinely needs SHALL carry a per-request nonce or a build-time hash.

#### Scenario: Responses carry the headers

- **WHEN** any response is returned, authenticated or not, including an error page
- **THEN** it carries HSTS, `nosniff`, `X-Frame-Options: DENY`, `referrer-policy: no-referrer`, and a CSP denying framing

#### Scenario: The endpoint CSP survives the router's secure headers

- **WHEN** a browser route returns a response through `put_secure_browser_headers/1`
- **THEN** the endpoint-level CSP is the one present on the response

### Request Body Size Limits

The server SHALL cap request body size and reject anything larger with `413`. This is already enforced globally by `Plug.Parsers` in `BinnacleWeb.Endpoint` at 1 MB; the endpoints in this spec accept no meaningful body.

#### Scenario: Oversized body is rejected

- **WHEN** a request arrives with a body exceeding the configured cap
- **THEN** the server responds `413` and does not buffer the remainder

### CSRF Protection

State-changing requests SHALL be protected against cross-site forgery. The `:browser` pipeline SHALL keep `protect_from_forgery`, `SameSite=Lax` on the session cookie suppresses cross-site POST, and `/auth/logout` SHALL be `POST` only. The `state` parameter provides the equivalent protection for the login flow itself.

#### Scenario: Cross-site logout is ineffective

- **WHEN** a third-party page attempts to log the user out by cross-site request
- **THEN** the cookie is not attached, the CSRF token is absent, and the session survives

### Redirect Validation

The post-login return target SHALL be validated before use. It MUST be a path on binnacle beginning with a single `/`, MUST NOT begin with `//` or `/\`, and MUST NOT contain a scheme or authority. Anything failing validation SHALL be replaced with `/`. Validation SHALL happen **after** any decoding, so percent-encoded and double-encoded variants cannot smuggle an authority past it.

The return target SHALL be carried in the **session**, not in a query parameter that returns from the IdP. The `redirect_uri` sent to the provider SHALL be the configured, registered value and MUST NOT be taken from the request.

#### Scenario: Open redirect is refused

- **WHEN** a login carries a return target of `https://evil.example/`, `//evil.example/`, `/\evil.example/`, or a percent-encoded form of any of them
- **THEN** the user lands on `/` after login and never on the external host

## Accessibility Requirements

The authenticated LiveView shell renders authentication state, so the following apply per WCAG 2.1 AA. These requirements are unchanged in substance from the original spec; only the surface they describe has moved from an SPA to HEEx.

### WCAG 2.1 AA Compliance

All UI produced by this spec MUST meet WCAG 2.1 Level AA as the minimum target.

### ARIA Landmarks

The authenticated shell MUST place `role="banner"` on the header carrying the identity indicator, `role="navigation"` on navigation regions, `role="main"` on the primary content area, and `role="contentinfo"` on the footer.

### Icon-Only Controls

Any icon-only control introduced by this spec — a logout glyph or an avatar button in particular — MUST carry an `aria-label` naming its purpose. `BinnacleWeb.UI.Icon` and `BinnacleWeb.UI.Button` are the existing components to extend rather than duplicate.

### Dynamic Content Regions

Authentication state changes MUST be announced: session expiry and sign-out MUST update an `aria-live="polite"` region, and an authentication error that interrupts the user MUST use `aria-live="assertive"`. `BinnacleWeb.Layouts.flash_group/1` already wraps flashes in a polite live region and MUST be reused — two competing live regions announce unpredictably.

### Keyboard Navigation

Every interactive element MUST be keyboard operable, with logical tab order, Enter or Space activating controls, and Escape dismissing any menu holding the sign-out control.

### Focus Management

If sign-out or session expiry is confirmed through a dialog, focus MUST be trapped within it while open, MUST move to its first focusable element on open, and MUST return to the triggering element on close.
