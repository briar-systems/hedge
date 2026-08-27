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

Coverage-guided harnesses target parsers, state machines, configuration, certificates, compression, routing, and cross-layer protocol transitions. Seed corpora include standards examples, historical vulnerabilities, and minimized failures.

### Fault injection

Tests inject allocation failure, short I/O, cancellation, timeout, reset, disk-full, descriptor exhaustion, unavailable entropy, clock changes, packet loss, reordering, duplication, and stale configuration generations.

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

