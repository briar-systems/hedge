# Production requirements

Production grade is an evidence standard. A feature is production grade only when its implementation, failure behavior, observability, and operational recovery are validated together.

## Correctness

- protocol behavior is derived from normative specifications
- ambiguous or invalid wire input has one documented outcome
- state transitions are total for every parsed input and completion result
- partial I/O is ordinary behavior
- integer conversions, lengths, offsets, and counters are checked
- cancellation resolves every owned resource exactly once
- debug and release behavior are equivalent except for diagnostics and performance

## Security

- every attacker-controlled dimension has a configurable bound and a safe default
- request framing rejects ambiguity
- route and file path normalization cannot escape configured roots
- headers, cookies, forms, and multipart input have independent bounds
- TLS rejects downgrade, transcript, extension, signature, certificate, and record violations
- QUIC enforces amplification and address-validation rules
- secrets have explicit creation, access, rotation, and destruction paths
- administrative interfaces use separate listeners and authentication policy
- defaults do not expose diagnostic data or directory contents

## Reliability

- listener failure does not corrupt active connections
- configuration reload is atomic
- old runtime generations drain independently
- overload produces bounded refusal, not unbounded memory or thread growth
- upstream failure respects retry safety and request deadlines
- telemetry failure cannot block request progress indefinitely
- disk-full, descriptor exhaustion, memory exhaustion, and clock changes have defined behavior
- restart and rollback preserve certificate and ACME state

## Performance

- every request path has an allocation profile
- streaming paths remain bounded by configured buffers
- backpressure reaches the source of produced data
- idle connections do not wake the process without a timer or network event
- locks do not span blocking I/O
- protocol compression tables and caches obey exact memory budgets
- latency, throughput, memory, CPU, and wakeups are measured together

No single benchmark becomes the architecture. Performance evidence includes small and large bodies, many idle connections, slow peers, high concurrency, packet loss, TLS handshakes, cache behavior, and application work.

## Portability

Each supported target has native CI and release evidence. A platform is not supported because its source compiles elsewhere.

Target evidence includes:

- native protocol tests
- native cancellation and timeout tests
- native resource exhaustion tests
- generated-code and executable-format validation
- service installation and shutdown
- certificate store and file permission behavior
- long-running leak and concurrency tests

## Operations

Hedge provides:

- structured access and error logs
- counters, gauges, and histograms with bounded label cardinality
- distributed trace propagation and server spans
- liveness and readiness with distinct semantics
- configuration validation without activation
- atomic reload with an observable result
- graceful drain with progress and deadline reporting
- machine-readable build, version, and capability information
- administrative state that does not share the public request route graph

## Compatibility

Every release publishes:

- supported operating systems and architectures
- HTTP and TLS versions
- cipher suites, groups, and signature schemes
- QUIC versions
- configuration compatibility policy
- state-file compatibility policy
- application framework compatibility policy
- known deviations with security impact

## Release gate

A production release requires all of the following:

1. Applicable compiler trust gates are closed.
2. Unit, conformance, integration, differential, and fuzz suites pass.
3. Native target matrices pass.
4. Load and multi-day soak tests remain within resource budgets.
5. Upgrade, reload, drain, rollback, and recovery exercises pass.
6. Security review findings are resolved or accepted with public rationale.
7. The release artifact and source are reproducible and signed.

