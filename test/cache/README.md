# Cache conformance

This harness starts a counted HTTP/1.1 origin and the real Hedge executable on
local TCP sockets. It proves that conditional revalidation remains internal,
that stale-if-error is bounded by policy, and that multiple ranges receive the
deliberate full representation without another origin request.

```sh
mach build .
./test/cache/run.sh
```

Set `HEDGE_BINARY` to qualify a different build profile. The runner binds
127.0.0.1 ports 19090 and 19091 and releases both processes on every exit path.
