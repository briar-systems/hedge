# Hedge

Hedge is a lightweight production web server written in Mach.

Hedge is the deployable product in the Mach web stack. It will serve static files, Mach web applications, and upstream services over HTTP/1.1, HTTP/2, and HTTP/3 with native Mach TLS and QUIC.

Hedge serves HTTP/1.1, HTTP/2, and HTTP/3 over native TLS and QUIC, with SNI,
ALPN, and client certificates, qualified against curl, OpenSSL, and GnuTLS in
[`test/interop`](test/interop/README.md). Static files, reverse proxying,
bounded caches, virtual host dispatch, and ACME over authenticated TLS are
implemented. The current Let's Encrypt chain uses certificate algorithms
mach-tls cannot verify (#38), and a listener's credential generation cannot yet
be replaced (#37).

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
- native Linux, Darwin, and Windows operation
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

All dependencies are pinned to released Git tags.

```sh
mach dep pull
mach test .
mach build .
```

Build output uses Mach's default `out/` directory.
