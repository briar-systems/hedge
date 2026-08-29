# live acme conformance

These tests drive a real ACME authority. Nothing here is a fixture: pebble
issues the certificates, and it validates them by connecting to the listener
the test starts.

```text
test/acme/harness/start.sh
mach test test/acme --profile debug --jobs 1
mach test test/acme --profile release --jobs 1
test/acme/harness/start.sh.stop
```

`--jobs 1` is required. Pebble validates HTTP-01 on one fixed port (5002), so
only one test at a time can own the listener that answers it.

The harness runs pebble's challenge test server with its own HTTP-01 responder
disabled and with AAAA answers turned off, so the authority resolves every name
to loopback IPv4 and the only process that can answer a validation is hedge.
