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

Automatically managed certificate and account keys, and the ephemeral
TLS-ALPN-01 key, are secret-typed for their whole life. Mach welds secret
storage transitively: a record that holds it, or a pointer to one, cannot be
cast to the untyped `ptr`. Every seam ACME keys must reach is such a `ptr`: the
challenge provider's context, the certification-request signer's context, and
the worker threads' start argument, from which the manager is reachable.

So the secret half of every key lives in one bounded ring of secret slots in
`src/acme/keys.mach`, and a `keys.Key` is the public half (point and SPKI) plus
a handle naming its slot and generation. A handle is not an address and
unlocks only the operations that module defines. The scalar is drawn by the
secret CSPRNG straight into its slot, signed with in place for JWS and for the
certification request, and handed to `mach-tls` as secret bytes when a
certificate is installed. A slot is wiped when its key is destroyed, and a
stale handle reaches nothing. The ring holds `keys.MAX_KEYS` keys, and drawing
or loading a key past that fails rather than falling back to public storage.

Key material becomes public at exactly one site, a `:>` declassify in
`keys.publish`, which produces the durable form. It is forced: `mach-acme`'s
file store frames and digests public bytes. The published scalar and the
document encoded around it are wiped as soon as the write returns, and the
file is created owner-only. The only other crossing is inbound: a key file is
read into public memory, because `mach-std` reads files there, lifted into its
slot by `keys.adopt`, and the read buffer is wiped. The material is never
rendered in diagnostics.

QUIC listener keys (the CID, stateless reset and Retry/NEW_TOKEN keys) are
secret-typed for their whole life in `src/protocol/quic/keys.mach`. By default
they are drawn by the secret CSPRNG straight into that storage. An operator's
key file (`quic_keys`) is the one way they enter from outside. It is refused
when group or other can read it. It is read into public memory, because
`mach-std` reads files there, and each key is decoded from it straight into
secret storage by `src/protocol/quic/keyfile.mach`. The read buffer is wiped
before the read returns. Nothing writes the keys out or declassifies them. The
one `:>` in that path is the verdict of a constant-time comparison between a
key the file holds and the key already in force, which a reload needs in order
to keep a key it holds unchanged and to refuse one it would change.

## Reporting

Before public release, this section will name a private security contact, expected acknowledgment interval, supported versions, disclosure process, and encrypted reporting channel.

Until then, the local scaffold is not a deployed security-reporting endpoint.
