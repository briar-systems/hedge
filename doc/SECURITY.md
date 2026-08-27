# Security model

Hedge treats every network peer, request field, uploaded byte, upstream response, configuration source, certificate, and persisted protocol object as untrusted until validated by its owning layer.

## Trust boundaries

- The compiler and standard library are trusted only through their release evidence.
- Crypto primitives are trusted only through their specification, tests, generated-code checks, and review status.
- TLS authenticates transport peers according to configured certificate policy.
- HTTP parsing establishes message boundaries before any routing or middleware decision.
- Hedge configuration establishes server policy before listeners become ready.
- Mach Web establishes application-level identity and authorization separately from transport identity.

## Threat classes

The validation program covers:

- memory corruption and integer overflow
- request smuggling and response splitting
- parser differentials
- path traversal and symlink races
- slow reads, slow writes, and connection hoarding
- compression bombs and state-table exhaustion
- TLS downgrade, replay, truncation, and certificate confusion
- QUIC amplification, spoofing, migration abuse, and reset handling
- cache poisoning and authorization leakage
- proxy header spoofing and confused peer identity
- session fixation, CSRF, cross-origin misuse, and unsafe redirects
- log injection and metric-cardinality exhaustion
- configuration rollback and secret exposure
- dependency, build, and release provenance compromise

## Resource policy

Every resource is charged to an ownership scope such as process, listener, virtual host, connection, client identity, HTTP stream, request, upstream, cache, or application.

Limits include counts and total bytes. Timeout policy includes inactivity and absolute deadlines. Sending occasional bytes cannot extend an absolute header or request deadline indefinitely.

Overload decisions occur before expensive allocation or cryptography where possible. Refusal does not create unbounded telemetry or retry work.

## Cryptography assurance

Mach constant-time facilities are treated as functional implementation machinery. Third-party validation is tracked independently from functionality.

Every crypto release records:

- supported target and optimization combinations
- official algorithm vectors
- cross-implementation differential results
- generated instruction checks for secret-dependent control and access
- invalid-input and fault behavior
- zeroization behavior
- independent review status

Lack of independent review is reported accurately. It does not cause the implementation to silently substitute a foreign TLS stack.

## Secrets

Secrets use dedicated types and explicit lifetimes. Copies are minimized and observable. Secret-bearing allocations are zeroized before reuse or release. Configuration diagnostics never render secret values.

Certificate private keys support reload without exposing mutable key state to request handlers. Session ticket keys rotate through immutable key generations with controlled overlap.

## Reporting

Before public release, this section will name a private security contact, expected acknowledgment interval, supported versions, disclosure process, and encrypted reporting channel.

Until then, the local scaffold is not a deployed security-reporting endpoint.

