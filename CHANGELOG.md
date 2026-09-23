# Changelog

## [Unreleased]

### Changed

- A parked service is entered again only when the wait it named has moved (#131). A wake now names the call it is for (`wake.Waker.call`, `wake.for_call`, and `wake.take` hands back `wake.Wake` records of owner and call), and each protocol binds its calls with a waker derived from its connection's: HTTP/1 names its one exchange, HTTP/2 the stream's slot, HTTP/3 the request's slot. The worker routes a named call to its connection or QUIC record, request body bytes or the body's end stir a service parked on `WAIT_BODY`, and HTTP/1, HTTP/2 and HTTP/3 resume a pending service only when `call.due` says a named wait moved, its wait deadline passed or its exchange was cancelled. Before, a connection re-entered every parked service it held on any event it had: a memory or TLS wake of the connection, another stream's wake, or body bytes for a service waiting on a wake each cost a full re-entry that parked again. The debug missed-wake audit asks the same question in place of its old "pending service parked on nothing" case: a stirred call on a connection or QUIC record no queue holds is work nothing will run.
- The debug missed-wake audit asks each engine whether it holds work, rather than guessing from hedge's own state (#261). A connection carrying HTTP/2 answered the audit with no work at all. It now answers with mach-http's `h2.connection.pending_work`: output framed with no write in flight, an event not yet processed, a writable stream or a close. A QUIC record on no list is asked `transport.pending_output` at the audit's instant, and, while its HTTP/3 session polls its engine, `transport.pending_stream_news`. Pending handshake work and a recorded but unapplied cancellation read as work. A send the pool refused does not, until the account's wake reaches `storage_ready`, and stream news on an account waiting for the pool is left to that wake. A record whose wheel entry fires by the end of the tick holding the audit's instant counts as queued, since the fire services it (`timer.fires_by`): time-driven transport work comes due between the turn's timer pass and the audit, and without this the load lane's 1100-connection QUIC cell failed on a debug build. A retiring connection whose close is waiting was skipped. It is now audited on that close: a secure channel or HTTP/2 engine holding work nothing started fails it, which is the shape #257 had. With #258's close pump reverted, the two peer-close composition tests end on the audit's panic within 0.2 s, where before they failed only at their 2 s bound. An HTTP/2 response body that reports pending now clears its stream's writable flag, so the engine does not name a stream that has nothing to send. `serve.audit` and `quic_runtime.audit` take the instant they ask at. Release builds carry none of it.
- Dependencies move to mach-std v7.1.0, mach-http v0.18.0, mach-quic v0.19.0, mach-acme v0.7.1 and laurel v0.16.1 (#261), each selected by an exact version, with `test/acme` selecting the same releases and committing them as gitlinks. std 7.1.0 gives back the `io.runtime` slot, timer, deadline and source capacity a load peak grew (mach-std#868). http 0.18 adds `h2.connection.pending_work` and quic 0.19 adds `transport.pending_output` and `transport.pending_stream_news`, which the debug missed-wake audit asks. acme 0.7.1 and laurel 0.16.1 only widen their http range to `^0.18`.
- Per-connection records recede when connections leave (#235). A TCP or TLS connection's record lives inline in its serve slot, so the slot table on the compacting slab is its storage, and 10,000 connections leaving hand back every slot chunk above the survivors. Before, each record (10,984 bytes) was allocated on its own and kept on a process-lifetime free list. On this box, with release builds and 10,000 idle TCP connections: dev at 19f347d held 138 MiB and still held 130 MiB after they had closed (a probe using the scale lane's configuration); `test/load/scale.sh` on this change measures 127 MiB while they are held and 13.7 MiB after they close, and for 10,000 idle TLS connections 216 MiB while held and 14.9 MiB after they close (idle baseline 4.6 MiB). A QUIC connection's plain storage and an HTTP/3 session's storage sit beside their welded records in a `storage.Pair` (a plain table and a secret table on one slab, owned as one value), claimed at one index and released with them, where each used to be kept on a free list of its own. The plain half is not zeroed on commit, since its owner arms it on every claim, so a record costs only the pages it writes: the scale lane's QUIC slope is 102,347 bytes per connection (113,634 on 19f347d). 10,000 QUIC connections leaving fall from 982 MiB to 605 MiB (859 MiB after release on 19f347d). The QUIC after-release figure varies between runs: two earlier runs, before #257 merged, measured 531 and 621 MiB. HTTP/2 sessions sit in a table and a connection holds its session by index. `storage.Recycler` is removed with its last record consumer. The per-request byte chunk classes keep a per-class free list of their own.
- **Breaking.** Dependencies move to the std 7 family (#253): mach-std v7.0.2, mach-crypto v0.20.0, mach-tls v0.10.0, mach-quic v0.18.0, mach-http v0.17.0, mach-acme v0.7.0 and laurel v0.16.0. Each is selected by an exact version (`version = "=7.0.2"`) rather than a `tag/` ref, so the root's selection intersects every requirer's range and `mach dep verify` reports no root override, and the resolved release is committed as a gitlink. `test/acme/mach.toml` selects the same releases the same way, and its resolved releases are committed as gitlinks under `test/acme/dep`, so CI pulls them. std 7 makes `io.runtime.make` take the allocator the runtime draws from: the listener hands its runtime the owner's page allocator, and the ACME transport and the TLS wire test client each hold a page allocator beside their runtime, which is what std 6 built internally. std 7.0.2 fixes a runtime-attached `process.events` source that never ended `io.runtime.wait`, the source hedge's listener sees its stop signals through (mach-std#863).
- A record table's chunk is bounded at 2 MiB of record storage (`storage.CHUNK_BYTES`), so the footprint tracks the live count rather than the top chunk (#234). A slab derives its geometry from its record size once: chunks double from 16 records until the next doubling would pass the bound, and every chunk after that holds the bound (128 QUIC connections, 64 HTTP/3 sessions, 256 TLS handshakes, 128 secure sessions per chunk). Before, chunk k held `16 << k` records and a chunk is committed whole (zeroed, or welded and wiped), so at 100k QUIC connections the top chunk alone was 65,536 welded slots, 693 MiB resident from the 65,537th connection with half of it unused until the 131,057th. Now the resident set at N connections is within one chunk of N slots and one grow is one commit of at most 2 MiB. The fixed 32-entry chunk directories are gone with it (`storage.TABLE_CHUNKS` is removed): the slab's per-chunk state and a plain table's chunk pointers are heap arrays that start at 32 entries on the first grow and double, and a secret table's directory is itself welded (`SecretArray[SecretArray[T]]`), because the language refuses a `SecretArray` a home in plain memory. A deployment below the bound sees exactly the growth it did. `test/load/scale.sh` no longer rounds the QUIC counts to chunk boundaries, and its 100k projection is the per-connection cost times 100k with no capacity qualifier.
- Dependency bump: mach-http `^0.16` (v0.16.0) (#248). The request failure log is coded by the engine's closure before the exchange outcome: `connection_closed`, `transport`, `peer_reset`, `local_reset` or `timed_out` when the engine closed the exchange, and `cancelled`, `timed_out` or `failed` from the outcome only when it did not. The record carries `close_code` (the wire's error code) and `transport_error` (the QUIC error for a transport closure), so a request a connection took with it is no longer logged as a caller cancellation. The HTTP/3 session still walks its request slots on a connection failure to settle its own state, but it no longer stands in for the cause.
- The interop lane's shutdown legs gain an HTTP/3 peer holding a request open across the signal: the drain deadline tears the session down on the real QUIC driver, the stop reports the abandoned exchange and no teardown failure (#248).
- The ACME transport runs on the worker's driver and its completions wake the plane (#250, part of #172). `transport.make` no longer creates a runtime and driver of its own: the manager is attached to the worker's `net_async.Driver` and a plane waker at start (`acme.attach_driver`, from the composition), every operation is bound through the new `hedge.operation` module (the routing contract the listener plane uses for served connections, upstream links and now ACME exchanges: an owner and a settle callback per in-flight operation, routed by context kind), and `origination`'s integer `COMPLETION_CONTEXT` is a bound operation too. A response landing on the worker's runtime is one completion that wakes the plane and completes the exchange, where before it was seen at the exchange's deadline. `begin` submits the connect itself, so the exchange is on the wire before it returns. Cancel and finish are states the release advances on completions: `finish` marks the transport releasing, each cancelled transfer lands, the tls engine is released, the socket is closed under a fresh scope, and `destroy` refuses while any of that is outstanding. The `drain(transport, 50)` loops are gone with the private runtime, and with them the measured 3.2 s worst-case stall of the worker during an ACME cancel. An expiring exchange's own cancel lands as an error completion and is settled as a timeout, not a transport fault, and a cancelled read reporting no bytes is not the stream's end. `manager.quiesce` gives up the exchange in flight for the drain and reports PENDING until its release has landed. The `test/acme` harness drives each test transport on its own runtime and dispatches completions to their bound owners, as the worker does.
- The worker sleeps until something happens: every sweep and the fixed poll interval are gone (#182). `serve.poll` waits with no timeout, and the wait ends at the timing wheel's next deadline, a completion, a signal or a wake. Each plane (the proxy links, the ACME manager) reports its earliest deadline through a `PlaneDeadlineFun` the composition registers with `serve.attach_plane_lifecycle`, and the serving loop arms it on the wheel and drives the plane when it fires or when a link completion or a memory release wakes it, rather than on every turn. A proxy link's deadline is its HTTP/1.1 engine's own timeout, an ACME exchange's is its request deadline, and an idle manager's is its renewal time. The TCP runtime keeps the live slots of the current and the previous service generation on two lists, so a reload moves the whole generation in one splice, the superseded count is a field, the drain deadline is one wheel entry, and a slot in teardown is a counter, not a walk before every wait. The QUIC runtime marks a record superseded at the pump swap that superseded it and counts marks and releases, so `superseded` is O(1). `DEFAULT_POLL_MS` is removed. The sweep survives only as a debug-build assertion: every 64th poll turn (counted in turns, never armed on a timer, so it cannot end a wait and hide a missed wake) routes the worker's wakes and walks the live connections of both generations and the QUIC runtime's live records, and a connection that is on no queue yet holds work its next step would do ends the process with a message. That work is a finished connection not yet retired, a pool wake nobody routed, a TLS completion not taken or an operation a free TLS lane could start, a prologue that can be evaluated, bytes the HTTP/1.1 engine holds and has not submitted, a request whose exchange has not started, or a pending service parked on nothing. For a QUIC record it is a datagram held for a handshake turn, a pool wake nobody routed, or a teardown on neither the ready nor the waiting list. Release builds carry none of it.

### Fixed

- A peer that closes an idle HTTP/1.1 keep-alive connection over TLS has it retired as soon as the close is seen (#257). Retiring the connection cancels its engine, and that cancellation queues the engine's transport close on the secure channel, which starts an operation only when driven. The close path drove the channel before the engine queued its close and never after, so the connection waited, with no I/O in flight to wake it, until the keep-alive timeout or shutdown ran its retirement again: the socket sat in CLOSE_WAIT and held its descriptor and its connection record meanwhile. Now closing drives the channel after the engine queues its close and takes what the channel settles, and the close's own completion wakes the connection. Cleartext connections, whose close goes straight to the runtime, and HTTP/2 over TLS were not affected. On the release binary, 100 TLS connections held idle by `test/load/hold.py --tls` and then released left 100 sockets in CLOSE_WAIT and 100 descriptors open for the whole 21 s sampled before, and none 0.2 s after release now. In `test/load/scale.sh` at 200 and 1000 connections the TLS resident set after release falls back as the TCP one does (29.2 MiB at 1000 connections to 20.0 MiB after release, where before it stayed at 29.2 MiB).
- The logged and histogrammed request duration is measured on the monotonic clock (#191). A call is stamped with the monotonic instant it is bound at receipt, and `observe_end` measures from that stamp, so a wall clock step during a request no longer logs a duration of zero (backward step) or the size of the step (forward step). `received_at` on the request metadata stays calendar time for the logged timestamp and for cache age. The other half of #191, the ACME transport deadline, was already moved to the monotonic clock in 0.7.0 (#202): `acme/manager.poll` hands every exchange `clock.instant()` and keeps wall time for the renewal schedule only.

## [0.9.0] - 2026-09-20

The QUIC admission path closes the two gaps a 3000-connection burst exposed on 0.8.0 (#242, #243): the arrival queue never drops a token-bearing Initial while cheaper arrivals are held, and the promotion rule judges a record's remaining time by what a handshake takes to finish, so no handshake is promoted only to expire. Telemetry names both: per-class arrival drops, expiries and the finish estimate.

### Changed

- The QUIC arrival queue is class-aware at its drop site (#242). Under pressure it gives up a duplicate of a datagram it already holds, then a version negotiation, then a first flight the server has not answered, and only then a token-bearing Initial, so a client that has answered a Retry is never the one dropped while cheaper arrivals are held. Before, the queue dropped the newest arrival whatever it was, and under a 3000-connection burst a third to three quarters of the clients had a token Initial dropped and completed only after a PTO step, and a client dropped two or three times arrived past its `handshake_ms` deadline and was refused for lateness the queue had made. `hedge_quic_arrivals_dropped_total` carries a `class` label (`token`, `untoken`, `other`, `duplicate`) in place of the single row, so the built-in series count rises, and `telemetry.metric_series` must cover it. The Initial's token length comes from mach-quic `^0.17` (v0.17.0), which carries it on `ClassifiedDatagram`. `test/load/burst.sh` reports the per-class drop counts and how many clients retransmitted a first flight or a token Initial before admission, counts refusals with drops in its completion check, and asserts token drops are 0. On this box, five consecutive runs: 3000 of 3000 dials complete in 9.1 to 9.5 s, 4517 to 5836 arrivals dropped per run, every one a duplicate the client's PTO sent while its original was held (token 0, untoken 0, other 0), 0 refused. Before, on v0.8.0 in the same cell: 7260 to 13015 dropped per run of which 1812 to 7386 were token Initials, 2912 to 3000 connected, and up to 166 refused for lateness the queue had made.

### Fixed

- The QUIC promotion rule judges an Initial's remaining time by what a handshake takes to finish, not by one crypto unit (#243). The runtime keeps a second running estimate, the wall time from promotion to established (seeded by the first completion, then an EWMA with the same one-eighth step and four-estimate sample cap as the service estimate), and a record with less than that left at its turn is refused, so no handshake is promoted only to spend its crypto and expire on its deadline with the client told nothing. Before, a burst's tail was admitted with tens of milliseconds left and ended neither completed nor refused, and nothing counted it. `hedge_quic_handshakes_expired_total` now counts a promoted handshake that ended on its own deadline, `hedge_quic_handshake_finish_ns` exposes the estimate (the built-in series count is 37), and `test/load/burst.sh` asserts expiries are 0.

## [0.8.0] - 2026-09-19

QUIC handshake admission is bounded and deferred (#164), which closes the two known limits 0.7.0 shipped with: the handshake-burst deadline (#231) and the burst losses (#232). A burst is now drained at read speed, every connection that cannot be served inside its deadline is refused in one RTT rather than started late, and the service rate the rule judges by is a running estimate exposed on the snapshot. The dependency family moves to std 6, and the handshake itself costs about a quarter of what it did on crypto 0.19.

### Added

- QUIC handshake admission is bounded and deferred (#164, closes #231). `server.limits.max_handshakes` (default 256, logged at startup) caps the connections admitted but not yet established; past it a token-bearing Initial waits in the pending queue in arrival order and is promoted one per worker turn as handshakes complete, and the worker does one unit of handshake work per turn. The handshake crypto no longer runs in the receive path: a datagram for a connection mid-handshake, or for an Initial still waiting (routed to it by the connection ID the client was given), is held and delivered on the worker's handshake turn, and the listener reads its sockets between every unit of Retry and handshake work so a burst is drained at read speed rather than at crypto speed. An Initial that could not finish inside its own `handshake_ms` deadline, at the running per-handshake cost (an EWMA over completed handshakes), is refused on arrival or at its turn rather than started late: the server answers with a stateless `CONNECTION_CLOSE(CONNECTION_REFUSED)` under the Initial keys (`quic.listener.refuse`), so the client learns in one RTT rather than after its own timeout. Refusals and drops are separate counters. `server.limits.max_handshakes_per_peer` (absent by default) bounds one address's share. Telemetry gains `hedge_quic_handshakes_in_flight`, `hedge_quic_handshake_service_ns` (the running per-handshake estimate the deadline rule judges by), `hedge_quic_handshakes_{deferred,promoted,completed,dropped,refused}_total` and `hedge_quic_retries_dropped_total`; the built-in series count is 32. `test/load/burst.sh` is the #232 measurement cell: on the release binary a 3000-connection burst leaves the socket drop counter at 0 (before: 75,221), every connection that completes was promoted, and completions match the service rate over the server's handshake deadline (on crypto 0.19: 3000 of 3000 in 9.9 s at 400/s, 7067 arrivals dropped from the hold table, which #242 then classifies).

### Changed

- **Breaking.** Dependencies: mach-std `^6.1` (v6.1.0, was v5.7.0), mach-crypto `^0.19` (v0.19.0, was v0.14.0), mach-tls `^0.9` (v0.9.0, was v0.8.1), mach-quic `^0.16` (v0.16.0, was v0.14.0), mach-http `^0.15` (v0.15.0, was v0.14.0), mach-acme `^0.6` (v0.6.0, was v0.5.0) and laurel `^0.15` (v0.15.0, was v0.14.0), and `mach.toml` requires mach `^5.9`. A consumer must be on std 6.x as well. std 6 reaches hedge in two places: the per-peer admission index is a `map.MapBy` keyed by the seeded address hash, since an `ip.Addr` carries arrays and has no natural hash, and a connection's account opens with a counted `buffers.Budgets`, so an engine that names its own lanes must pass exactly that many and the borrower refuses any other count as misuse. crypto 0.19 runs P-256 on 64-bit Montgomery limbs, so a TLS 1.3 handshake costs about a quarter of what it did. On aarch64 the program turns PSTATE.DIT on before `main` and refuses to start, with status 255, on a processor or kernel without the mode, and CI runs the aarch64 legs with `dit: required`.
- A Retry token is valid for 30 s rather than 10 s. A client accepts one Retry per connection attempt, so a token that expired while its Initial waited, or before the client's PTO retransmission brought it back, stranded that attempt.

### Fixed

- A QUIC handshake still running when the server begins draining is failed at once rather than left to its idle timeout, and a promoted Initial the connection pool refused frees its handshake slot in the same turn instead of blocking every later promotion. Before, a drain with dead handshakes in flight waited on them for the full drain deadline, and one pool refusal under load could stall admission until the deadline refused everything queued behind it.

## [0.7.0] - 2026-09-19

Stage 6 of #169 (#175): an idle connection holds only its protocol state. Every buffer a connection once carried between requests is now borrowed from its worker's pool while bytes are in flight and returned when they are done, the per-stream and per-connection record tables recede to what is actually connected, and the whole reduction is measured on the real binary with a pinned regression guard.

### Added

- `test/load/scale.sh` measures what an idle connection costs on the release binary (#214). For each transport it holds 1000, then 5500, then 10000 connections idle, reads the process's resident set at each step with transparent huge pages disabled, and reports bytes per connection, the two halves of that slope, the address space and mapping count, and the projection to 100k connections. The slope is pinned per transport and a build past the pin by more than 25% fails; CI runs the lane at 200 to 1000 connections. On this release (linux-x86_64): **13,956 bytes per idle TCP connection**, **29,591 per idle TLS connection** (both HTTP/1.1 keep-alive after one served request), and **111,857 per handshake-only QUIC connection**, each linear across the span, projecting to **1.3 GiB, 2.8 GiB and 13.7 GiB at 100k**. The QUIC figure is per welded slot: a secret table wipes a chunk whole when it welds it, so the QUIC counts are taken where every chunk is full and the projection pays for the 131,056 slots 100k connections need. These are the achieved numbers, not the goals in #169 section 4 (1/2/2 KiB), which are not met; the structure is linear and the two largest remaining terms are #234 and #235.
- The scale lane ends with an end-to-end HTTP/3 concurrency check (#220): two throttled requests on one QUIC connection are served at the same time under the default budget, and one after the other under a `connection_memory_bytes` that funds a single request, because hedge advertises only the concurrency its request lane funds.
- `test/load/h3load` holds idle QUIC connections for the scale lane and takes `-dialing N` to bound the handshakes in flight (#214). `test/load/lib.sh` carries what the load lanes share (the generated configuration and credentials, the holders, the HTTP/3 curl), and `hold.py` holds TLS connections with `--tls`.

### Changed

- A QUIC connection's account composes hedge's memory lanes onto mach-quic's supply explicitly (#209, sub-task a). hedge used to hand quic a source advertising only quic's three lanes and silently backfill its own I/O and request lanes inside the account open; on quic v0.14.0's composition contract it now states them directly through `extra_budgets`, `extra_lanes` and `account_handle`. Behaviour is unchanged; this is the boundary the rest of stage 6 sits on.
- An idle HTTP/1 connection holds no response staging buffer (#210, sub-task b). The 8,192-byte staging buffer that lived inline in the connection for its whole life is now borrowed from the I/O lane only while a response body is being serialized and returned when the exchange settles, so an idle keep-alive connection carries none of it. With mach-http's own on-demand read buffer (v0.13.2), an idle HTTP/1 connection now holds only protocol state.
- Handshake buffers are released when the handshake completes (#211, sub-task c). This already held on mach-tls v0.8.1, which returns the handshake input, output, hello and peer-parameter buffers to the TLS lane when hedge destroys the settled handshake write; a regression guard now pins that an established idle connection strands none of them (measured `held = 0`).
- Per-stream HTTP/2 and HTTP/3 state is allocated on demand (#212, sub-task d). Both planes preallocated `MAX_STREAMS` per-stream records inline in the session; each is now borrowed from the request lane when a stream becomes active and released when the stream retires, so an idle connection's memory is independent of how many streams it has served. The HTTP/2 session shrinks from about 167 KiB to about 45 KiB, and about 280 KiB of idle HTTP/3 per-request storage leaves the session. Lane exhaustion refuses just the new stream (`REFUSED_STREAM`, `H3_REQUEST_REJECTED`) rather than failing the connection.
- The request-lane budget is derived, not tuned, so advertised concurrency is always fundable (#219, sub-task d2). Since per-stream state is now borrowed from the request lane, the lane is sized as `max_pipeline_depth × the largest per-stream footprint across every protocol` (`h1_set_bytes`, `h2.set_bytes()`, `h3.set_bytes()`, HTTP/3 binding at about 98 KiB), and advertised HTTP/2 and HTTP/3 concurrency is capped at what that lane funds. hedge can no longer advertise a stream limit it would then refuse.
- Record tables commit chunks as records are claimed and release trailing empty chunks (#213, sub-task e). `src/storage.mach` gains a shared compacting index allocator (the Slab): one index space drawn on by up to `MAX_STORAGES` typed storages that grow and compact in lockstep, a claim taking the lowest free index and the release of a trailing chunk's last live record freeing that chunk and cascading. The connection slots, listener connections, admission peers and leases, the timer wheel, and the QUIC pending-initial and stateless-send tables all migrate onto it, so a table holds chunks in proportion to its live records rather than its high-water mark. Records never move, so a long-lived connection pinned high holds its chunk, which is the correct cost of the raw-pointer contract. Internal storage API changed (`Slab[S1, S2]`, `table_count` renamed to `table_chunks`, a new paired API).
- The secret record tables recede on the same compacting allocator (#222, sub-task e2). The QUIC connection, QUIC handshake, HTTP/3 session and TLS session secret tables, and the secure channel table paired with its session table on one index space, now claim and release through the Slab; a released trailing secret chunk is zeroized and unwelded through `crypto.secret`, not plainly freed. Starting a server with a QUIC listener and no configured `max_connections` allocates no per-connection QUIC storage.
- The per-stream budget is charged against each engine's own footprint (#224). hedge adopts mach-std 5.7.0 and mach-http 0.14.0, whose `stream_footprint` / `request_footprint` functions replace hedge's hand-kept mirror of the engine per-stream chunk list, so the budget tracks the engine rather than restating it. mach-quic moved to v0.14.0 for the composition contract (#207).

### Fixed

- An ACME transfer that completed before its cancel took effect is no longer discarded (#200). Every ACME transport path now accounts the reported bytes before it weighs a cancel or timeout error, and an expired exchange reaps the completion it just cancelled and succeeds when those bytes parse. A finalize response arriving in the same poll as its deadline used to be dropped, restarting the issuance run and spending one of Let's Encrypt's five weekly duplicate certificates, so a repeated race against a slow authority could block renewal for a week.
- `test/acme`'s live drive loops are paced by their wall deadline rather than a round budget (#227, #229). `secure_discover` and its five sibling loops busy-spun a non-blocking poll up to a 400,000-round cap that elapsed in about a second, giving up long before their intended wall deadline; the round cap is removed, the wall deadline is the sole bound, and the loops pace themselves so the async connect gets real time. `origination.failure()` on a channel that never reached TLS now reports OK rather than a spurious internal error.

### Known issues

- A concurrent-handshake burst blows the handshake deadline for a fraction of the connections (#231, present in 0.6.0). A single worker completes about 60 to 110 full handshakes per second (x25519 and P-256), and each connection's TLS handshake deadline is `handshake_ms` (10 s) of wall time, so a burst of about 600 simultaneous handshakes clears too slowly and the connections reached after the deadline are failed: 424 of 600 served, the rest killed after the client's request was already sent. Raising `handshake_ms` to 60 s serves all 600. This is a throughput limit, not a lost-response bug. Faster handshake crypto arrives with the mach-crypto adoption in the next window, #231 is rescoped to refuse a handshake at admission rather than kill it after the request, and multi-core serving (#169 section 5) is the structural fix. The 1100-connection cell in `test/load/run.sh` is this limit's proof and CI skips its served assertion until then.
- A burst of several thousand QUIC handshakes dialled at once loses some to their handshake timeout (#232); holding the handshakes to 64 in flight, all 10,000 complete.

### Tooling

- hedge adopts the family shared release workflow (#204): `cd.yml` runs verify, then full CI, then publish from a `v*` tag push, calling `briar-systems/.github`'s `mach-release.yml`.

## [0.6.0] - 2026-09-18

### Security

- A QUIC datagram that went out whole before its send was cancelled or timed out is now reported as sent (#202). hedge reported it as failed, which refunded its anti-amplification credit and queued its frames again, so an unvalidated peer could draw more than three times what it sent (the rule mach-quic fixed in briar-systems/mach-quic#174).

### Fixed

- An accepted or connected socket now carries the opening number std assigns it, so the driver can tell it apart from a later socket that reuses the descriptor (#171). hedge built these handles from the descriptor alone, which defeated that protection under mach-std 4.
- A connection's socket is only ever closed through the driver that has seen it (#171). When no protocol engine closed it, `connection.close` used to close it directly. The listener now closes it through the driver and returns the slot once the close completes.
- A laurel application's handler timeout is enforced (#171). hedge reads laurel's narrowed deadline after binding a request and times out the exchange scope once a suspended handler is still waiting past it.
- A burst of concurrent HTTP/3 connections no longer leaves the QUIC listener deaf (#145). A connection force-released at its drain deadline skipped the transport's `finish_close` and ignored a refused `assembly.release_closed`, so its slot was reused over a live TLS server and refused every later connection it was given. Each refusal was reported as a runtime failure, which released every QUIC pump and cancelled the pending receive, so the socket was never read again. The forced release now releases the h3 session, finishes the transport's close, destroys the scope and releases the assembly, retrying on later passes until each step completes, and never frees the slot before then.
- A datagram or connection that cannot be handled no longer fails the QUIC runtime (#145). A failed datagram is dropped and a failed connection step is retried or the connection is failed, and both are counted in `quic_runtime.Snapshot` (`datagram_failures`, `connection_failures`). `advance` returns `FAILED` only when a pump can no longer receive.
- TCP connections and QUIC listener sockets close through `net.async` rather than directly (#157). A direct close left any operation the driver still held on a backend resource keyed by the old descriptor, where the next socket to reuse that descriptor would pick it up (briar-systems/mach-std#716). Closing now settles those operations before the descriptor is released. A TCP listener closes through `net.async.submit_listener_close`, new in mach-std v3.3.0, so an accept the driver still holds settles as well.
- A burst of QUIC handshakes no longer loses most of its Retries (#159). A pump held four stateless sends, so a Retry that found them all pending was dropped and its client waited out a timeout: 64 concurrent dials lost 320 of 402 Retries. Stateless sends now grow per pump up to `quic_runtime.MAX_STATELESS_PENDING` (4096) and are released as they complete, and a Retry dropped at that ceiling is counted in `quic_runtime.Snapshot.stateless_dropped`. Bursts of 64 and 200 dials now all connect, in about 1.4 s and 4.6 s, where they connected 56 of 64 and 168 of 200 after 20 s.
- A QUIC connection whose peer left with a response still unacknowledged no longer holds shutdown open (#161). Past its drain deadline the forced release waited for the HTTP/3 session before cancelling the transport, but a request stream only closes once the transport settles it, and with the peer gone and the connection timer off nothing did. The transport is now cancelled first.
- An HTTP/3 request no longer fails about half the time it is served (#202). mach-quic reclaimed a packet-number space's recovery history whenever nothing was tracked in it, without regard for a packet already generated but not yet sent, so a datagram that arrived in that window left the pending send with nowhere to record itself and failed the connection with an internal error. mach-quic v0.13.2 keeps the history while any owner is prepared (briar-systems/mach-quic#190). A stalled HTTP/2 connection whose scope ends mid-drain now reaches its close on its own, following mach-http v0.13.2 (briar-systems/mach-http#123); hedge nudges only a failure that still holds a stream open, which its close releases.
- An HTTP/3 response under many concurrent connections no longer stops short of its last bytes (#163). mach-quic v0.9.3 publishes a send range that crosses a lap of its stream buffer under the right offset, where a range published under the old offset left the next lap unsent and later counted as delivered.

- A budget queue whose head expires now admits the waiters that head was holding back (#181). They used to wait for an unrelated release.
- A connection still making progress at the end of its turn runs again on the next turn (#181). Without this, an HTTP/2 upload over TLS larger than its flow-control window could stall until the request timeout.
- The interop matrix's telemetry leg configures every built-in metric series. It was refused at startup, which stopped the matrix before its remaining legs ran.
- A proxied response body held behind a client's flow-control window no longer spins its connection (#196). The HTTP/1 upstream engine reports the same held bytes on every step, and each report counted as progress, so the connection ran every turn until the window opened. The same held bytes now count as backpressure.
- Every configuration the interop and cache lanes run is built by the loader in the unit suite (#196), so a lane configuration the loader refuses fails `mach test` instead of skipping lane legs.

### Added

- Connection memory comes from one buffer pool per worker (#202). Each connection, TCP or QUIC, opens an account on its worker's pool and borrows TLS records, read and write buffers and per-request memory from it, instead of carrying fixed arrays. An idle HTTP/1.1 connection holds no buffer. `server.limits.memory_bytes` bounds the pool and `server.limits.connection_memory_bytes` bounds one connection. Both default from the other limits and are validated at load. The budget splits into TLS, I/O and request lanes (see Connection memory in `doc/CONFIGURATION.md`).
- Admission refuses a connection the pool cannot fund, keeping an eighth of the pool as headroom for connections already open (#202). A refused TCP connection is closed and counted in `hedge_connections_refused_memory_total`. A refused QUIC Initial is dropped. An open HTTP/2 connection refuses a new stream with REFUSED_STREAM, and HTTP/3 with REQUEST_REJECTED.
- A connection waiting for memory longer than `server.timeouts.header_ms` is closed (#202). Shedding under pressure is deliberate: it keeps the pool for connections that can finish. `hedge_memory_held_bytes`, `hedge_memory_refusals_total` and `hedge_memory_timeouts_total` report each lane.
- `hedge.timer`, a hierarchical timing wheel that will hold every deadline hedge decides (#179, part of #172). It has four levels of 256 one-millisecond slots, covering about 49 days. Entries are intrusive, live in a chunked table and never move, and each level keeps an occupancy bitmap, so arming, disarming and finding the next deadline are constant time. Deadlines are monotonic and round up to the next tick, so nothing fires early. With 100,000 armed entries a re-arm costs 70–100 ns, or about 25 ns when the deadline stays in its slot, against about 2,000 ns for a std io timer's cancel and resubmit.
- `max_retry_replay` on a QUIC `[[listener]]` bounds the Retry nonces its replay store remembers, 65536 by default (#171). mach-quic 0.11 requires the bound. A Retry-token Initial that arrives while the store is full is dropped. Those drops count in `hedge_quic_retry_replay_full_total` and in `quic_runtime.Snapshot.replay_full`.
- QUIC listeners size their UDP socket buffers (#153). `receive_buffer_bytes` and `send_buffer_bytes` on a `[[listener]]` set them, and an absent value asks for 4 MiB to receive and 1 MiB to send rather than the kernel default that a handshake burst overflowed. The size the kernel granted is read back and logged at startup next to the request, since Linux doubles and caps it. The keys are refused on TCP and local listeners, and changing them needs a restart.

### Changed

- **Breaking.** Dependencies move to the mach-std 5 stack (#202): mach-std v5.4.0, mach-crypto v0.13.2, mach-tls v0.8.1, mach-quic v0.13.2, mach-http v0.13.2, mach-acme v0.5.0 and laurel v0.14.0, with `mach = "^5.3"`. Both `mach.toml` and `test/acme/mach.toml` pin mach-std v5.4.0, and `test/acme/mach.toml` also pins mach-http and mach-quic v0.13.2 to override the older selectors mach-acme and laurel carry.
- Every deadline hedge schedules is a monotonic `time.Instant` (#202). Cancel scopes take an optional deadline, and budgets, the drain sequence, dispatch waits, request deadlines, proxy attempts and upstream breakers all run on the monotonic clock. Calendar time is read only for dates, cache freshness and certificate validity. TLS reads both clocks through its policy's clock source, so hedge hands TLS and QUIC no verification time.
- HTTP/2 connection deadlines are the engine's own on mach-http 0.13 (#202). The adapter's stopgap from #189 is gone. `header_ms`, `request_ms`, `keep_alive_ms` and `write_ms` reach the HTTP/2 engine, which also closes every HTTP/2 connection at its total timeout (300 s), as HTTP/1.1 already did. A stalled HTTP/2 stream is reset on its own, and a failed HTTP/2 connection releases every stream's memory when it closes, including streams hedge never saw.
- An HTTP/1.1 connection that has no request in hand and nothing read closes at `header_ms`, following mach-http 0.13 (#202). That covers a client that goes quiet after its TLS handshake, and a connection blocked on memory, which counts as a memory timeout. A quiet keep-alive connection is still bounded by `keep_alive_ms`.
- TLS reads and writes run concurrently on mach-tls 0.8 (#202). The read preemption from 0.5.3 (#196) is removed. A queued write no longer waits behind a read.
- **Breaking.** `telemetry.metric_series` must cover 23 built-in series, up from six, for `hedge_quic_retry_replay_full_total` and the per-lane memory series.
- **Breaking.** `connection.make` takes the worker's `hedge.memory.Memory`, `proxy.attach_driver` takes the pool and the connection budgets, `quic_runtime.RuntimeConfig` takes `memory`, and `quic_runtime.advance` no longer takes a wall time. `serve.PlaneFun` and `serve.PlaneQuiesceFun` take a monotonic `time.Instant`. A laurel test site takes `handler_timeout` as an optional duration, following laurel 0.14.
- The QUIC runtime runs only the connections that have work (#180, part of #172). A settled completion, a fired timer or a state change marks its connection ready, and `advance` services only the ready list, in arrival order. QUIC transport and drain deadlines live in the serving runtime's timing wheel, which also sets the poll timeout, and `hedge.protocol.quic.timers` is removed. 100 held idle HTTP/3 connections cost about 2% CPU, down from 66%. A connection with a teardown step that waits on nothing that wakes it is still visited every turn until #182.
- TCP connections run only when something happened to them (#181, part of #172). Each worker has a wake queue of tagged owners (`hedge.wake`) and a ready queue, and every connection deadline (prologue, request, HTTP/1.1 and HTTP/2 timeouts, a service's wait) is an entry in the worker's timing wheel. The per-turn sweep over every connection is gone. With release builds, 4000 idle HTTP/1.1 keep-alive connections cost 0.2% CPU, down from 2.1%. 2000 idle TLS connections cost 0.2%, down from 1.6%. Measured as the server process's CPU over 10 s after every connection was held.
- A service that reports `SERVICE_PENDING` must say what it waits on with `call.park` (a body, a wake, a deadline) or ask for another turn with `call.yield_turn`, and dispatch fails a pending service that does neither (#181). Budget waiters form a FIFO queue on their budget, and a release wakes the waiter it admits. The proxy wakes the request waiting on an upstream link when that link moves. An HTTP/3 connection with a request in service waits for that request's wake or deadline instead of running every turn, and a queued QUIC initial waits for its budget's wake or its queue deadline. A pending service is still re-entered on any event its connection has (#131).
- **Breaking.** `call.bind`, `budget.charge`, `dispatch.admit`, `connection.make`, `h2.begin` and the HTTP/3 `session.begin` take a `hedge.wake.Waker`. `quic_runtime.RuntimeConfig` takes the worker's `wakes`. `quic_runtime.next_budget_deadline` is removed, `quic_runtime.wake` and `owns` are new, and `budget.relocate` is the only way to move a queued charge.
- **Breaking.** `quic_runtime.RuntimeConfig` takes the worker's `timers`, `quic_runtime.next_deadline` is removed in favour of the wheel's, and `quic_runtime.fire`, `owns_timer` and `has_ready` are new. `quic_runtime.Snapshot.timers` counts armed wheel entries.
- hedge is copyright Briar Systems LLC (#184). The MIT license terms are unchanged.
- **Breaking.** Dependencies move to the mach-std 4 stack (#171): mach-std v4.2.0, mach-crypto v0.12.0, mach-tls v0.5.1, mach-quic v0.11.0, mach-http v0.11.0, mach-acme v0.4.2 and laurel v0.13.3. Both `mach.toml` and `test/acme/mach.toml` carry the std and crypto pins (#171, #186). Errors hedge raises itself now name their kind (`io_error.make`), as std 4 requires. `listener.apply_stream_policy` takes a socket handle rather than a raw descriptor. `connection.stream_released` reports whether the driver has taken a connection's socket. `quic_runtime.PumpConfig.max_replay` is required.
- **Breaking.** `quic_runtime.STATELESS_SENDS` and `quic_capacity.STATELESS_SENDS` are replaced by `MAX_STATELESS_PENDING`, a ceiling rather than a pool size, and `operation_capacity_required` counts one operation per pump (#159).
- mach-quic no longer enforces the TLS handshake deadline once the handshake is complete, so an HTTP/3 connection that outlives `handshake_ms` (a slow reader, or any long transfer) is no longer failed at that moment (#145). mach-quic v0.9.2 no longer fails a connection whose MTU probe is acknowledged after its congestion window has grown past ten datagrams, and a connection that fails while settling acknowledgements can still finish closing, so hedge's shutdown completes after a burst of handshakes (#161). mach-acme v0.3.0 keeps its store owner-only on Windows (#149).

### Known issues

- A burst of QUIC handshakes larger than the server can complete within its clients' timeouts collapses (#164). With 1100 clients dialling at once, about half connect. The same 1100 arriving at 40 per second almost all connect. Bursts of 200 connect in under 5 seconds.
- hedge builds for `windows-x86_64` but is not supported at runtime on Windows (#149). The CI leg for Windows is build-only until that is fixed.
- The TLS stall fix merged from 0.5.2 (#189) is bounded by the timing wheel, not by a deadline carried on std's cancel scope. A TLS operation runs under the scope of the protocol engine that asked for it, and that engine's own deadline (keep-alive, header, request or write) is an entry in the worker's wheel, which times the scope out when it passes.

## [0.5.3] - 2026-09-17

### Fixed

- A proxied response body only reached the client over cleartext HTTP/1.1 (#196). Two causes.
  - Over TLS the connection had already started a read for its next request when a late response became ready, and the TLS channel runs one operation at a time, so the response waited behind a read that only the client could end. HTTP/1.1 stopped after its first 8192 bytes and HTTP/2 never sent the body. A write queued behind a read now cancels that read through its own operation scope, the writes run, and the read starts again unseen by the engine, keeping every byte it had already received. A write is never cancelled this way.
  - HTTP/2 and HTTP/3 carry field names in lowercase only, and the engines refuse anything else. An upstream's `Content-Type` or `Last-Modified` was passed through as written, so the response was refused and the request logged as `cancelled`. hedge now lowers every name it sends on those protocols, headers and trailers alike, and refuses a list it cannot lower rather than truncating it.
- The interop lane now proxies a 156000-byte body over TLS HTTP/1.1, HTTP/2 and HTTP/3 and compares it byte for byte.

## [0.5.2] - 2026-09-17

### Security

- Timeouts were never enforced on a TLS listener once a client had sent its first byte (#189). The TLS adapter ran every TLS operation under a scope root of its own, detached from the connection, so an engine timeout never reached the TLS read in flight, and the handshake ran with no deadline at all. A client that sent part of a ClientHello, finished the handshake and went silent, sent part of a request, or sat idle after a response kept its connection slot, admission lease and descriptor indefinitely. The TLS session now descends from the connection's scope, each engine operation runs under the scope the engine submitted it with, and the handshake runs under the prologue scope that carries `timeouts.handshake_ms`.
- HTTP/2 connections had no connection timeouts (#189). mach-http's HTTP/2 engine has no timeout support, so `header_ms`, `keep_alive_ms` and `write_ms` never applied to HTTP/2. As a stopgap, hedge's HTTP/2 adapter now enforces them itself: `header_ms` until the first request, `keep_alive_ms` while no stream is open, and `write_ms` while a write is pending. The real fix belongs in the engine (briar-systems/mach-http#110), and the stopgap is removed once that lands.
- Mutual TLS was completely broken in 0.5.1 (#190). #168 moved the connection's clock to monotonic time, and the TLS verification time was still derived from it, so client certificates were checked against seconds since boot and every one was refused as expired. The same value drove session ticket key rotation, against a key ring initialised in wall time, so ticket keys never rotated in 0.5.1. Every time hedge hands mach-tls now comes from the wall clock, and the call sites say so. Ticket keys and the replay window live only in memory and are minted fresh in each process, so no ticket survives a restart, whatever the clock. That is why there is no restart test.

Measured with release builds and the default timeouts (`handshake_ms` 10000, `header_ms` 10000, `keep_alive_ms` 75000, `write_ms` 30000). Each probe waited 100 s. The 0.5.1 column is from the #189 report.

| client behaviour over TLS | 0.5.1 | dev before this fix | 0.5.2 |
|---|---|---|---|
| half a ClientHello | still open | still open | closed at 10.0 s |
| full ClientHello, never finishes the handshake | still open | still open | closed at 10.0 s |
| HTTP/1.1: silent after the handshake | still open | still open | closed at 75.1 s |
| HTTP/1.1: partial request header | still open | still open | closed at 10.1 s |
| HTTP/1.1: idle after a response | still open | still open | closed at 75.1 s |
| HTTP/2: silent after the handshake | still open | still open | closed at 10.0 s |
| HTTP/2: preface only | still open | still open | closed at 10.0 s |
| HTTP/2: stalls inside HEADERS | still open | still open | closed at 10.0 s |
| HTTP/2: header block that never ends | still open | still open | closed at 10.0 s |
| HTTP/2: idle after a response | still open | still open | closed at 75.1 s |
| HTTP/1.1: stops reading a 12 MB response | | still open | closed at 30.2 s |
| HTTP/2: stops reading a 12 MB response, with a large flow-control window | | still open | closed at 31.2 s |

A client that stops reading a response is covered by `write_ms` on both protocols. An HTTP/1.1 connection that has sent no request byte yet is idle, so `keep_alive_ms` bounds it rather than `header_ms`, which starts at a request's first byte. The HTTP/2 stopgap applies `header_ms` until the first request.

### Fixed

- Stopping hedge could hang forever on a TLS connection waiting for its next request (#192). The engine's read sat in the TLS adapter's queue, not yet started, and a closing connection never started or failed it, so the connection could not be torn down. A 0.5.1 server with one idle TLS keep-alive client was still running 40 s after SIGTERM. The adapter now settles a queued operation as cancelled or timed out once its scope has ended, without starting it.
- An HTTP/2 connection that failed with a stream the adapter had not yet opened could not be torn down (#189). The adapter now releases such streams before it destroys the engine.

## [0.5.1] - 2026-09-17

### Security

- A client that opened a TCP connection and then sent nothing was never disconnected (#168). The deadline meant to close it after `timeouts.handshake_ms`, which also bounds the TLS handshake, was computed from the wall clock, but hedge's I/O layer enforces deadlines against the monotonic clock, so the deadline was always decades away. Any client could hold connection slots, admission leases and descriptors open indefinitely by connecting and staying silent, on cleartext and TLS listeners alike. Every deadline hedge builds now comes from the monotonic clock. Wall time is used only for calendar purposes: `Date` headers, certificate validity, cache freshness and request timestamps.

### Fixed

- An HTTP/2 request whose handler never completes is reset when `timeouts.request_ms` passes (#168). The stream's deadline was never checked, because a handler that submits no I/O gives the I/O layer nothing to time out.

## [0.5.0] - 2026-09-16

### Changed

- **Breaking.** `server.limits.max_connections` is optional and absent by default, and both it and `max_connections_per_peer` are reloadable (#111, #113). Absent means no cap on any transport: connection storage grows with what is actually connected and the ceiling is the descriptor table and what the allocator will give. Present means a policy cap, applies to every transport, and admission refuses past it exactly as the preallocated pool did. Zero is a configuration error rather than a spelling of no limit. `plan.reload_compatible` no longer treats either limit as startup-owned, since neither sizes any storage.
- **Breaking.** `schema.Limits.max_connections` and `max_connections_per_peer` are `opt[usize]`, and `reset_graph` leaves the global limit absent where it defaulted to 10000. The per-peer default is unchanged at 100.
- The TCP connection pool grows on demand (#113). `listener.Owner` holds its connections in a chunked directory and `serve` holds its slots in another; a record never moves once handed out, so io completion contexts, cancel scopes and body readers keep their pointers. Each `connection.Connection` is claimed from a recycler as a peer is admitted and returned when it retires, so a 106 KiB record exists per live connection rather than per configured one. Starting a server allocates four times where it allocated six, and an idle listener holds no connection storage at all.
- `hedge.admission` grows its peer and lease tables and finds a peer through a hash index seeded once per process, rather than scanning to a preallocated capacity (#113). `make` takes an allocator and `opt[usize]` limits, `retune` moves them, and `destroy` releases what was grown.
- The QUIC connection pools grow on demand (#138). `quic_runtime.ConnectionStorage` (589 KiB) and `h3_session.SessionStorage` (938 KiB) are claimed from recyclers as a connection and its session are taken and returned when they retire, so an idle QUIC listener no longer reserves about 1.5 GiB of address space. `quic_runtime.Connection`, `assembly.SecretStorage` and `h3_session.Session` live in `hedge.storage.SecretTable`s that the runtime grows through `quic_runtime.ControlView`, and a record never moves once its chunk exists. The routing table owns its entries and rehashes into a larger array as it fills, and the timer queue grows its heap and per-slot positions, so neither sentinel depends on a capacity any more. Pending initials grow the same way, and a QUIC runtime's storage is released when it is.
- **Breaking.** `composition.DEFAULT_QUIC_POOL`, `quic_pool_size` and `quic_capacity_required` are removed. `composition.quic_required` says whether a graph needs the QUIC controls, and `make_controls` takes no capacity. `quic_runtime.Storage`, `make_storage`, `route_capacity_required`, `ROUTE_TABLE_LOAD` and `ROUTES_PER_CONNECTION` are removed, `quic_runtime.make` takes only the view and a `RuntimeConfig` of allocator and chunks, and `PumpConfig.connection_limit` and `max_connections_per_peer` are the configured `opt[usize]` limits. `routing.make`, `timers.make` and `h3_session.make_pool` take an allocator in place of caller arrays.
- **Breaking.** `serve.make` no longer takes a pool size or caller-provided slot and connection arrays, which it no longer needs. `serve.slot_at`, `serve.slot_connection` and `serve.last_refusal` expose what a caller used to read out of those arrays; the refusal reason in particular has to be published on retirement now that the record it lived in goes back to the pool.
- `test/load/run.sh` and `doc/bench/run.sh` drop their `max_connections` settings. Both keep `max_connections_per_peer`, which the whole load coming from one address still needs.
- `hedge.service.laurel` resumes a suspended laurel request instead of re-running it (#116). `RequestState` gains laurel's `middleware.Execution`, a pending execution is reported as `SERVICE_PENDING`, and re-entry calls `app.resume` rather than dispatching, binding and executing a second time. The handler is entered once however many reads its body takes.
- The laurel adapter calls `app.abandon` before releasing a context whose execution is still suspended, so a connection that dies mid-suspension still runs every middleware exit half that is owed and cannot leak an admission slot (#116).
- `test/acme` declares `mach-crypto` itself, as it already declares `mach-std`. laurel reaches crypto with a different selection than hedge's other dependencies, and hedge's own root declaration cannot settle a graph where hedge is not the root (#116).
- Dependencies: mach-std v3.2.0, mach-quic v0.8.1, laurel v0.11.0 and mach-crypto v0.9.2, in `mach.toml`, with std and crypto also in `test/acme/mach.toml`, which is the root of its own graph.
  - mach-std: `io.runtime.wait` now collects native readiness on every call, so one connection streaming a response no longer keeps any other socket's readiness from being collected. Concurrent TLS connections are served evenly rather than starved (#122, briar-systems/mach-std#658). The io runtime's slot, completion, timer and source tables grow on demand, so `RESOURCE_EXHAUSTED` means the allocator refused rather than that a configured size was reached, and the linux completion index widened past its 65535 ceiling (briar-systems/mach-std#653). `io.runtime.wait` now returns early only on a timeout or a caller's wake. hedge never wakes a runtime and every wait loops, so nothing depends on that change. v3.2.0 also makes owner-only file modes hold on Windows.
  - mach-quic: QUIC admission, token and listener storage takes an allocator in place of caller-sized tables, so hedge no longer preallocates four arrays of `max_connections` entries per pump bank (briar-systems/mach-quic#100). mach-quic now sizes packets by the validated path MTU, arms a timer for pacing delays, delivers a 1-RTT packet coalesced behind the handshake's Finished, accepts clients with an empty source connection id, follows a peer's key update before acknowledging it, and takes datagrams up to 1500 bytes by default, which matches hedge's pump buffers (#140). Sequential, first-request and single-transfer HTTP/3 stalls are gone (#145).
  - laurel: its handler and middleware signatures changed in v0.11.0: a middleware is now a `before`/`resume`/`after` triple, and a handler returns `handler.Result` (#116).

### Added

- CI runs on the family pipeline, `briar-systems/.github` `mach-lib.yml` with a `gate` job (#147). Pull requests into `dev` run `x86_64-linux`, including `test/acme` against the live ACME stack and the load lane. Pull requests into `main` and dispatches add native `aarch64-linux`, `aarch64-darwin`, `x86_64-darwin`, and `x86_64-windows`, which is build-only (#149). CI no longer runs on push, and the tree is formatted with `mach fmt`.
- `call.finalizer_state`: the service that attached a call's finalizer reclaims the per-exchange state it owns when the call is entered again, so a service that reports itself pending needs no registry of its own (#116).
- `test/load/`, a harness that holds 256 connections open against the real executable and requires every one of them to be served, wired into CI here because it only passes once the mach-std pin has moved. Cleartext runs beside TLS as the control (#122).
- `test/load/` QUIC cells (#138). One server with no limit has to serve 1100 concurrent HTTP/3 connections, and a server capped at 48 has to admit QUIC to exactly what 32 held TCP connections leave, refuse the rest, and then refuse TCP while QUIC holds its share. Five small bodies are also fetched over HTTP/3 one connection at a time, which is the check that stops a change that breaks HTTP/3 outright. The served cells under load do not pass yet (#145), so CI runs the lane with `LOAD_QUIC_SERVED=0`. `test/load/h3load` is a quic-go client for the same cells, run by hand for now.
- `cache: a response is stored when its client stops writing before the answer` constructs the two-completions-in-one-wait pairing rather than waiting for the runtime to produce it, by half-closing the client before the server answers, so it guards the fixes below at any mach-std pin (#133).

### Fixed

- A proxy link that received its whole response is returned to the idle pool even when the client goes away in the same turn the last of that response arrived (#133). The link settles what it already holds before its reusability is judged, and reusability is read from the upstream rather than from how the downstream exchange ended.
- A connection arriving while a finished one is still being torn down waits for its slot instead of being refused, and a poll retires what finished before it admits what arrived (#133). A pool full of live connections still refuses, which is what `max_connections` means; a pool holding a slot open for a teardown does not.
- A connection advances its engine after every completion it settles, not only when the settlement itself reported progress (#133). Two completions for one connection arrive together whenever both are ready at the same native collect, and the second was being applied to an engine that had never been advanced past the first, which discarded a finished response.
- A QUIC connection cancelled on its first delivery, or while its routes and timer were first published, starts its close and is released at the drain deadline (#141). It used to stay cancelling for the life of the process, holding its slot and admission lease, and it kept SIGTERM from ever stopping the server.

### Known issues

- HTTP/3 does not yet hold up under concurrency (#145). With 200 concurrent connections from one client, about half of the QUIC handshakes never complete. A transfer to a client that reads slowly can stop part-way and not resume. Single connections and sequential requests are served, over curl and quic-go alike. A server that has to carry many concurrent HTTP/3 clients should not rely on this release for it.
- hedge builds for `windows-x86_64` but is not supported at runtime on Windows (#149). Its tests fail there, in the ACME store and transport, the cache store, static directories and connection draining. The CI leg for Windows is build-only until that is fixed.

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
