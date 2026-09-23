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
assertions that HTTP/3 transfers were served, leaving admission and refusal
checked. `LOAD_CONNECTIONS` and `LOAD_TARGET` change the shape of the TCP load, `LOAD_QUIC_CONNECTIONS` and `LOAD_QUIC_RATE`
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
TCP, can prove a cap on its own with `-expect-connected` and `-hold`, and holds
idle connections for the scale lane with `-serve=false -hold`. `-dialing N`
bounds the handshakes in flight, so the scale lane measures held connections
rather than a handshake burst. A held connection sends a keep-alive PING at half its
`-idle-timeout`, which is what quic-go would cap it at anyway. It used to send
one every second, and 10,000 connections doing that was 10,000 datagrams a
second into hedge's socket: the socket dropped 76,396 datagrams while they were
held, and 2,063 more when the holder closed them, so 1,948 connections never
saw their CONNECTION_CLOSE and stayed live until their idle timeout (#269).
`-keep-alive` sets the period outright, which the scale lane uses to give idle
QUIC connections a known event rate. `-source` binds every socket to one local
address, `-rate` paces the dials for the ramp, and `-migrate` rebinds every
connection to a new port between two requests. The lanes build it, and
`test/load/rate`, into `.tools/` with the Go toolchain on the box, module
cache beside it.

```sh
cd test/load/h3load && go run . -address 127.0.0.1:PORT -connections 1100
```

## The burst lane

```sh
mach build . --profile release
./test/load/burst.sh
```

`burst.sh` dials more QUIC handshakes at once than the server can finish inside
its handshake deadline and asserts the shape that bounded, deferred admission
([#164](https://github.com/briar-systems/hedge/issues/164)) gives such a
burst. It is the measurement cell for
[#232](https://github.com/briar-systems/hedge/issues/232): before it, a burst
of several thousand dials lost some to their handshake timeout because the
handshake crypto ran in the receive path, the socket was read at the crypto
rate, and the kernel receive buffer filled and dropped.

A warm-up of `LOAD_BURST_WARM` dials (200) must all connect and gives the
service rate. Then `LOAD_BURST` dials (3000) go out together with a client
budget of `LOAD_BURST_CONNECT_TIMEOUT` seconds (30) against a server
`handshake_ms` of `LOAD_BURST_HANDSHAKE_MS` (10000), and the lane reads the
admission counters from an admin listener and the socket's drop counter from
`/proc/net/udp`. It passes when every promoted handshake completed (connected
equals promoted, so nothing was admitted and then lost), every dial either
completed or was refused (connected plus dropped covers the burst), the socket
dropped nothing, and the completions are the measured rate over the client
budget within `LOAD_BURST_TOLERANCE` (0.35). A refused dial is a silent drop
today, so its retransmission arrives afresh and the horizon is the client's
budget; when mach-quic can send a stateless close, a refused dial fails in one
round trip and the horizon becomes the server deadline. The lane binds ports
19110 to 19113.

## The scale lane

```sh
mach build . --profile release
./test/load/scale.sh
```

`scale.sh` measures what an idle connection costs, on the same binary and
configuration shape as `run.sh`. For each transport it starts a fresh server,
holds `LOAD_SCALE_SMALL` connections (1000) and then `LOAD_SCALE_LARGE`
(10000) open and idle, and reads the process's resident set from
`/proc/<pid>/smaps_rollup` at each step. TCP and TLS connections are HTTP/1.1
keep-alive connections that have served one request (`hold.py`, with `--tls`
for the second); QUIC connections are handshake-only holds over `h3load`,
because no client hedge can be measured with holds an HTTP/3 connection idle
after a request.

It prints, per transport, the resident set at 0, small, the midpoint and
large, the address space and mapping count at large, the slope in bytes per
connection between small and large with its two halves beside it, what the
first connections brought once, and the projection to 100k connections. The
served process runs with transparent huge pages disabled
(`PR_SET_THP_DISABLE`), because a resident set under them counts 2 MiB for the
first byte touched in each region and moves as pages collapse, which is the
kernel's policy, not hedge's footprint.

The slope is the regression guard #214 asked for. It is pinned per transport,
`LOAD_SCALE_PIN_TCP`, `_TLS` and `_QUIC`, at the value the lane achieved when
it was written, and a slope past the pin by more than `LOAD_SCALE_TOLERANCE`
percent (25) fails. A build that starts holding a buffer per idle connection
again moves the slope by tens of kilobytes; a build that grows faster than
linearly passes the pin at 10k only by holding less than the pin below it.
The pins are achieved values, not the targets in #169 section 4, and the
projection is a number the release notes carry, not a gate.

A record table commits a chunk whole (zeroed, or welded and wiped), and a
chunk's record storage is bounded at `storage.CHUNK_BYTES` (2 MiB): chunks
double from 16 records until the next doubling would pass the bound, and every
chunk after that holds the bound. So the resident set at N connections is
within one chunk of N times the per-slot cost, the counts are taken as given
for every transport, and the 100k projection is the per-connection cost times
100k plus what the first connections brought once.

What a TCP or TLS server keeps after its connections leave is asserted
(#235). The lane first waits up to 15 s for hedge's open sockets to fall back
to the idle count, so every connection has been retired, and then the resident
set above the idle baseline must be within these named terms, none of which
grows with the peak:

| term | bytes | why it stays |
| --- | ---: | --- |
| telemetry's log queue | 2,099,200 | 256 records of `std.log.sink.QueuedRecord` (8,200 bytes), allocated at start and resident once access-log records have passed through it |
| std's peak slack | 1,638,400 | one empty chunk above the lowest in io.runtime's slot, timer and deadline tables and net.async's operation, resource, resource map and driver slot tables, kept so a load crossing a chunk boundary never reallocates (mach-std#868, #874) |
| one `serve.Slot` chunk | 1,433,600 | 128 slots with `connection.Connection` inline, for a connection still being retired at the sample |
| allowance | 1,048,576 | listener-start tables first touched under load, released pool chunks each class keeps up to its high water, admission leases and the log writer's stack (measured 212 KiB for TCP and 712 KiB for TLS) |

A term that grows with the peak can hide under that bound at 10k, so a second
fresh server holds only `LOAD_SCALE_SMALL` connections and releases them, and
what the two servers keep may differ by no more than std's peak slack plus
128 KiB. At 1k against 10k the difference measures 1.59 MiB, which is the
slack; std 7.2.0's buffers slot table, which grew with the peak
(mach-std#878), made it 1.87 to 1.88 MiB over TLS, and the check fails on that build.

Measured page by page on std 7.4.0 (release build, transparent huge pages
off), a TCP server keeps 2,320, 3,928 and 3,932 KiB after 1k, 10k and 20k
connections, and a TLS server 2,820, 4,428 and 4,440 KiB, with its address
space back within 2.5 MiB of idle.

QUIC's after-release figure is printed, not asserted. The QUIC cell checks
that the connections have left first. A connection the client
closed stays in its draining period (mach-quic's 3 s drain timeout) before
hedge releases it, so a sample on a fixed delay after release measured
connections still draining (#269). The cell reads `hedge_quic_connections`
from an admin listener on 127.0.0.1:19116, waits up to 15 s for it to reach
zero, and fails if it does not, before the after-release sample is taken.

### The measured run for 0.7.0

`dev` for 0.7.0, release build, linux-x86_64, 16 cores, loopback, 1000 to
10000 connections, transparent huge pages off:

| transport | bytes per idle connection | halves (1000..5500, 5500..10000) | resident at 10000 | projected at 100k |
| --- | ---: | ---: | ---: | ---: |
| TCP, HTTP/1.1 keep-alive after one request | 13,956 | 13,888 / 14,024 | 139 MiB | 1,336 MiB |
| TLS, HTTP/1.1 keep-alive after one request | 29,591 | 28,481 / 30,700 | 282 MiB | 2,821 MiB |
| QUIC, handshake only (1008..8176, halves 1008..4080, 4080..8176) | 111,857 | 112,025 / 111,731 | 878 MiB at 8176 | 13,985 MiB for 131,056 slots |

The records behind those numbers, from `$size_of` on the same build:
`connection.Connection` 10,984 bytes, `listener.Connection` 280,
`secure.Channel` 440, `quic_runtime.Connection` 10,520,
`quic_runtime.ConnectionStorage` 13,544, `h3_session.Session` 22,944. The
rest of a TLS connection is its session in `protocol/secure` and one TLS
record chunk; the rest of a QUIC connection is mach-quic's per-connection
assembly and crypto state and the pool chunks its handshake left welded.

The lane ends with #220: two requests on one HTTP/3 connection, each throttled,
must be served at the same time under the default budget (the slowest finishes
within half again the fastest), and under a `connection_memory_bytes` that
funds one request the same two are served one after the other, because hedge
advertises only the concurrency its request lane funds.

CI runs it on the light tier at `LOAD_SCALE_SMALL=200 LOAD_SCALE_LARGE=1000`,
which is enough connections for the slopes to be measured and few enough to
fit the runner.

### Idle CPU, descriptors and timers (#176)

Each step also measures what an idle connection costs in CPU. At 0, at the
small count and at the large count, the lane reads the served process's CPU
time (each thread's `schedstat`, in nanoseconds) over a window in which it
does nothing but hold the connections. For TCP and TLS the window is
`LOAD_SCALE_IDLE_SECONDS` (10). QUIC connections send a keep-alive PING every
`LOAD_SCALE_QUIC_KEEPALIVE` seconds (15), and a step's connections are
dialled together, so their PINGs arrive in one burst per period, the first a
full period after the step. The QUIC window therefore opens one period after
the step and lasts one whole period. The cost above idle, per connection per
second, has to be flat in N: the large step may spend no more than the small
step's per-connection cost times the large count, within
`LOAD_SCALE_CPU_TOLERANCE` percent (50) plus 2 ms per window of noise. A per-event path that walks the live connections costs O(N) per
event and O(N²) per second, and it fails here.

Descriptors and timer-wheel entries are counted at each step as well. A TCP or
TLS connection holds exactly one descriptor, and a QUIC connection holds none
because it shares its listener's socket. The timer counts come from the
`hedge_timers_claimed` and `hedge_timers_armed` gauges. No connection may
hold more than `LOAD_SCALE_TIMERS_PER` wheel entries (1). A build without the
gauges reports the timer counts as missing and asserts nothing about them.

The connections come from several client processes. Each holds at most
`LOAD_SCALE_PER_CLIENT` connections (10000) from its own loopback source
address, 127.0.0.2 and up, so one address's ephemeral port range never
bounds N. That makes the 100k run ten holders:

```sh
LOAD_SCALE_SMALL=10000 LOAD_SCALE_LARGE=100000 ./test/load/scale.sh
```

It is a manual lane. At 100k QUIC connections the server alone needs about
11 GiB and the quic-go holders need several more, so on a smaller host run it
at the largest N the host allows and state the projection it prints.

### The measured run for #176

The lanes are from `feat/176` at 627fc1d and 7ec5491. The binary is a release
build of the source at fe80306 (sha256 `8daad759…`). Later commits change
only the lanes and a unit test. It ran on linux-x86_64, a Ryzen 7 5800X3D,
over loopback with one worker. Each run held every heavy slot (`agent-heavy
--exclusive`) with `vmstat` alongside. The QUIC keep-alive was 15 s.

| transport | span | bytes per idle connection (halves) | CPU per idle connection per second | descriptors, timer entries per connection |
| --- | --- | ---: | ---: | --- |
| TCP | 1k..10k | 13,166 (13,238 / 13,095) | under 0.0001 µs at both | 1, 1 |
| TCP | 10k..100k | 12,695 (12,522 / 12,868) | under 0.0001 µs at both | 1, 1 |
| TLS | 1k..10k | 22,501 (22,697 / 22,304) | under 0.0001 µs at both | 1, 1 |
| QUIC | 1k..10k | 103,612 (104,122 / 103,102) | 14.79 µs, 14.12 µs | 0, 1 |
| QUIC | 10k..30k | 102,846 (102,964 / 102,728) | 14.02 µs, 10.41 µs | 0, 1 |

So CPU per idle connection is flat in N and memory is linear, up to 100k for
TCP and 30k for QUIC. For TLS and QUIC the lane found problems past those
counts rather than figures:

- TLS at 100k: hedge held 62,925 of the 100,000 connections its clients had
  handshaken and been served on, so connections were closed under it past
  about 63k.
- TCP at 100k: the server keeps 84.5 MiB more after its connections leave than
  it does after 10k, so something grows with the peak past 10k.
- QUIC at 30k: 12,652 connections were still live 15 s after their clients
  closed them, which is #274's socket-drop shape at the close.
- QUIC at 50k: the host swapped hedge's pages out. The lane now counts
  swapped pages in the resident figure.

The 10-minute churn, at 200 TLS connections a second and then 100 HTTP/3
connections a second, served 120,000 and 60,000 with none missed. The
resident peak moved by 140 KiB and 40 KiB between the halves. CPU per
connection was 1,451 against 1,458 µs for TLS and 4,131 against 4,290 µs for
HTTP/3.

## The rate lane

```sh
./test/load/rate.sh
```

`rate.sh` measures request and handshake rates and what each costs the
server. `test/load/rate` is a closed-loop Go client, so a worker offers its
next operation only when its last one has finished, and the rate is what the
server sustained. The cells are:

- `h1`, `tls`, `h2` and `h3`: requests for a 1 KiB body back to back on
  `LOAD_RATE_CONNECTIONS` (64) held connections, over HTTP/1.1, HTTP/1.1 over
  TLS, HTTP/2 over TLS and HTTP/3;
- `tls-handshake` and `quic-handshake`: full handshakes on fresh
  connections, `LOAD_RATE_DIALING` (64) in flight, with X25519 alone and no
  session resumption, each closed once it is established.

Each cell runs against a fresh server for a `LOAD_RATE_WARMUP` (2 s) warm-up
and a `LOAD_RATE_DURATION` (10 s) window. The client reads the server's CPU
time from `/proc` as the window opens and closes, and each cell prints the
rate, the server's CPU per operation and the cores it used. The CPU per
operation is the server's own cost, so it says the same thing on a busy box
as on an idle one. The rate does not, because the client shares the cores.

`LOAD_RATE_WORKERS` is the worker-scaling cell from #169 section 8. Given a
list such as `1 2 4 8`, it runs every cell once per count with
`server.workers` set to that count, and asserts that each rate at N workers
reaches `LOAD_RATE_EFFICIENCY` (0.7) of N over the first count times the
first count's rate, up to the host's core count. `server.workers` arrives
with #173, so until then the lane runs the server's default and asserts only
that every operation succeeds. The lane binds ports 19140 to 19142.

## The ramp lane

```sh
./test/load/ramp.sh
```

`ramp.sh` is the ramp cell. `LOAD_RAMP` dials (1000) arrive at
`LOAD_RAMP_RATE` a second (200), over TCP and TLS through `hold.py --rate`
and over QUIC through `h3load -rate`, each against a fresh server under the
default handshake deadline and admission. Every dial has to be held. For QUIC,
hedge also has to count every one as a live connection, its admission
counters must show nothing dropped, refused or expired, and the socket's drop
counter must not move. The offered rate is below what the server can
handshake, so any loss is work the server dropped although it had room. This
is what a slow ramp of 1100 QUIC dials failed before #164. The lane binds
ports 19150 to 19153.

## The churn lane

```sh
./test/load/churn.sh
```

`churn.sh` is the churn cell. For `LOAD_CHURN_SECONDS` (600), new connections
arrive at a fixed rate, `LOAD_CHURN_TLS_RATE` (200) over TLS and
`LOAD_CHURN_H3_RATE` (100) over HTTP/3. Each one carries one request and
closes. The client is open-loop, so a start that finds all
`LOAD_CHURN_IN_FLIGHT` (256) workers busy is counted as missed rather than
queued. Every `LOAD_CHURN_SAMPLE` seconds (10) it samples the server's
resident set and CPU time. The lane passes when:

- every connection is served, with no missed start;
- the resident set's peak over the second half of the run is within
  `LOAD_CHURN_RSS_MARGIN` bytes (4 MiB) of its peak over the first half;
- the CPU per connection over the last quarter is within
  `LOAD_CHURN_CPU_TOLERANCE` percent (25) of the second quarter's. The first
  quarter is warm-up.

Anything a retired connection leaves behind (a record, a timer entry, a pool
chunk) grows the resident set linearly in the connections served, and it
fails the first check. A walk over anything that grows the same way fails
the second. CI runs it for 60 s. The lane binds ports 19160 to 19162.

## The migration lane

```sh
./test/load/migrate.sh
```

`migrate.sh` is the migration cell. `LOAD_MIGRATE` QUIC connections (32) each
complete a request. Then `h3load -migrate` moves each connection's socket to a
new local port without a PATH_CHALLENGE of its own, which is what a NAT
rebinding looks like to the server, and completes a second request on the
same connection. The lane passes only if hedge follows every connection to its
new address. Once workers steer datagrams by connection ID (#174), the new
4-tuple can land on another worker's socket, and this cell holds that case.
The lane binds ports 19170 to 19172.
