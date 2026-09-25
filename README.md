# Hedge

Hedge is a lightweight production web server written in Mach.

Hedge is the deployable product in the Mach web stack. It serves static files, Mach web applications, and upstream services over HTTP/1.1, HTTP/2, and HTTP/3 with native Mach TLS and QUIC.

Hedge serves HTTP/1.1 and HTTP/2 over TLS 1.3, with SNI, ALPN, session
resumption and client certificates. It does not offer TLS 1.2, and refuses a
TLS 1.2 client. A `transport = "quic"` listener serves HTTP/3, with ALPN inside
QUIC selecting `h3`. The interoperability matrix in
[`test/interop`](test/interop/README.md) qualifies these against curl, OpenSSL
and GnuTLS, and HTTP/3 against curl over ngtcp2, including request bodies,
large responses and prompt shutdown. The matrix runs one client at a time. Static
files, reverse proxying, bounded caches, virtual host dispatch, and ACME over
authenticated TLS are implemented. A certificate that ACME issues or renews is
installed into the running listener, and connections already open keep the
certificate they started with. The live ACME suite reaches Let's Encrypt's
staging directory over TLS verified against the system trust store on every
pull request. Issuing a certificate from Let's Encrypt's production directory
has not been run yet.

Hedge serves from one worker thread per CPU, but a QUIC listener is served by
the first worker alone. That worker's QUIC receive path drops datagrams past
about 10,000 a second, which 10,000 connections sending one keep-alive a second
reach. A `transport = "local"` listener accepts connections, then resets each
one without serving it. The comparison against Caddy in
[`doc/bench`](doc/bench/COMPARISON.md) measured hedge 0.2.1, before the TLS
handshake cost fell from about half a second of CPU to milliseconds and before
serving moved to a worker per CPU. It has not been run since, so it does not
describe hedge under load today.

## Product goals

- direct public internet operation without a C runtime protocol dependency
- HTTP/1.1, HTTP/2, and HTTP/3
- TLS 1.2 and TLS 1.3 with SNI, ALPN, resumption, and certificate rotation
- IPv4, IPv6, TCP, Unix sockets where available, and QUIC
- static files, reverse proxying, load balancing, caching, and Mach handlers
- automatic ACME certificate management
- graceful configuration reload and connection draining
- strict resource bounds and hostile-input handling
- structured logs, metrics, traces, health, and readiness
- native Linux, Darwin, and Windows operation (Windows builds today, but its tests do not pass there yet, so it is not supported at runtime)
- small idle footprint and pay-for-what-is-enabled composition

Lightweight does not mean omitting production duties. It means that protocol engines, storage, observability, and optional services are independent components with explicit ownership and no mandatory framework runtime.

## Repository family

- `mach-std` provides portable operating-system and runtime foundations.
- `mach-crypto` provides cryptographic algorithms over Mach constant-time primitives.
- `mach-tls` provides TLS and certificate machinery.
- `mach-http` provides HTTP semantics and connection engines.
- `mach-quic` provides QUIC transport and recovery.
- `mach-acme` provides certificate issuance and renewal.
- Laurel provides the production web application framework.
- `hedge` assembles those libraries into an operated server.

See [Project boundaries](doc/PROJECTS.md) and [Architecture](doc/ARCHITECTURE.md) for the dependency contracts.

## Try it

- [Demos](demo/README.md) are three configurations that run as they are: a
  static site, the same site over TLS with HTTP/2 and HTTP/3, and a reverse
  proxy. Each takes about a minute.
- [Benchmarks](doc/bench/README.md) measure hedge under load beside Caddy, with
  published results and a script that reproduces them.

## Documentation

- [Architecture](doc/ARCHITECTURE.md)
- [Project boundaries](doc/PROJECTS.md)
- [Roadmap](doc/ROADMAP.md)
- [Production requirements](doc/PRODUCTION.md)
- [Security model](doc/SECURITY.md)
- [Configuration model](doc/CONFIGURATION.md)
- [Required mach-std work](doc/MACH_STD_REQUIREMENTS.md)
- [Validation strategy](doc/VALIDATION.md)

## Local development

Each dependency is selected by an exact released version, and the resolved release is committed as a gitlink under `dep/`.

```sh
mach dep pull
mach test .
mach test . --lib tests
mach build .
```

`mach test . --lib tests` runs the test-only modules the executable never reaches.

GitHub Actions CI runs both test selections in both profiles and the live ACME conformance suite on every pull request.


Build output uses Mach's default `out/` directory.
