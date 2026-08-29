# Security model

Hedge treats every network peer, request field, uploaded byte, upstream response, configuration source, certificate, and persisted protocol object as untrusted until validated by its owning layer.

## Trust boundaries

- The compiler and standard library are trusted only through their release evidence.
- Crypto primitives are trusted only through their specification, tests, generated-code checks, and review status.
- TLS authenticates transport peers according to configured certificate policy.
- HTTP parsing establishes message boundaries before any routing or middleware decision.
- Hedge configuration establishes server policy before listeners become ready.
- Laurel establishes application-level identity and authorization separately from transport identity.

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

Automatically managed certificate and account keys are a stated exception to
secret-typed storage, and it is a property of the toolchain rather than a
choice. Mach forbids dropping the `^` secret qualifier — there is no
declassification at all, in either direction — and it welds transitively: a
record that contains secret storage, or a pointer to one, cannot be cast to the
untyped `ptr` that every callback seam in the server uses. `mach-std` also
exposes no secret-aware file interface, and `keys.encode_private_der` writes
into a secret buffer, so a key that must survive a restart cannot reach a file
at all while it stays secret-typed.

ACME key material is therefore held as public bytes and classified into a
secret stack buffer for the exact call that consumes it, which is zeroized
immediately after. Every crossing is one `scratch` argument in
`src/acme/keys.mach` and there are no others. The material is zeroized when the
key is destroyed, is never rendered in diagnostics, and reaches disk only in
files created owner-only.

**There is no key in this subsystem that could be held welded instead**, and
the reason differs per key rather than being one blanket claim:

- The account key and the certificate key must both survive a restart, and no
  welded value can be written to a file by any route. Holding them welded and
  declassifying only at the write is not a narrower option; it is not an
  option.
- Both are also reached through `ptr` callbacks — the serving plane for the
  manager, and the certification-request signer for the certificate key — so
  welded storage would make those seams unimplementable independently of
  persistence.
- The TLS-ALPN-01 key is never persisted, but it is held by the challenge
  provider whose context is a `ptr`, and it must survive from presentation to
  cleanup, so it cannot be confined to one call either.

What is bounded is the window rather than the storage class. The public copy
exists only inside the ACME subsystem: once a key is loaded into a `mach-tls`
credential generation it lives in secret storage there and never returns to
public bytes, and the per-call classification buffers are the only other place
the material appears.

## Reporting

Before public release, this section will name a private security contact, expected acknowledgment interval, supported versions, disclosure process, and encrypted reporting channel.

Until then, the local scaffold is not a deployed security-reporting endpoint.
