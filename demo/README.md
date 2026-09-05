# Demos

Three configurations that run as they are. Each one starts a server, serves
something, and can be checked with a single curl command.

| demo | what it shows | port |
| --- | --- | --- |
| [`static/`](static/README.md) | a directory served over cleartext HTTP/1.1 and HTTP/2 | 8080 |
| [`tls/`](tls/README.md) | the same directory over TLS 1.3, with HTTP/1.1, HTTP/2 and HTTP/3 | 8443 |
| [`proxy/`](proxy/README.md) | hedge forwarding to an upstream origin | 8081 |

Every demo runs from the repository root and binds to `127.0.0.1` only.

## Before the first run

Each `run.sh` builds hedge if there is no binary yet, which takes a few minutes
and a few gigabytes of memory. To build once yourself:

```sh
mach dep pull .
mach build . --profile release
```

Set `HEDGE_BINARY` to point a demo at a hedge you built somewhere else.

## Stopping

Each `run.sh` runs in the foreground. Ctrl-C stops it, and hedge drains its
connections before exiting. The proxy demo also stops the upstream it started.

## Where to look next

- [Configuration model](../doc/CONFIGURATION.md) is the full schema these three
  files use a corner of.
- [`test/interop`](../test/interop/README.md) drives the same server with curl,
  OpenSSL and GnuTLS and asserts the result of every leg.
- [`doc/bench`](../doc/bench/README.md) measures it under load.
