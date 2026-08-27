# Roadmap

The roadmap is ordered by dependency and validation, not by declaring production capabilities impractical. The complete target includes portable operation, every current HTTP version, native TLS, QUIC, ACME, proxying, caching, static files, and production Mach applications.

Every phase ends with executable tests and an explicit compatibility gate. Later phases may begin when their contracts are stable enough to consume, but no product release claims a capability whose gate is open.

## 0. Toolchain trust

- close or quarantine applicable compiler optimizer, ABI, frame, register allocation, linker, and target findings
- define release build cells for every supported target
- validate artifact properties and reproducibility
- add compiler regressions derived from protocol and crypto workloads
- provide a supported optimization policy for constant-time code

Gate: protocol and crypto test artifacts produce identical specified behavior in debug and release profiles on native target runners.

## 1. Runtime foundations

- land the `mach-std` requirements tracked in this repository
- define native resource handles and normalized errors
- implement operation completion, timers, cancellation, and wakeups
- implement sleeping synchronization and bounded queues
- implement portable process lifecycle and graceful interruption
- provide dual-stack TCP and UDP with production socket options
- provide asynchronous file operations or compatible worker integration

Gate: native TCP and UDP suites pass under fragmentation, cancellation, timeout, reset, exhaustion, and sustained concurrency on Linux, Darwin, and Windows.

## 2. Bounded byte and protocol foundations

- implement checked cursors, builders, varints, and bounded field collections
- define streaming reader and writer ownership
- implement deterministic allocation-failure injection
- establish protocol corpus and differential-test harnesses

Gate: no parser reads or writes outside the supplied region across generated fragmentation and failure cases.

## 3. Cryptography

- implement MAC and KDF families
- implement AES-GCM and ChaCha20-Poly1305
- implement P-256 and X25519 key agreement
- implement required signature schemes and encodings
- validate against official and independent vectors
- inspect constant-time lowering on every supported target
- establish secret lifecycle and zeroization tests

Gate: algorithm vectors, cross-implementation differential tests, invalid-input suites, and generated-code checks pass for every release target.

## 4. TLS

- implement TLS 1.3 records and handshakes
- implement certificate authentication, SNI, ALPN, resumption, and key updates
- implement TLS 1.2 for configured compatibility policies
- implement server and client roles
- implement certificate and private-key loading, selection, and rotation
- implement session storage boundaries and replay policy

Gate: complete interoperability matrix with major clients and servers, malformed-handshake corpus, long-session key update, resumption, rotation, and failure-injection coverage.

## 5. HTTP/1.1

- implement strict incremental parsing and serialization
- implement framing, persistence, pipelining, informational responses, trailers, and upgrades
- implement bounded client and server connection engines
- implement request-smuggling corpus and differential tests

Gate: RFC conformance, parser fragmentation, hostile framing, proxy-chain, and sustained keep-alive suites pass.

## 6. HTTP/2

- implement frames and connection preface
- implement HPACK with bounded dynamic tables
- implement streams, priorities, flow control, settings, ping, and GOAWAY
- integrate common HTTP service exchanges

Gate: conformance, compression adversarial cases, flow-control deadlock checks, cancellation, and interoperability suites pass.

## 7. QUIC and HTTP/3

- implement QUIC packet protection, transport state, recovery, congestion control, migration, and streams
- implement HTTP/3 framing and QPACK
- implement control streams, settings, cancellation, and graceful close
- validate NAT rebinding, loss, reordering, duplication, path changes, and amplification limits

Gate: protocol conformance, simulated network fault matrix, interoperability, and sustained multi-stream load suites pass.

## 8. Hedge serving product

- implement configuration and atomic reload generations
- implement multi-protocol listeners and virtual hosts
- implement static files, ranges, conditional requests, and compression
- implement reverse proxying, health checks, pools, retries, and circuit breaking
- implement optional memory and disk caching
- implement structured logs, metrics, traces, health, readiness, and administration
- implement process service integration and safe upgrade procedures

Gate: configuration rollback, zero-downtime reload, graceful drain, privilege boundary, resource exhaustion, and multi-day soak suites pass.

## 9. ACME

- implement account and order lifecycle
- implement HTTP-01, DNS-01 provider contracts, and TLS-ALPN-01
- implement durable state, renewal, backoff, and alternate chains
- integrate certificate generations without connection interruption

Gate: ACME staging environments, failure recovery, clock skew, account rollover, and certificate rotation suites pass.

## 10. Mach Web

- implement application composition and typed request context
- implement routing, middleware, errors, sessions, forms, multipart input, and rendering
- implement security defaults and explicit override policy
- implement test clients, fixtures, and application observability
- implement background service and graceful application lifecycle contracts

Gate: framework security corpus, handler cancellation, session rotation, upload exhaustion, middleware ordering, and end-to-end application suites pass under all HTTP versions.

## 11. Production qualification

- publish supported platform and protocol matrices
- establish release signing and provenance
- run independent protocol and cryptographic review
- run performance, fault, leak, and recovery campaigns
- exercise backup, restore, certificate recovery, and rollback procedures
- publish security response and compatibility policies

Gate: a release candidate operates a real public website through sustained traffic while all defined production evidence remains green.

