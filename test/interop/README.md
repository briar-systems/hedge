# Protocol interoperability

This harness runs the hedge binary against checked-in configurations and drives
it with real clients: `curl`, `openssl s_client`, `gnutls-cli`, and a raw socket
for the legs no packaged client can express. Every leg is an assertion, and the
runner exits non-zero naming any that failed.

```sh
mach build .
./test/interop/run.sh
```

Set `HEDGE_BINARY` to run a different build. The fixture private keys are test
material only.

## Configurations

`hedge.toml` binds four listeners:

| listener | address | protocols | notes |
| --- | --- | --- | --- |
| `cleartext` | 127.0.0.1:9080 | http/1.1, h2 | HTTP/2 by prior knowledge |
| `secure` | 127.0.0.1:9443 | http/1.1, h2 | TLS with three SNI identities |
| `proxied` | 127.0.0.1:9081 | http/1.1, h2 | PROXY protocol required from 127.0.0.1 |
| `h2only` | 127.0.0.1:9082 | h2 | refuses anything that is not the preface |

`no-default.toml` binds one TLS listener whose policy has a single named
identity and no default, so an unmatched server name is refused rather than
served somebody else's certificate.

`shutdown.toml` binds one cleartext listener with a 300ms drain deadline, short
enough that a shutdown with a peer still holding a request open reaches the
deadline within the life of a test.

## What the matrix covers

Serving:

- cleartext HTTP/1.1
- cleartext HTTP/2 by prior knowledge, with and without a request body
- TLS with ALPN selecting `http/1.1` and `h2`
- request bodies of 100000 bytes over HTTP/1.1 and HTTP/2, both over TLS
- a 156000-byte response over HTTP/1.1 and HTTP/2, compared byte for byte, which
  is what exercises multi-frame DATA, HTTP/2 flow control, and the record layer
  under a response larger than any single buffer
- six requests multiplexed on one HTTP/2 connection, two of them large
- twenty requests on one HTTP/1.1 connection

Credential selection:

- SNI selecting an exact identity (`alt.example.com`)
- SNI falling back to a wildcard identity (`*.example.com`)
- a server name with no matching identity and no default, refused with
  `unrecognized_name`

Session resumption:

- OpenSSL receives and resumes a TLS 1.3 session ticket
- a second presentation of the same ticket under `single_use` falls back to a
  full handshake

Refusals, each of which must fail the way policy says rather than falling
through to a default:

- a TLS 1.2 client against a TLS 1.3 listener: `protocol_version` (70)
- a client offering only `h3` over TLS on TCP: `no_application_protocol` (120)
- an HTTP/1 request to an HTTP/2-only listener: closed with no response
- a required PROXY header that never arrives: closed with no response
- a malformed PROXY header: closed with no response, and the address it asserted
  is never used

Shutdown, asserted through the process exit status, which is the only place the
outcome is visible to whoever supervises hedge:

- a stop with nothing in flight drains and exits 0
- a stop with a peer mid-request reaches the drain deadline, cancels the
  exchange, and exits 75 naming how many were abandoned

The PROXY protocol legs also cover the positive direction: a trusted v1 header
followed by an HTTP/1 request is served, and a trusted header followed by the
HTTP/2 preface selects HTTP/2.

## Qualification for this revision

30 legs passed, 0 failed, on linux-x86_64 against:

- curl 8.21.0 (libcurl/8.21.0, OpenSSL/3.6.3, nghttp2/1.70.0)
- OpenSSL 3.6.3
- GnuTLS 3.8.13

The in-process suites cover what this harness cannot express as a client
command: `mach test .` for the selection, prologue, credential, PROXY, TLS
policy, session and shutdown-ordering rules, and `mach test test/runtime` for
PROXY decoding and peer propagation over real sockets, for the drain deadline
against a stuck handler and a slow peer, for the two-stage HTTP/2 GOAWAY, and
for a superseded generation draining while its replacement serves.

## What this does not cover

- HTTP/3. hedge has no QUIC listener, because its listener plane has no
  datagram receive path. A QUIC listener is rejected at configuration time.
  `mach-quic` now ships the production binding from its connection core to its
  driver contract, so that half of the blocker is gone. See issue #32.
- Browser interoperability. This machine has no browser harness, so the ALPN and
  certificate paths are exercised only through the clients above.
- TLS 1.2. hedge configures its listeners for TLS 1.3 only, and the matrix
  asserts that a TLS 1.2 client is refused rather than served.
- Concurrency beyond one client at a time. Every leg runs against an idle server.
