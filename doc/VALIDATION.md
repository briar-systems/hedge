# Validation strategy

## Test layers

### Unit tests

Pure state transitions, encodings, limits, arithmetic, routing, and policy decisions have local deterministic tests.

### Fragmentation tests

Every streaming parser and serializer is exercised with input and output split at every byte boundary, including multiple consecutive empty or partial completions where the transport permits them.

### Conformance tests

Normative protocol requirements map to named cases with specification references. Generated cases cover valid and invalid state transitions.

### Differential tests

Wire parsers, serializers, cryptographic algorithms, TLS handshakes, and compression are compared against independent implementations. A difference is investigated rather than normalized away.

### Fuzz tests

`test/fuzz` answers every untrusted-input entry point: the PROXY header, the prologue and cleartext protocol selection, ACME wire responses, destination CID routing and the QUIC runtime's arrival, stateless and held-datagram queues, HTTP/2 and HTTP/3 request headers, dispatch, forwarding, trace context, administration auth, the HTTP semantics headers, static paths and media types, the ACME challenge path, and the config loader, trusted peers, anchor bundles and ACME durable state. Each boundary has a harness and a directory of retained inputs in `test/fuzz/corpus`. The property is that no byte sequence a peer, an upstream or a file can send crashes an entry point, reads past its input, loops, or is accepted or refused against what it promises:

- every input is parsed or refused as its entry point says it will, and every view a parse publishes lies inside the input or the storage it was copied into
- each input ends on the last byte before an unreadable page, so a read one byte past it faults
- each harness checks its entry point's promise: a round trip, a comparison law, a model of the RFC or of the state the runtime must hold

The replay is deterministic and runs in both profiles on the heavy tier (a pull request into `main`, or a dispatch with `heavy: fuzz` or `heavy: all`). The lane is built on every pull request so it cannot rot. `fuzz mutate` is the on-demand search: a seeded structural mutator over a boundary's corpus that writes findings and, with `--retain`, adds a minimized input for each outcome the corpus does not hold yet. It is not coverage-guided: no coverage instrumentation exists for Mach, so the search will not find a path that needs a specific constant to reach. [`test/fuzz/README.md`](../test/fuzz/README.md) has the commands.

### Fault injection

Tests inject allocation failure, short I/O, cancellation, timeout, reset, disk-full, descriptor exhaustion, unavailable entropy, clock changes, packet loss, reordering, duplication, and stale configuration generations.

Telemetry fault cases include sink failure, full-queue rejection and dropping, structured-record injection, series-cardinality exhaustion, administration response exhaustion, authentication failure, and shutdown flush failure. Tests assert the externally visible status and the accounting counters for each outcome.

### Interoperability tests

Client and server matrices cover major HTTP, TLS, QUIC, and ACME implementations. Results record version and configuration so changes are attributable.

### Load and soak tests

Workloads combine:

- many idle connections
- handshake bursts
- small dynamic requests
- large streaming bodies
- slow request and response peers
- HTTP/2 and HTTP/3 stream concurrency
- lossy and reordered QUIC paths
- static file ranges and conditional requests
- cache churn
- unhealthy and recovering upstreams
- reload and certificate rotation during traffic

Soak tests track memory, handles, threads, queue depth, timers, cache size, connection state, latency, errors, and telemetry loss.

## Native target evidence

Linux, Darwin, and Windows execute native runtime and protocol suites. Cross-compilation is additional evidence, not a substitute.

Generated binaries are inspected for target format, relocation policy, executable stack state, unwind information, imported libraries, and hardening flags.

## Failure artifacts

Every randomized failure records a seed, minimized input, configuration, target tuple, profile, compiler revision, and dependency revisions. Reproduction requires no external service unless the case is explicitly an interoperability test.

## Production canary

The final qualification stage serves a real public site with controlled canary traffic. Automated rollback watches correctness, crash, resource, certificate, and latency signals. Canary success supplements the test program and never replaces it.
