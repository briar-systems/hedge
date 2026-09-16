# Changelog

## [Unreleased]

### Changed

- **Breaking.** `server.limits.max_connections` is optional and absent by default, and both it and `max_connections_per_peer` are reloadable (#111, #113). Absent means no cap on any transport: connection storage grows with what is actually connected and the ceiling is the descriptor table and what the allocator will give. Present means a policy cap, applies to every transport, and admission refuses past it exactly as the preallocated pool did. Zero is a configuration error rather than a spelling of no limit. `plan.reload_compatible` no longer treats either limit as startup-owned, since neither sizes any storage.
- **Breaking.** `schema.Limits.max_connections` and `max_connections_per_peer` are `opt[usize]`, and `reset_graph` leaves the global limit absent where it defaulted to 10000. The per-peer default is unchanged at 100.
- The TCP connection pool grows on demand (#113). `listener.Owner` holds its connections in a chunked directory and `serve` holds its slots in another; a record never moves once handed out, so io completion contexts, cancel scopes and body readers keep their pointers. Each `connection.Connection` is claimed from a recycler as a peer is admitted and returned when it retires, so a 106 KiB record exists per live connection rather than per configured one. Starting a server allocates four times where it allocated six, and an idle listener holds no connection storage at all.
- `hedge.admission` grows its peer and lease tables and finds a peer through a hash index seeded once per process, rather than scanning to a preallocated capacity (#113). `make` takes an allocator and `opt[usize]` limits, `retune` moves them, and `destroy` releases what was grown.
- The QUIC connection pools grow on demand (#138). `quic_runtime.ConnectionStorage` (589 KiB) and `h3_session.SessionStorage` (938 KiB) are claimed from recyclers as a connection and its session are taken and returned when they retire, so an idle QUIC listener no longer reserves about 1.5 GiB of address space. `quic_runtime.Connection`, `assembly.SecretStorage` and `h3_session.Session` live in `hedge.storage.SecretTable`s that the runtime grows through `quic_runtime.ControlView`, and a record never moves once its chunk exists. The routing table owns its entries and rehashes into a larger array as it fills, and the timer queue grows its heap and per-slot positions, so neither sentinel depends on a capacity any more. Pending initials grow the same way, and a QUIC runtime's storage is released when it is.
- **Breaking.** `composition.DEFAULT_QUIC_POOL`, `quic_pool_size` and `quic_capacity_required` are removed. `composition.quic_required` says whether a graph needs the QUIC controls, and `make_controls` takes no capacity. `quic_runtime.Storage`, `make_storage`, `route_capacity_required`, `ROUTE_TABLE_LOAD` and `ROUTES_PER_CONNECTION` are removed, `quic_runtime.make` takes only the view and a `RuntimeConfig` of allocator and chunks, and `PumpConfig.connection_limit` and `max_connections_per_peer` are the configured `opt[usize]` limits. `routing.make`, `timers.make` and `h3_session.make_pool` take an allocator in place of caller arrays.
- **Breaking.** `serve.make` no longer takes a pool size or caller-provided slot and connection arrays, which it no longer needs. `serve.slot_at`, `serve.slot_connection` and `serve.last_refusal` expose what a caller used to read out of those arrays; the refusal reason in particular has to be published on retirement now that the record it lived in goes back to the pool.
- Dependencies: mach-std v3.0.1 and mach-quic v0.7.0, in `mach.toml` and in `test/acme/mach.toml` (#113). The io runtime's slot, completion, timer and source tables grow on demand, so `RESOURCE_EXHAUSTED` means the allocator refused rather than that a configured size was reached, and the linux completion index widened past its 65535 ceiling (briar-systems/mach-std#653). QUIC admission, token and listener storage takes an allocator in place of caller-sized tables, so hedge no longer preallocates four arrays of `max_connections` entries per pump bank (briar-systems/mach-quic#100).
- `test/load/run.sh` and `doc/bench/run.sh` drop their `max_connections` settings. Both keep `max_connections_per_peer`, which the whole load coming from one address still needs.

### Added

- `call.finalizer_state`: the service that attached a call's finalizer reclaims the per-exchange state it owns when the call is entered again, so a service that reports itself pending needs no registry of its own (#116).
- `test/load/`, a harness that holds 256 connections open against the real executable and requires every one of them to be served, wired into CI here because it only passes once the mach-std pin has moved. Cleartext runs beside TLS as the control (#122).
- `test/load/` QUIC cells (#138). One server with no limit has to serve 1100 concurrent HTTP/3 connections, and a server capped at 48 has to admit QUIC to exactly what 32 held TCP connections leave, refuse the rest, and then refuse TCP while QUIC holds its share. The served-1100 cell does not pass yet (#145) and is not wired into CI. `test/load/h3load` is a quic-go client kept for when mach-quic accepts Initials above 1200 bytes (#140).

### Changed

- `hedge.service.laurel` resumes a suspended laurel request instead of re-running it (#116). `RequestState` gains laurel's `middleware.Execution`, a pending execution is reported as `SERVICE_PENDING`, and re-entry calls `app.resume` rather than dispatching, binding and executing a second time. The handler is entered once however many reads its body takes.
- The laurel adapter calls `app.abandon` before releasing a context whose execution is still suspended, so a connection that dies mid-suspension still runs every middleware exit half that is owed and cannot leak an admission slot (#116).
- Dependencies: laurel v0.11.0, mach-crypto v0.9.2. laurel's handler and middleware signatures changed in v0.11.0: a middleware is now a `before`/`resume`/`after` triple, and a handler returns `handler.Result` (#116). laurel v0.11.0 supports mach-std v2.1.0 as well as the v2.2.0 it pins for itself; hedge takes v2.2.0 in #122.
- `test/acme` declares `mach-crypto` itself, as it already declares `mach-std`. laurel reaches crypto with a different selection than hedge's other dependencies, and hedge's own root declaration cannot settle a graph where hedge is not the root (#116).
- Dependencies: mach-std v2.2.0, in `mach.toml` and in `test/acme/mach.toml`, which declares its own and is the root of its own graph. `io.runtime.wait` now collects native readiness on every call, so one connection streaming a response no longer keeps any other socket's readiness from being collected. Concurrent TLS connections are served evenly rather than starved (#122, briar-systems/mach-std#658).

### Added

- `cache: a response is stored when its client stops writing before the answer` constructs the two-completions-in-one-wait pairing rather than waiting for the runtime to produce it, by half-closing the client before the server answers, so it guards the fixes below at any mach-std pin (#133).

### Fixed

- A proxy link that received its whole response is returned to the idle pool even when the client goes away in the same turn the last of that response arrived (#133). The link settles what it already holds before its reusability is judged, and reusability is read from the upstream rather than from how the downstream exchange ended.
- A connection arriving while a finished one is still being torn down waits for its slot instead of being refused, and a poll retires what finished before it admits what arrived (#133). A pool full of live connections still refuses, which is what `max_connections` means; a pool holding a slot open for a teardown does not.
- A connection advances its engine after every completion it settles, not only when the settlement itself reported progress (#133). Two completions for one connection arrive together whenever both are ready at the same native collect, and the second was being applied to an engine that had never been advanced past the first, which discarded a finished response.
- A QUIC connection cancelled on its first delivery, or while its routes and timer were first published, starts its close and is released at the drain deadline (#141). It used to stay cancelling for the life of the process, holding its slot and admission lease, and it kept SIGTERM from ever stopping the server.

## [0.4.1] - 2026-09-15

### Changed

- `hedge.service.laurel` ends the application's middleware chain through laurel's exported `router.terminal_handler` rather than its own copy of the mapping (#125). Dependencies: laurel v0.10.0.

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
