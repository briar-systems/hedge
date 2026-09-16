# A reverse proxy

hedge in front of an origin, forwarding every request to it.

## Run it

```sh
./demo/proxy/run.sh
```

The script starts a `python3 -m http.server` on port 8082 as the origin, waits
for it, then starts hedge on port 8081 in front of it. Stopping the script stops
both.

```
upstream ready on 127.0.0.1:8082
hedge: listening public 127.0.0.1:8081
hedge: ready
```

## Check it

```sh
curl http://localhost:8081/hello.txt
```

prints `upstream says hello`, which is a file hedge never opened. The same file
straight from the origin, for comparison:

```sh
curl http://127.0.0.1:8082/hello.txt
```

## The configuration

Two things make this a proxy rather than a static site.

```toml
[server.features]
proxy = true

[service.origin]
kind = "proxy"
upstream = "127.0.0.1:8082"
```

Proxying is opt-in at the process level. Without `[server.features] proxy =
true` nothing in the proxy subsystem is constructed and a `proxy` service fails
to load, rather than being built and left unused.

`upstream` takes a comma-separated list, so `"127.0.0.1:8082, 127.0.0.1:8083"`
balances across two origins. `hedge.toml` beside this README carries that form
as a commented alternative.

## What a real edge adds

This demo is deliberately bare. A production edge in front of an upstream also
wants a `[budget]` bounding how many requests may be in flight to it at once, a
TLS listener in front, and health policy on the upstream. Those are in the
[configuration model](../../doc/CONFIGURATION.md); the point here is that the
forwarding itself is three lines.
