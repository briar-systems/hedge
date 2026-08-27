# Project boundaries

The Mach web stack is split where implementation, reuse, and security ownership grow independently. It is not split by individual protocol feature.

## Dependency graph

```text
mach
  builds every project

mach-std
  <- mach-crypto
  <- mach-http
  <- mach-quic
  <- mach-tls

mach-crypto
  <- mach-tls
  <- mach-quic

mach-tls
  <- mach-quic
  <- mach-acme
  <- hedge

mach-http
  <- mach-acme
  <- laurel
  <- hedge

mach-quic
  <- hedge

mach-acme
  <- hedge

laurel
  <- hedge
  <- applications
```

Arrows point from a provider to a consumer.

## `mach`

The compiler owns language semantics, target code generation, linking, build orchestration, and artifact correctness. Web projects must not compensate for compiler defects. Applicable audit findings are fixed in `mach` and covered by target-specific regressions.

## `mach-std`

The standard library owns capabilities that are useful to protocols other than HTTP:

- native socket handles and portable network errors
- endpoints, DNS, TCP, UDP, and local transports
- operation completion, timers, cancellation, and wakeups
- synchronization, threads, and bounded queues
- process signals and lifecycle notifications
- files, mappings, watchers, clocks, and entropy

The proposed upstream work is maintained in [MACH_STD_REQUIREMENTS.md](MACH_STD_REQUIREMENTS.md) until issues are opened.

## `mach-crypto`

Crypto owns algorithms and their mechanical validation. It does not own TLS wire state, certificate policy, sockets, or HTTP.

Its public surface includes hashes, MACs, KDFs, AEADs, finite-field and elliptic-curve operations, signatures, key encodings, test vectors, zeroization, and assurance tooling.

## `mach-tls`

TLS owns record protection, handshakes, key schedules, alerts, extensions, certificate messages, verification policy, sessions, and a secure byte-stream adapter.

It is transport-independent. TCP and QUIC supply different transport adapters. HTTP consumes the resulting secure stream or QUIC application transport without knowing TLS internals.

## `mach-http`

HTTP owns protocol semantics and wire engines:

- common method, status, field, URI, request, response, and body contracts
- HTTP/1.1 parsing, framing, persistence, upgrades, and serialization
- HTTP/2 framing, HPACK, stream state, priorities, and flow control
- HTTP/3 framing, QPACK, stream mapping, and control streams
- client and server connection engines
- routing primitives that do not require the application framework

It does not own daemon configuration, certificates, static-file policy, application sessions, templates, or database integration.

## `mach-quic`

QUIC owns packets, connection identifiers, transport parameters, loss recovery, congestion control, flow control, migration, path validation, streams, datagrams, and TLS handshake integration.

HTTP/3 belongs in `mach-http` because it is an HTTP mapping. The generic QUIC transport belongs in `mach-quic`.

## `mach-acme`

ACME owns accounts, nonces, orders, authorizations, challenges, finalization, certificate retrieval, renewal scheduling, and durable state contracts. Challenge presentation is injected by the server product.

## Laurel

The framework owns application concerns:

- application composition and handler context
- middleware
- typed routes and parameter decoding
- forms and multipart input
- sessions, CSRF, origin policy, and security headers
- rendering boundaries and templates
- application errors and observability
- test clients and application harnesses

It can run under Hedge or any server implementing the `mach-http` service contract.

## `hedge`

Hedge owns the operated product:

- configuration loading, validation, and reload
- listeners and protocol negotiation
- certificates and ACME orchestration
- virtual hosts and route dispatch
- static files, reverse proxying, load balancing, and caching
- admission control, limits, timeouts, and graceful drain
- logging, metrics, tracing, health, readiness, and administration
- packaging and production compatibility guarantees

Hedge must remain usable without Laurel. Laurel must remain usable without Hedge.

## Site repositories

A site repository owns content, application code, configuration, migrations, and deployment declarations. It consumes released project contracts and does not become a hidden integration layer for missing server capabilities.
