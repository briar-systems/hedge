# TLS, with HTTP/1.1, HTTP/2 and HTTP/3

The same directory as the static demo, over TLS 1.3, reachable three ways on one
address.

## Run it

```sh
./demo/tls/run.sh
```

The first run generates a self-signed P-256 certificate for `localhost` into
`demo/tls/.certs/`, which is ignored by git. Then:

```
hedge: listening secure 127.0.0.1:8443
hedge: listening quic 127.0.0.1:8443
hedge: ready
```

Two listeners on the same port number: one TCP, one UDP.

## Check it

The certificate is self-signed, so every command needs `-k`.

```sh
curl -k --http1.1   -o /dev/null -w '%{http_code} HTTP/%{http_version}\n' https://localhost:8443/
curl -k --http2     -o /dev/null -w '%{http_code} HTTP/%{http_version}\n' https://localhost:8443/
curl -k --http3-only -o /dev/null -w '%{http_code} HTTP/%{http_version}\n' https://localhost:8443/
```

which print, in order:

```
200 HTTP/1.1
200 HTTP/2
200 HTTP/3
```

HTTP/3 needs a curl built against a QUIC library. `curl --version` lists
`ngtcp2` or `quiche` in its feature line if yours is.

## How one address serves three protocols

The TCP listener offers `http/1.1` and `h2`. Which one a connection gets is
decided by ALPN during the handshake, and by the listener's order rather than
the client's: a client that offers both is given `h2` because the listener
prefers it.

The QUIC listener binds the same port over UDP and offers `h3` only. HTTP/3 is
reached through ALPN inside QUIC, so a client that speaks QUIC but does not ask
for `h3` is refused rather than served something else.

Both listeners name `tls = "public"`, so one certificate covers all three
protocols.

`host.site` owns the routes and `host.h3` exists to give the QUIC listener the
same name and TLS policy. Routing itself carries no listener dimension: the one
route under `host.site` serves both listeners.

## Going to production

Replace the self-signed certificate. Either point the identity at real files, or
switch on ACME and let hedge obtain and renew one. The
[configuration model](../../doc/CONFIGURATION.md) covers `[acme]`, the three
challenge types, and what a listener must look like for each.
