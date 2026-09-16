# Concurrent-connection fairness and growth

This harness holds many connections open against the real Hedge executable at
once and asserts that service reaches all of them, over TCP and over QUIC, and
that a configured connection cap binds both transports at one number. It exists because
[#122](https://github.com/briar-systems/hedge/issues/122) shipped: TLS
connections went unserved under concurrent load for as long as there has been a
published benchmark, and no test noticed, because every other test in the suite
drives one connection at a time.

```sh
mach build . --profile release
./test/load/run.sh
```

`HEDGE_BINARY` qualifies a different build. `LOAD_QUIC_SERVED=0` skips the
assertions that HTTP/3 transfers were served, which cannot pass until hedge#145
is fixed; CI sets it, and admission and refusal are checked regardless. `LOAD_CONNECTIONS` and `LOAD_TARGET`
change the shape of the TCP load, `LOAD_QUIC_CONNECTIONS` and `LOAD_QUIC_RATE`
the QUIC load. The runner binds 127.0.0.1 ports 19100 to 19105, TCP and UDP,
and releases every server and client on every exit path. The QUIC cells use the
system `curl` when it is built with HTTP/3, and otherwise fetch a pinned static
build into `.tools/`.

## What it asserts

Each of `LOAD_CONNECTIONS` workers owns one connection and issues requests on it
back to back. The run stops as soon as the median connection has completed
`LOAD_TARGET` requests, and then every connection must have completed at least
half of that median.

The verdict is a ratio taken inside a single run, never a duration. A slow
machine moves every connection's count together and the ratio does not move, so
the lane says the same thing on a loaded runner as on an idle one, and a failure
is a real loss of fairness rather than a missed deadline.

A run whose median connection never reaches the target inside the safety
deadline reports no verdict and fails. It has measured nothing, and saying so is
worth more than a number that came from a truncated run.

## Why there are two cells

The cleartext cell is the control. It shares the load generator, the machine and
the body with the TLS cell, so a cleartext failure means the run itself is not
trustworthy rather than that Hedge is unfair. Under the defect #122 tracked, the
cleartext cell passes and the TLS cell does not, which is what placed the fault
below TLS rather than in HTTP.

## Why it is not a `mach test` case

The property needs hundreds of live connections and a real TLS handshake on
each. `mach test` runs its cases as parallel processes sharing one machine, so a
case that saturates the box would change what every other case measures. It
belongs in a CI lane against a release build instead.


## The QUIC cells

Five small bodies are fetched over HTTP/3 one connection at a time. That cell
always runs, and it is what fails when a change stops HTTP/3 being served at
all.

A server with no configured `max_connections` must serve 1100 concurrent QUIC
connections, past the 1024 its QUIC pools were once preallocated to. Each
transfer names its own `*.load.test` authority, so curl opens a connection per
transfer instead of multiplexing them onto one, and a rate limit keeps every
transfer running until the last one has connected. The verdict requires every
transfer to finish with the whole body over HTTP/3 and checks the overlap from
curl's own timings: the latest handshake has to complete before the earliest
transfer finishes.

A second server caps connections at 48. Thirty-two TCP connections are held
open, then 32 QUIC transfers are started: exactly 16 must be admitted and
served, and the other 16 must be refused. While those 16 are open, a further
TCP connection must be refused as well. That is what one process-wide cap
means: whichever transport a connection arrives on, it counts against the same
number.

## `h3load`

`h3load/` is a quic-go client that does for QUIC what `fairness.py` does for
TCP, and can prove a cap on its own with `-expect-connected` and `-hold`. It is
not in the lane yet. hedge declares a 1200-byte UDP payload, which refuses
quic-go's 1280-byte Initials, and at mach-quic v0.7.0 declaring more stalls
stream delivery for every client (hedge#140). Run it by hand when a mach-quic
pin bump claims to fix that:

```sh
cd test/load/h3load && go run . -address 127.0.0.1:PORT -connections 1100
```

Once it serves, the QUIC cells move onto it.
