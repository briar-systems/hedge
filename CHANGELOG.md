# Changelog

## [Unreleased]

### Removed

- `example/`, which `demo/` replaced on 2026-09-02 and which nothing has touched since (#123). The `fixed` and `redirect` service kinds it showed are documented in doc/CONFIGURATION.md, and the multi-origin `upstream` form it carried is a commented alternative in `demo/proxy/hedge.toml`.

## [0.4.0] - 2026-09-15

### Added
- `server.limits.call_memory_bytes` and `service.<name>.memory_bytes` bound the memory one request may hold, and a registered application declares what it needs as the last argument to `service.register_application`. See Request memory in doc/CONFIGURATION.md (#84).
- A request that exhausts its memory bound is logged as a `memory_exhausted` error naming its route and bound, and counted by `hedge_request_memory_refusals_total`. The minimum `telemetry.metric_series` is now 6 (#84).
- `composition.Options.applications`: the registry `kind = "laurel"` services resolve against, owned by the embedding program, at startup and at every reload (#81).

### Changed
- Request memory is claimed in chunks as a request asks for it and returned when it settles, instead of a fixed 32 KiB arena carried inline by every HTTP/1 connection, HTTP/2 stream and HTTP/3 request slot (#84).
- An HTTP/2 session is claimed per connection instead of from a table of 16, so the 17th concurrent HTTP/2 connection is no longer refused (part of #92).
- TLS session storage grows with the connections that negotiate TLS instead of refusing the 65th (#112).
- The connection pool sweeps only live slots, so a large `max_connections` no longer costs throughput when idle (#88).
- `hedge.service.laurel.make` takes only the application. The adapter dispatches through the application's own router and fallback, so routes with typed and wildcard parameters work (#82).
- `serve.make` takes the allocator per-protocol storage is claimed from.
- Dependencies: mach-crypto v0.9.1, mach-tls v0.3.1, mach-quic v0.6.1, mach-http v0.8.2, mach-acme v0.2.1, laurel v0.9.2. On the same machine and release build, the server CPU for a TLS 1.3 connection's handshake and first request drops from 573 ms to 20 ms, and for a kept-alive 1 KiB request from 5.25 ms to 0.30 ms (#91, #72).

### Fixed
- A service that suspends on the request body receives it on HTTP/1.1, HTTP/2 and HTTP/3. The host no longer completes the service's own suspended read (#83).
- One QUIC connection's failure no longer shuts down the server, and shutdown completes (#89).
- A process that served an HTTP/3 request exits on SIGTERM instead of spinning. A force-released QUIC connection now cancels its scope before destroying it (#118).

## [0.3.1] - 2026-09-13

### Fixed
- Log method and target as text rather than hex (#77).

### Changed
- Dependencies: mach-std v2.1.0.

## [0.3.0] - 2026-09-13

### Changed
- Migrated to mach 5.0 and mach-std 2.0.0.
- Dependencies: mach-crypto v0.9.0, mach-tls v0.3.0, mach-quic v0.6.0, mach-http v0.8.0, mach-acme v0.2.0, laurel v0.9.0.

## [0.2.1] - 2026-09-05

Validated with the root suite in both profiles, the interoperability matrix
(46 legs) and IR verification on all six targets. The runtime harness
(`test/runtime`) was not run for this release: it peaks near 18 GiB and the
release machine could not provide it.

### Added

- `demo/`: three runnable deployments (a static site, the same over TLS with HTTP/2 and HTTP/3, and a reverse proxy), and `doc/bench/`: a benchmark project against Caddy with a published first run and a comparison of throughput, memory and operation.

### Changed

- Dependencies: mach-http v0.7.6, laurel v0.8.9, mach-tls v0.2.5, mach-quic
  v0.5.9, mach-acme v0.1.9, mach-crypto v0.8.2.
- A TLS client that offers no ALPN extension now selects the listener's
  HTTP/1.1, where the listener serves it, instead of selecting nothing.
  RFC 7301 section 3.2 reserves the `no_application_protocol` alert for a
  client that offered protocols and matched none; a client that offered no
  extension is served without ALPN. HTTP/2 over TLS is reachable only by
  negotiating `h2`, so HTTP/1.1 is the only fallback, and a listener that
  does not serve it still selects nothing. mach-tls v0.2.5 stops failing the
  handshake for a client that sent no extension, which is where the alert was
  raised, and the interoperability matrix gains a no-ALPN OpenSSL leg.

### Removed

- `tools/check-version.sh` and `tools/partial_literal_sweep.py`. The version
  check belongs to the release process rather than a script in the tree, and
  the literal sweep was a workaround for briar-systems/mach#3108, which is
  being fixed in the compiler.

### Fixed

- The QUIC runtime sweeps the connections and queued initials that are live
  rather than the whole pool the configured connection limit reserved. Every
  poll walked all `limits.max_connections` connection slots twice and every
  queued-initial slot three times, whether or not a datagram had arrived, so
  an idle HTTP/3 listener taxed the unrelated TCP path. Both pools now carry
  an intrusive live list beside their existing free list and every sweep
  walks it. At the default limit of 10000, cleartext HTTP/1.1 served
  alongside an idle QUIC listener went from 339 to 511 requests a second.
- A free QUIC connection slot and a free HTTP/3 session no longer have their
  storage written when the pool is prepared. A connection storage is 588 KiB
  and a session 33 KiB, both allocated for the configured connection limit,
  so arming every slot at startup made an idle server resident in that whole
  product. Both are armed when the slot is taken. Peak resident memory for a
  server with an idle QUIC listener fell from 672 MiB to 557 MiB. What
  remains is the secret-welded connection and session arrays, which
  mach-crypto wipes at allocation.
- Every TCP stream hedge owns now disables Nagle's algorithm, on accepted
  connections and on upstream ones alike. Nagle holds a sub-maximum segment
  back until the peer acknowledges the segment before it, and every protocol
  hedge speaks writes a message as more than one segment and then waits for
  the peer to answer, so each exchange paid the peer's delayed
  acknowledgement: 40 ms on Linux. A keep-alive HTTP/2 connection served
  about 22 requests a second at 18 percent processor use and collapsed under
  concurrency; it now serves the same work at the rate the server can
  actually do it. HTTP/1.1 was affected too, at one stalled segment per
  connection rather than one per exchange. The interoperability matrix gains
  a leg that times 100 requests over one HTTP/2 connection, because every
  other leg runs a single client against an idle server and passes at either
  rate.
- A request body the service never reads no longer logs `body ended at a
  different declared length` once the protocol layer has drained it. The
  reader in mach-http compared the bytes the service read with the declared
  length even when the drain owned the remainder (mach-http v0.7.6). A body
  that really ends short of its declared length still fails the exchange on
  every protocol.

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
