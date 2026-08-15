---
status: draft
date: 2026-08-15
implements: [ADR-0004]
---

# SPEC-0003: OIDC Authentication — Pocket ID Login and Server-Side Sessions

## Overview

binnacle authenticates its users against Pocket ID v2 (`identity.stump.rocks`) as a native OIDC confidential client running in the Gren server, per ADR-0004. The server performs the authorization code flow, holds the client secret, validates the ID token, and issues an opaque server-side session carried by an `HttpOnly` cookie. No token, refresh token, or client secret is ever exposed to browser JavaScript.

This spec covers the login and session boundary only. Per-user *authorization* — who may control which host, guest, or container — is deliberately out of scope and awaits its own ADR once control actions exist.

## Requirements

### Requirement: Unauthenticated Access Boundary

The server SHALL require an authenticated session for every route except those explicitly enumerated as public. Public routes are limited to the health probe, the static SPA bundle, and the two endpoints that by definition run before a session exists.

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| GET | `/healthz` | Public | Container HEALTHCHECK and the deploy lane's readiness probe. MUST NOT redirect, MUST NOT set cookies, and MUST answer before the session store is reachable. |
| GET | `/` and `/assets/*` | Public | The SPA shell and its hashed bundle. Justified because the bundle is compiled application code containing no fleet data; every endpoint that returns fleet data is gated. |
| GET | `/auth/login` | Public | Initiates the authorization request. Unauthenticated by definition. |
| GET | `/auth/callback` | Public | The IdP redirects the browser here before a session exists. Unauthenticated by definition. |
| POST | `/auth/logout` | Required | Destroys the session. |
| GET | `/api/session` | Required | Returns the authenticated identity. |
| GET | `/api/**` | Required | All fleet data. |

An unauthenticated request to a gated route SHALL receive `401` when it is an API request (`/api/**`), and a `302` to `/auth/login` otherwise. API requests MUST NOT be answered with a redirect, because a redirect to an HTML login page is indistinguishable from success to a `fetch` caller and surfaces as a JSON parse error rather than an auth failure.

#### Scenario: Unauthenticated API request is rejected, not redirected

- **WHEN** a request without a valid session cookie arrives at `GET /api/fleet`
- **THEN** the server responds `401` with a JSON body and no `Location` header

#### Scenario: Unauthenticated page request is redirected to login

- **WHEN** a request without a valid session cookie arrives at `GET /fleet/ie01`
- **THEN** the server responds `302` to `/auth/login` carrying the original path as the return target

#### Scenario: Health probe is never gated

- **WHEN** `GET /healthz` is requested with no session cookie
- **THEN** the server responds `200` with body `ok`, no redirect and no `Set-Cookie`

### Requirement: Authorization Code Flow

The server SHALL implement the OIDC authorization code flow as a confidential client. The implicit and hybrid flows MUST NOT be used. On `GET /auth/login` the server SHALL generate a `state` value and a `nonce` value, each at least 128 bits of CSPRNG output, record them against a pending authorization request with an expiry of no more than 10 minutes, and redirect to the provider's authorization endpoint with `response_type=code`, `scope=openid profile email`, the configured `client_id`, and the registered `redirect_uri`.

On `GET /auth/callback` the server SHALL reject the request unless the returned `state` matches a pending, unexpired authorization request. A `state` value SHALL be single-use and MUST be deleted once consumed, whether the exchange then succeeds or fails.

The authorization code SHALL be exchanged for tokens by a direct server-to-server `POST` to the provider's token endpoint over TLS, authenticated with the `client_secret`. The code and the secret MUST NOT pass through the browser.

#### Scenario: Login redirects with state and nonce

- **WHEN** an unauthenticated user requests `GET /auth/login`
- **THEN** the server redirects to the Pocket ID authorization endpoint with `response_type=code`, a `state` parameter, and a `nonce` parameter

#### Scenario: Callback with an unknown state is rejected

- **WHEN** `GET /auth/callback` arrives with a `state` that matches no pending authorization request
- **THEN** the server responds `400`, creates no session, and logs the rejection

#### Scenario: Replayed state is rejected

- **WHEN** a `state` value that was already consumed by a prior callback is presented again
- **THEN** the server responds `400` and creates no session

#### Scenario: Expired authorization request is rejected

- **WHEN** a callback presents a `state` whose pending request was created more than 10 minutes earlier
- **THEN** the server responds `400` and creates no session

### Requirement: ID Token Validation

The server SHALL validate the ID token returned from the token endpoint. Because the token is received by direct TLS-protected communication with the token endpoint, the server MAY rely on TLS server validation in place of verifying the token signature, per OIDC Core 1.0 §3.1.3.7 item 6. This exemption applies ONLY to tokens received on that direct channel; a token arriving by any other path MUST have its signature verified before use.

Regardless of the signature exemption, the server SHALL verify that:

- `iss` exactly equals the configured issuer
- `aud` contains the configured `client_id`
- `exp` is in the future and `iat` is not implausibly far in the past, allowing no more than 120 seconds of clock skew
- `nonce` equals the value recorded against the pending authorization request

If any check fails the server SHALL NOT create a session, and SHALL respond `401`.

The server SHALL validate the TLS certificate chain of the token endpoint. TLS verification MUST NOT be disabled by configuration, environment variable, or build flag — the signature exemption above makes that chain the sole integrity guarantee for the token.

#### Scenario: Token with a mismatched nonce is rejected

- **WHEN** the token endpoint returns an ID token whose `nonce` does not match the pending request's nonce
- **THEN** the server creates no session and responds `401`

#### Scenario: Expired token is rejected

- **WHEN** the ID token's `exp` is in the past beyond the permitted skew
- **THEN** the server creates no session and responds `401`

#### Scenario: Token for another audience is rejected

- **WHEN** the ID token's `aud` does not contain binnacle's configured `client_id`
- **THEN** the server creates no session and responds `401`

### Requirement: Session Lifecycle

On successful validation the server SHALL create a session keyed by an opaque identifier of at least 256 bits of CSPRNG output. The identifier MUST NOT encode, and MUST NOT be derived from, any claim, user identifier, or timestamp.

The session cookie SHALL be set with `HttpOnly`, `Secure`, `SameSite=Lax`, and `Path=/`. It MUST NOT carry a `Domain` attribute, so that it stays host-scoped to binnacle rather than shared across `.stump.rocks`.

Sessions SHALL expire no more than 12 hours after creation. The server SHALL treat an expired session as absent and SHALL delete expired sessions rather than merely refusing them.

`POST /auth/logout` SHALL delete the server-side session and clear the cookie. Logout MUST be effective server-side: clearing the cookie alone is insufficient, because a copied cookie value would otherwise remain valid.

Session state SHALL hold only what the application needs — the subject identifier, email, display name, issue time, and expiry. Access tokens and refresh tokens SHALL NOT be persisted, because binnacle calls no provider API on the user's behalf.

#### Scenario: Successful login issues a hardened cookie

- **WHEN** the ID token passes every validation check
- **THEN** the server responds with `Set-Cookie` carrying `HttpOnly`, `Secure`, `SameSite=Lax`, `Path=/`, and no `Domain` attribute

#### Scenario: Logout invalidates the session server-side

- **WHEN** a user posts to `/auth/logout` and the same cookie value is then replayed on a gated route
- **THEN** the replayed request is treated as unauthenticated

#### Scenario: Expired session is treated as absent

- **WHEN** a request presents a session cookie whose session was created more than 12 hours earlier
- **THEN** the request is treated as unauthenticated and the session record is deleted

### Requirement: Cryptographic Primitives

All random values specified here — `state`, `nonce`, and session identifiers — SHALL be produced by a cryptographically secure pseudo-random number generator. A general-purpose pseudo-random generator, including `gren-lang/core`'s seeded `Random`, MUST NOT be used for any of them.

Because the Gren ecosystem provides no cryptographic primitives, the CSPRNG SHALL be reached through a task port exposing Node's `crypto`. The port surface SHALL be limited to random-byte generation and SHA-256, and SHALL NOT be widened to general JavaScript evaluation.

Random values SHALL be compared in constant time where a comparison decides authentication — specifically the `state` and session-identifier lookups.

#### Scenario: Session identifiers are unpredictable

- **WHEN** session identifiers are generated repeatedly
- **THEN** each is at least 256 bits drawn from the CSPRNG, and no value repeats

#### Scenario: The port surface stays narrow

- **WHEN** the task port module is reviewed
- **THEN** it exposes only random-byte generation and SHA-256, with no general-purpose evaluation entry point

### Requirement: Client Configuration and Secret Handling

The OIDC client SHALL be provisioned in Pocket ID by the `joestump.pocket_id.oidc_client` Ansible module, not registered by hand. The server SHALL read `OIDC_ISSUER_URL`, `OIDC_CLIENT_ID`, and `OIDC_CLIENT_SECRET` from the environment, sourced from OpenBao by the deployment.

The client secret MUST NOT appear in the repository, the container image, the SPA bundle, log output, or any error message or diagnostic response. The server SHALL fail to start — loudly, with a message naming the missing variable — rather than starting unauthenticated when any of the three is absent or empty.

The `redirect_uri` SHALL be registered explicitly with the provider and SHALL exactly match the value the server sends. Wildcard redirect registration MUST NOT be used.

#### Scenario: Missing configuration fails startup

- **WHEN** the server starts with `OIDC_CLIENT_SECRET` unset
- **THEN** it exits non-zero with a message naming the missing variable, and does not begin serving

#### Scenario: Secret never reaches a response

- **WHEN** the token exchange fails and the server renders an error
- **THEN** the response and the log line contain no part of the client secret

### Requirement: Session Identity Exposure

`GET /api/session` SHALL return the authenticated identity — subject, email, display name, and session expiry — as a value whose type is defined once in `packages/core` and shared by the server and the SPA, per ADR-0001. The SPA SHALL learn its identity only from this endpoint and MUST NOT parse a token.

The response MUST NOT include the session identifier, any token, or any provider credential.

#### Scenario: Session endpoint returns the shared identity type

- **WHEN** an authenticated user requests `GET /api/session`
- **THEN** the response decodes into the `packages/core` identity type, carrying no token and no session identifier

#### Scenario: Session endpoint is gated

- **WHEN** `GET /api/session` is requested without a valid session
- **THEN** the server responds `401`

### Requirement: Interim Access Control Before the Server Ships

binnacle is currently served by a static file server with no session capability, and is publicly reachable. Until the Gren server implements this spec, access SHALL be gated by the shared oauth2-proxy: the inventory entry SHALL set `oauth2_proxy.enabled: true`, per `stumpcloud/ansible` ADR-0018.

That interim gate SHALL be removed in the same change that enables native login, and the two MUST NOT both be active — a forward-auth redirect stacked in front of binnacle's own redirect produces a login loop that is difficult to diagnose from either side.

#### Scenario: Interim gate protects the current deployment

- **WHEN** an unauthenticated request reaches `https://binnacle.stump.rocks/` before the Gren server ships
- **THEN** Caddy's forward auth redirects it to Pocket ID rather than serving the SPA

#### Scenario: The two gates are never both active

- **WHEN** native OIDC login is enabled in the inventory
- **THEN** the same change removes `oauth2_proxy.enabled`, and no deployed state has both

### Requirement: Error Handling Standards

All error-producing operations in the authentication path MUST follow structured error handling:

- Errors MUST be wrapped with contextual information at each layer boundary, naming the operation that failed (for example, "token exchange failed: connection refused to identity.stump.rocks")
- Distinct failure modes that the caller must distinguish — unknown state, expired state, token validation failure, provider unreachable — MUST be represented as distinct values in the type system, not as a single opaque error string
- Silent error swallowing MUST NOT occur; every error MUST be returned to the caller or logged with sufficient context
- Structured logging MUST be used, with key-value pairs rather than string interpolation
- Authentication failures MUST be logged with the reason and the source address, and MUST NOT log the code, the token, the secret, or the session identifier

#### Scenario: Provider outage is distinguishable from rejection

- **WHEN** the token endpoint is unreachable
- **THEN** the failure is distinct in both type and log line from an ID token that was received and rejected

#### Scenario: Failed authentication logs no credential

- **WHEN** any authentication step fails
- **THEN** the log line names the reason and the source address, and contains no code, token, secret, or session identifier

### Requirement: Session Store Standards

Session and pending-authorization state SHALL be held in a store that survives neither longer than its expiry nor less than a rolling container restart, as chosen in the design document. Where the store is a database:

- Multi-step mutations that must be atomic — consuming a `state` and creating a session — MUST occur in a transaction
- Connection lifecycle MUST be explicitly managed, with connections released after use and timeouts configured
- Queries MUST be parameterized; string interpolation into queries MUST NOT occur
- Expired sessions and expired pending requests MUST be purged on a schedule, not only on access, so that an abandoned login does not accumulate rows indefinitely

#### Scenario: State consumption and session creation are atomic

- **WHEN** a callback consumes a `state` and creates a session
- **THEN** both occur in one transaction, and a failure leaves neither a consumed state nor an orphaned session

#### Scenario: Abandoned logins are purged

- **WHEN** a pending authorization request expires without a callback
- **THEN** it is removed by the scheduled purge rather than persisting until a later lookup

## Security Requirements

This spec defines HTTP endpoints and is web-facing. The following requirements are mandatory.

### Authentication

Every endpoint defaults to authenticated. The four public endpoints are enumerated in "Unauthenticated Access Boundary" above, each with its justification. No endpoint may be added without an explicit auth designation.

#### Scenario: A new endpoint without a designation fails review

- **WHEN** a route is added with no auth designation in this spec's table
- **THEN** it is treated as requiring authentication until the spec is amended

### Rate Limiting

`GET /auth/login` and `GET /auth/callback` SHALL be rate limited per source address. The limit SHALL permit ordinary interactive use — a handful of attempts per minute — while preventing an attacker from cheaply enumerating `state` values or flooding the pending-request store.

#### Scenario: Callback flooding is throttled

- **WHEN** one source address issues callback requests far beyond the configured rate
- **THEN** further requests receive `429` and no pending-request lookups are performed for them

### Security Headers

Every response SHALL carry `Strict-Transport-Security`, `X-Content-Type-Options: nosniff`, `Referrer-Policy: strict-origin-when-cross-origin`, and a `Content-Security-Policy` that sets `frame-ancestors 'none'` and `default-src 'self'`.

#### Scenario: Responses carry the headers

- **WHEN** any response is returned, authenticated or not
- **THEN** it carries HSTS, `nosniff`, a referrer policy, and a CSP denying framing

### Request Body Size Limits

The server SHALL cap request body size and reject anything larger with `413`. Endpoints in this spec accept no meaningful body, so the cap SHALL be small.

#### Scenario: Oversized body is rejected

- **WHEN** a request arrives with a body exceeding the configured cap
- **THEN** the server responds `413` and does not buffer the remainder

### CSRF Protection

State-changing requests SHALL be protected against cross-site forgery. `SameSite=Lax` on the session cookie suppresses cross-site POST, and `/auth/logout` SHALL be `POST` only — a `GET` logout is forgeable from any page and MUST NOT be offered. The `state` parameter provides the equivalent protection for the login flow itself.

#### Scenario: Cross-site logout is ineffective

- **WHEN** a third-party page attempts to log the user out by cross-site request
- **THEN** the cookie is not attached and the session survives

### Redirect Validation

The post-login return target SHALL be validated before use. It MUST be a path on binnacle beginning with a single `/` and MUST NOT begin with `//` or contain a scheme or authority. Anything failing validation SHALL be replaced with `/`. The `redirect_uri` sent to the provider SHALL be the configured, registered value and MUST NOT be taken from the request.

#### Scenario: Open redirect is refused

- **WHEN** a login carries a return target of `https://evil.example/` or `//evil.example/`
- **THEN** the user is returned to `/` after login and never to the external host

## Accessibility Requirements

The SPA renders authentication state, so the following apply per WCAG 2.1 AA.

### WCAG 2.1 AA Compliance

All UI produced by this spec MUST meet WCAG 2.1 Level AA as the minimum target.

### ARIA Landmarks

The authenticated shell MUST place `role="banner"` on the header carrying the identity indicator, `role="navigation"` on navigation regions, `role="main"` on the primary content area, and `role="contentinfo"` on the footer.

### Icon-Only Controls

Any icon-only control introduced by this spec — a logout glyph or an avatar button in particular — MUST carry an `aria-label` naming its purpose.

### Dynamic Content Regions

Authentication state changes MUST be announced: session expiry and sign-out MUST update an `aria-live="polite"` region, and an authentication error that interrupts the user MUST use `aria-live="assertive"`.

### Keyboard Navigation

Every interactive element MUST be keyboard operable, with logical tab order, Enter or Space activating controls, and Escape dismissing any menu holding the sign-out control.

### Focus Management

If sign-out or session expiry is confirmed through a dialog, focus MUST be trapped within it while open, MUST move to its first focusable element on open, and MUST return to the triggering element on close.
