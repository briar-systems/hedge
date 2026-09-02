# Changelog

## [0.2.0] - 2026-09-02

### Added

- HTTP/3 serving. A `transport = "quic"` listener becomes ready and serves
  instead of refusing before readiness. ALPN inside QUIC selects `h3` per
  listener policy, and an HTTP/3 request reaches the same dispatch
  boundary as HTTP/1 and HTTP/2. Qualified against curl 8.21.0 over
  ngtcp2: the interoperability matrix gains three HTTP/3 legs (ALPN
  selection, a 100000-byte request body, and a byte-identical 156000-byte
  response) alongside its existing legs, and ten consecutive rounds of all
  three against one server process pass.
- `composition.Controls`, a typed secret owner for every welded QUIC
  record. The pump, connection, assembly secret storage, and HTTP/3
  session control records are allocated through `mach-crypto`
  `SecretArray`, and a failed release retains wiped ownership for retry.
- `tools/check-version.sh`, which holds `mach.toml` and `src/hedge.mach`
  to the same release version.

### Changed

- Dependency graph moved to the released QUIC storage split and the
  patches this work surfaced upstream: mach-std v0.34.0, mach-http v0.7.5,
  laurel v0.8.8, mach-tls v0.2.3, mach-quic v0.5.7, mach-acme v0.1.8, and
  mach-crypto pinned explicitly at v0.8.1.
- QUIC connection and pump backing is split between public storage and
  deep-secret storage. `ConnectionStorage` carries the public
  `assembly.Storage`; the deep-secret `assembly.SecretStorage` is owned
  per connection by `Controls`.
- The public `Runtime`, `Reloader`, `Pool`, and every public `*Storage`
  record retain no welded pointer. Code that needs the welded records
  borrows a stack-local `ControlView` that does not outlive the call.
- QUIC listener teardown follows the released lease contract: an
  unpublished listener uses `abort_initialize`, a normal close uses
  `finish_close_result`, and a retained cleanup is retried through
  `retry_cleanup` with the same handle.

### Fixed

- A QUIC connection ID whose sequence number is zero could never be
  published to the routing table, so every accepted connection was
  unreachable. RFC 9000 numbers a connection's first ID zero; the
  generations carry the validity signal, not the sequence.
- `advance` looped on a timer that was re-armed still due, starving the
  I/O completions the connection was waiting on. One pass now services a
  connection's timer once and yields.
- A connection was built with a fresh random connection ID while the
  client addressed the one the server named in its Retry, so nothing the
  client sent could be routed. The connection now adopts the accepted
  initial destination, which is the single local routing ID the
  production core carries.
- Stream scratch was sized at one maximum field where the HTTP/3 engine
  requires two, so every session failed to start and the connection was
  closed as a protocol error.
- A QUIC connection's close period was the process drain budget, so every
  finished connection lingered for the whole budget and shutdown waited it
  out. The connection now drains for the RFC 9000 close period.
- An HTTP/3 failure no longer stops the transport being driven, so a
  queued close still reaches the wire and the drain timer still fires.
- Request data longer than one read buffer is taken one buffer at a time
  instead of being rejected, since the HTTP/3 engine re-presents what has
  not been consumed.
- The secure layer closed sockets with a lifecycle cause where a close mode
  was expected, which selected a graceful shutdown the TLS close never
  accepted, so a server that had served one TLS HTTP/1.1 request could not
  stop. A retiring TLS connection now drives its secure channel to
  completion, and a graceful signal to an engine that is already ending is
  no longer counted as a shutdown failure.

### Removed

- The QUIC listener refusal path. A datagram listener no longer fails
  before readiness with a diagnostic.

## [0.1.0] - 2026-08-27

### Added

- Initial release. HTTP/1.1 and HTTP/2 over TLS 1.2 and TLS 1.3, with SNI,
  ALPN, and client certificates, qualified against curl, OpenSSL, and
  GnuTLS.
- Static files, reverse proxying, bounded caches, virtual host dispatch,
  and ACME over authenticated TLS against a compatible authority.
