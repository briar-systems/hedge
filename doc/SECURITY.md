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

Every secret hedge holds, and where it becomes public:

- the administration credential: welded storage in `hedge.secret`, compared in
  constant time, never declassified beyond two one-bit verdicts: whether it
  holds a NUL, CR or LF byte, and whether a presented token matches it
- secrets granted to hosted applications: welded storage in `hedge.secret`,
  never declassified by hedge
- automatically managed certificate and account keys: a ring of secret slots,
  made public only by `keys.publish` for the durable form
- QUIC listener keys: secret-typed storage, never declassified beyond a key
  file's layout and a reload's comparison verdict
- configured TLS private keys: read with `std.filesystem.read_secret_of`
  straight into welded storage, parsed by `mach-tls` from there, never
  declassified
- session ticket keys: drawn from the operating system entropy source into
  `mach-tls`'s key ring, which owns their storage

Every key file hedge reads, a configured TLS private key, a QUIC listener key
file and a key in the ACME store, goes through one check in
`src/secret_file.mach`. The file is opened once, and that handle is stat'd and
read with `std.filesystem.read_secret_of`, so the file checked is the file
read. One group or other can read is refused before a byte of it is read, with
a diagnostic naming the file and the fix, `chmod 600`. Windows synthesizes the
mode from attributes, so the check is skipped there.

The administration credential and the secrets granted to hosted applications
resolve through one path in `src/secret.mach`. A `file` secret is read with
`std.filesystem.read_secret`, straight into its own welded allocation. An
`os` or `application` secret is written by the embedding program's registered
`secret.Provider` into secret scratch storage and copied into one. An `env`
secret is the one exception: the process already holds its environment in
public memory, so the value is copied out of it and the public copy is cleared.

The administration credential is resolved once, when the process starts. A
reload that would change which secret it names, or that secret's provider or
key, is not reload-compatible, so a credential rotated at its source takes
effect at the next start. hedge holds it in a bounded table of
welded slots, and the admin handler refers to it by a public handle, a slot
and generation that is not an address. The handler checks the public `Bearer `
scheme, then compares the presented token against every byte of the credential
in constant time. That path has two `:>` sites, each declassifying one bit
computed over every byte without a branch on the value:

- `secret.presentable`: whether the credential holds a NUL, CR or LF byte. No
  request can present such a credential, so hedge refuses to start with it
  rather than hold one that nothing could match. The refusal is diagnosed
  against the secret's declaration (source `secret`, path its name), never by
  its value. This is the same kind of structural verdict the QUIC key file
  parser declassifies.
- `secret.matches`: whether a presented token equals the credential.
 The credential is wiped and its slot freed when telemetry
closes, and a stale handle authenticates nothing.

A hosted application's secrets are resolved again for every generation, into a
bank beside the one borrows read, and the replaced bank is wiped when the new
one is published. A borrow copies one value into secret scratch storage, hands
it to the borrower's callback as `contracts.SecretBytes`, and wipes the scratch
once the callback returns. hedge never declassifies them. What the borrower
does with a value is its own.

Automatically managed certificate and account keys, and the ephemeral
TLS-ALPN-01 key, are secret-typed for their whole life. Mach welds secret
storage transitively: a record that holds it, or a pointer to one, cannot be
cast to the untyped `ptr`. `mach-acme` types the challenge provider's and the
certification-request signer's contexts, so those seams take a `*Key` directly.
The worker threads' start argument is still a `ptr`, and the manager that owns
the keys is reachable from it, so a key record the manager holds must stay
public.

So the secret half of every key lives in one ring of secret slots in
`src/acme/keys.mach`, and a `keys.Key` is the public half (point and SPKI) plus
a handle naming its slot and generation. A handle is not an address and
unlocks only the operations that module defines. The scalar is drawn by the
secret CSPRNG straight into its slot, signed with in place for JWS and for the
certification request, and handed to `mach-tls` as secret bytes when a
certificate is installed. A slot is wiped when its key is destroyed, and a
stale handle reaches nothing. The ring is drawn once in secret storage when
the process starts, sized at `keys.KEYS_PER_CERTIFICATE` (the account, pending,
active and tls-alpn-01 presentation keys) for each configured certificate, and
drawing or loading a key past that fails rather than falling back to public
storage.

Key material becomes public at exactly one site, a `:>` declassify in
`keys.publish`, which produces the durable form. It is forced: `mach-acme`'s
file store frames and digests public bytes. The published scalar and the
document encoded around it are wiped as soon as the write returns, and the
file is created owner-only. A key file is read back through
`src/secret_file.mach`, straight into secret storage. Its frame (magic,
version, kind and length) is read in the clear, its digest is checked over the
secret payload without a branch on it, and `keys.adopt` copies the scalar into
its slot. The read storage is wiped when it is released, so the material is
never public on the way in. It is never rendered in diagnostics.

QUIC listener keys (the CID, stateless reset and Retry/NEW_TOKEN keys) are
secret-typed for their whole life in `src/protocol/quic/keys.mach`. By default
they are drawn by the secret CSPRNG straight into that storage. An operator's
key file (`quic_keys`) is the one way they enter from outside. It is refused
when group or other can read it. It is read through `src/secret_file.mach`,
straight into secret storage, and
`src/protocol/quic/keyfile.mach` parses it there, decoding each key's hex
without a branch on a digit. The parser declassifies only the file's layout:
which bytes separate words and lines, whether a word is a keyword, the numbers
(codepoints, host ID lengths and generations), and one verdict per key on
whether it is well-formed hex. The read storage is wiped when it is released.
Nothing writes the keys out or declassifies them. Beyond the layout, the one
`:>` in that path is the verdict of a constant-time comparison between a key
the file holds and the key already in force, which a reload needs in order to
keep a key it holds unchanged and to refuse one it would change.

## Reporting

Before public release, this section will name a private security contact, expected acknowledgment interval, supported versions, disclosure process, and encrypted reporting channel.

Until then, the local scaffold is not a deployed security-reporting endpoint.
