# Hedge

Hedge is a lightweight production web server written in Mach.

Hedge is the deployable product in the Mach web stack. It will serve static files, Mach web applications, and upstream services over HTTP/1.1, HTTP/2, and HTTP/3 with native Mach TLS and QUIC.

The repository currently contains the product contract and implementation scaffold. The executable fails closed until the serving runtime exists. Nothing in this repository claims to serve traffic yet.

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
- `mach-web` provides the production web application framework.
- `hedge` assembles those libraries into an operated server.

See [Project boundaries](docs/PROJECTS.md) and [Architecture](docs/ARCHITECTURE.md) for the dependency contracts.

## Documentation

- [Architecture](docs/ARCHITECTURE.md)
- [Project boundaries](docs/PROJECTS.md)
- [Roadmap](docs/ROADMAP.md)
- [Production requirements](docs/PRODUCTION.md)
- [Security model](docs/SECURITY.md)
- [Configuration model](docs/CONFIGURATION.md)
- [Required mach-std work](docs/MACH_STD_REQUIREMENTS.md)
- [Validation strategy](docs/VALIDATION.md)

## Local development

All dependencies are local path dependencies. The repositories have no remote configured during scaffolding.

```sh
mach dep pull
mach test .
mach build .
```

Build output is written to the shared sibling directory `.mach-out`, outside this repository.

