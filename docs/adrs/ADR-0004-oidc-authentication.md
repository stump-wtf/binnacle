---
status: proposed
date: 2026-08-15
decision-makers: [joestump]
extends: [ADR-0001]
governs: [SPEC-0003]
---

# ADR-0004: Native OIDC authentication against Pocket ID, in the Gren server

## Context and Problem Statement

binnacle is deployed at `https://binnacle.stump.rocks` and is currently **unauthenticated** — the SPA is served to anyone who resolves the name, with no redirect, no forward auth, and no session. Today that discloses the fleet's topology; the roadmap makes it worse, because ADR-0001 scopes binnacle to *controlling* hosts as well as monitoring them, and a restart-this-container button behind no login is a different class of problem.

StumpCloud has exactly one identity provider — Pocket ID v2 at `identity.stump.rocks`, passkey-only — and `stumpcloud/ansible` ADR-0018 already sanctions two ways for a service to use it: delegate to the shared oauth2-proxy at `auth.stump.rocks` via Caddy `forward_auth`, or register a native OIDC client. How does binnacle authenticate its users, and — given that the Gren ecosystem ships no cryptography — how is that actually implementable in the Gren server?

## Decision Drivers

* binnacle is publicly reachable with no authentication right now. Closing that is the immediate driver, and nothing here should be so elaborate that it delays closing it.
* Control actions need **per-user attribution** — an audit line saying which human restarted a container — and eventually per-user authorization. A yes/no gate at the proxy cannot supply either.
* ADR-0018's own guidance: native OIDC is preferred where a service can support it; oauth2-proxy is the fallback for services that cannot. binnacle is first-party code, so "cannot" would be a choice, not a constraint.
* One identity provider, one login ritual. Passkeys mean binnacle never sees, stores, or resets a password.
* ADR-0001's one-language rule: the session and the wire contract belong in the Gren server and `packages/core`, not in a second runtime bolted alongside.
* **The Gren ecosystem has no cryptography.** `gren-lang/node` 6.1.3 exposes `Node`, `Init`, `Terminal`, `ChildProcess`, `FileSystem`, `HttpClient`, `HttpServer` — no hashing, no HMAC, no JWT, no CSPRNG — and the package registry has no third-party equivalent. Any option chosen here has to be implementable on that surface.
* Credentials live in OpenBao and clients are provisioned by `joestump.pocket_id`, not registered by hand in a UI.

## Considered Options

* **A. Native OIDC confidential client in the Gren server** — authorization code flow, server-side session, `packages/core` shares the session types with the SPA
* **B. Shared oauth2-proxy forward auth** — `oauth2_proxy.enabled: true` in dub.yaml, identity arrives as `X-Auth-Request-*` headers
* **C. Public client in the browser** — the SPA runs the code flow with PKCE and holds tokens itself
* **D. No authentication; restrict at the network layer** — drop the public DNS record, reach binnacle over the LAN or VPN only

## Decision Outcome

Chosen option: **A — a native OIDC confidential client in the Gren server**, because binnacle needs the authenticated identity as *data it can act on* (attribute a control action, and later authorize one), not merely as a gate it passed; because ADR-0018 names native OIDC the preferred pattern for services that can support it; and because the identity, its session, and the wire types can then live in the same Gren codebase as everything else per ADR-0001.

The decision carries five sub-decisions that are the substance of it:

**1. Authorization Code flow with a confidential client. No token ever reaches the browser.** The Gren server holds the `client_secret`, exchanges the code server-side, and hands the browser nothing but an opaque session cookie. The SPA learns who it is from an authenticated `GET /api/session`, never by parsing a token.

**2. The ID token is validated without a JWT library, per OIDC Core §3.1.3.7.** The specification permits a client that receives the ID token *by direct communication with the token endpoint* — which is exactly this flow — to rely on TLS server validation instead of verifying the token signature. This is what makes the decision implementable at all: it removes RS256 and JWKS from the critical path, which the Gren ecosystem cannot supply. The server still validates `iss`, `aud`, `exp`, and the `nonce` it issued, and it must therefore treat the TLS trust chain to `identity.stump.rocks` as load-bearing. The implicit and hybrid flows are excluded for exactly this reason: they deliver the token through the browser, where the signature check is not optional.

**3. Cryptographic primitives come from Node through a Gren task port.** `state`, `nonce`, and session identifiers require a CSPRNG, which Gren does not have. Gren's 25S release added task ports specifically to make this kind of interop clean, so a narrow port exposes exactly two operations — `randomBytes` and `sha256` — backed by Node's `crypto`. The port surface is deliberately two functions wide so it stays auditable.

**4. Sessions are opaque, server-side, and cookie-borne.** A 256-bit random identifier in an `HttpOnly; Secure; SameSite=Lax` cookie, mapping to server-held session state. No claims in the cookie, so no signing or encryption of cookie contents is needed — which again avoids crypto Gren does not have.

**5. The client is provisioned by Ansible, not by hand.** `joestump.pocket_id.oidc_client` registers `binnacle` with its callback URL; the secret lands in OpenBao and reaches the container as `OIDC_CLIENT_SECRET`, alongside `OIDC_CLIENT_ID` and `OIDC_ISSUER_URL`, matching the pattern every other native-OIDC service on the fleet already uses.

### Consequences

* Good, because the authenticated user becomes a value in the Gren type system — `packages/core` defines it once and both ends of the wire agree, which is the whole premise of ADR-0001.
* Good, because control actions can be attributed to a person from the moment they exist, rather than retrofitted onto an anonymous `X-Auth-Request-Email` header.
* Good, because no token, refresh token, or client secret is ever exposed to browser JavaScript; an XSS in the SPA cannot exfiltrate a credential that is not there.
* Good, because passkey-only Pocket ID means binnacle has no password, reset flow, or credential store to defend.
* Good, because the port surface is two functions, so the "auditable blast radius" property ADR-0001 claims for Gren's capability model survives mostly intact.
* Bad, because **binnacle stays unauthenticated until the Gren server ships**, and `server/` does not exist yet. This is the real cost of choosing A over B, and it must not be papered over: the interim mitigation is to set `oauth2_proxy.enabled: true` on binnacle's dub.yaml entry now, which closes the open door in one line and is removed in the same change that turns this ADR on. That interim step is a deployment decision, not a competing architecture — see SPEC-0003.
* Bad, because skipping ID token signature verification makes the TLS chain to `identity.stump.rocks` load-bearing in a way that a JWKS check would not be. It is spec-sanctioned and correct for this flow, but it is a constraint to re-examine the moment any token arrives by another path.
* Bad, because ports forfeit `gren make-static`. Irrelevant for a container image, but it forecloses a static-binary distribution if that is ever wanted.
* Bad, because binnacle now owns session lifecycle, logout, and expiry — code that oauth2-proxy would have supplied for free.
* Neutral, because authorization stays coarse for now: any Pocket ID user who authenticates is a full user. Per-user roles over the ADR-0002 taxonomy are deliberately out of scope here and want their own ADR once control actions define what needs restricting.

### Confirmation

* An unauthenticated request to any path but `/healthz` and the static bundle redirects to Pocket ID, and the redirect carries `state` and `nonce`.
* A completed login lands a session cookie that is `HttpOnly`, `Secure`, and `SameSite=Lax`, and `GET /api/session` returns the authenticated identity.
* A callback whose `state` does not match a pending authorization request is rejected, and so is an ID token whose `nonce`, `iss`, `aud`, or `exp` does not check out.
* `/healthz` still answers `200 ok` unauthenticated, or the container's own HEALTHCHECK deadlocks against the login it triggers.
* The OIDC client exists in Pocket ID via `joestump.pocket_id.oidc_client`, and no secret appears in the repo, the image, or the SPA bundle.
* Realized by SPEC-0003 (`docs/specs/oidc-authentication/`).

## Pros and Cons of the Options

### A. Native OIDC confidential client in the Gren server

The server registers as a confidential client, runs the authorization code flow, and owns the session.

* Good, because the identity is available to application logic as typed data, not just as an access verdict.
* Good, because it is the pattern ADR-0018 prefers, and the one Grafana, Gitea, Mealie, and Open-WebUI already use on this fleet.
* Good, because it leaves room for per-user authorization without re-architecting.
* Neutral, because it requires a task port for crypto — a small, well-contained exception to the pure-Gren rule.
* Bad, because it is the only option that cannot ship until `server/` exists.
* Bad, because binnacle owns session code it would otherwise not write.

### B. Shared oauth2-proxy forward auth

`oauth2_proxy.enabled: true` in dub.yaml; Caddy calls `auth:4180/oauth2/auth`, and identity arrives as `X-Auth-Request-User` and `X-Auth-Request-Email`.

* Good, because it is one line and needs no application code at all — it could gate binnacle today.
* Good, because domain-wide `.stump.rocks` cookies give SSO with every other protected service.
* Good, because it is proven on this fleet and maintained outside binnacle.
* Bad, because identity arrives as a header the application must trust implicitly; anything that reaches the container port directly, bypassing Caddy, can simply assert it.
* Bad, because it gates but does not authorize — ADR-0018 says so itself — and every authenticated Pocket ID user is equivalent.
* Bad, because auth for binnacle on ie02 would depend on oauth2-proxy on ie01, adding a cross-host failure mode to a tool whose main job is telling you when hosts are down.

**Retained as the interim mitigation**, precisely because its one-line cost is the right trade while `server/` is being built. It is not the destination.

### C. Public client in the browser (PKCE)

The SPA performs the code flow itself and holds tokens in browser storage.

* Good, because it needs no server, so it could ship on today's static container.
* Bad, because tokens live in browser-reachable storage, which is the exact exposure option A eliminates.
* Bad, because a public client **requires** PKCE, so SHA-256 becomes mandatory — in the browser, where the SPA is Gren and equally crypto-less, and would need its own port to WebCrypto.
* Bad, because a static file server cannot enforce anything: the API it eventually guards would be unprotected regardless of what the SPA does.

### D. No authentication; restrict at the network layer

Remove the public DNS record; reach binnacle over LAN or VPN.

* Good, because it costs nothing and closes the exposure immediately.
* Bad, because it is flat network trust — every device on the LAN is an administrator of the fleet console.
* Bad, because it gives up remote access, which is much of the point of a fleet monitor.
* Bad, because it still provides no attribution for control actions.

## Architecture Diagram

```mermaid
sequenceDiagram
    autonumber
    participant B as Browser (Gren SPA)
    participant C as Caddy
    participant S as binnacle server (Gren)
    participant P as Pocket ID<br/>identity.stump.rocks

    B->>C: GET /
    C->>S: GET /
    S-->>B: 302 → Pocket ID<br/>(state + nonce, PKCE via task port)
    B->>P: authorize (passkey)
    P-->>B: 302 → /auth/callback?code&state
    B->>S: GET /auth/callback?code&state
    S->>S: verify state matches a pending request
    S->>P: POST /token (code + client_secret)<br/>direct, TLS — §3.1.3.7
    P-->>S: id_token + access_token
    S->>S: verify iss / aud / exp / nonce
    S-->>B: Set-Cookie: session<br/>HttpOnly; Secure; SameSite=Lax
    B->>S: GET /api/session
    S-->>B: authenticated identity (packages/core type)
```

## More Information

* Extends ADR-0001 — the session, its types, and the task port all live in the Gren stack that ADR defines.
* Governed spec: SPEC-0003 (`docs/specs/oidc-authentication/`).
* Fleet precedent: `stumpcloud/ansible` ADR-0018, *OAuth2-Proxy as Shared Forward Auth Layer* — its "when to use oauth2-proxy vs native OIDC" table is the direct basis for choosing A here.
* Identity provider: Pocket ID v2, https://identity.stump.rocks — passkey-based, provisioned via the `joestump.pocket_id` Ansible collection.
* OIDC Core 1.0 §3.1.3.7, ID Token Validation — item 6 is the clause that permits skipping signature verification for tokens received directly from the token endpoint.
* Gren task ports: https://gren-lang.org/news/250721_gren_25s/
* Deliberately deferred to a future ADR: per-user authorization over the ADR-0002 taxonomy (who may control which host, guest, or container), and whether binnacle needs its own audit log or writes to an existing one.
