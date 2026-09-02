# Benchmarks

What hedge does under load, measured beside a server people already know, on a
machine you can reproduce the numbers on.

```sh
./doc/bench/run.sh
```

That provisions everything, runs the matrix, and writes a results file into
[`results/`](results/). The published runs are in there. Read one of those
before running your own: it names the machine it came off, and a number from a
different machine is a different number.

## What is measured

One cell is one combination of protocol, body size, concurrency and server. Each
cell gets a freshly started server, ten seconds of load, and reports six things:

| column | meaning |
| --- | --- |
| req/s | completed responses per second |
| MiB/s | body bytes off the wire per second, not counting headers |
| p50 ms | the median request's whole life, connection reuse included |
| p99 ms | the 99th percentile of the same |
| peak RSS | `VmHWM` for the server process, over that cell only |
| CPU s | user plus system time across every thread, over that cell only |

The matrix is fixed:

- **Protocols**: HTTP/1.1 cleartext, HTTP/1.1 over TLS 1.3, HTTP/2 over TLS 1.3,
  HTTP/3 over QUIC.
- **Bodies**: 1 KiB, 64 KiB and 1 MiB of incompressible random bytes, from one
  content directory both servers serve.
- **Concurrency**: 64 and 256 connections.
- **Servers**: hedge, and [Caddy](https://caddyserver.com) 2.11.4.

Both servers present the same self-signed P-256 certificate for `localhost`,
serve the same files off the same directory, and bind separate ports on the
loopback interface. The load generator asks for no compression, and neither
server is configured to compress, so the transfer columns compare like with
like.

## Why the servers get restarted between cells

`VmHWM` is a high-water mark that never falls. A server left running across
cells would report the largest cell's peak in every row after it, and the
memory column would say nothing. So each cell starts its own server, warms it
for a second, measures for ten, reads `/proc`, and stops it.

## How the load is generated

HTTP/1.1 and HTTP/2 cells use [`oha`](https://github.com/hatoo/oha) 1.16.0,
which holds a fixed connection count open for a fixed duration and reports
latency percentiles over every request. `-w` is set so that requests still in
flight when the clock runs out are waited for rather than aborted, because an
abort per connection at the end of every run is an artefact of the stopwatch
rather than anything the server did.

**HTTP/3 is measured differently, and its numbers are comparable only with each
other.** The released `oha` binary is not built with HTTP/3 support, so there is
no load generator on this machine that speaks it. The HTTP/3 cells instead use
curl, driven in parallel batches until the ten seconds are spent. Three things
follow from that, and none of them are true of the other rows:

- curl multiplexes onto one QUIC connection, so the concurrency figure bounds
  concurrent streams rather than connections.
- Each batch is a separate curl process, so process startup is inside the
  measured time.
- curl is a transfer tool. It is not trying to saturate anything.

An HTTP/3 number in these tables is therefore a floor, not a throughput result.
It is enough to tell a working HTTP/3 implementation from a broken one and to
watch it change between revisions, and it is not enough to compare against the
HTTP/2 row above it.

## What is not measured

- **Anything but loopback.** No network, so no packet loss, no reordering, and a
  round trip near zero. QUIC's recovery machinery is doing nothing here, which
  flatters the HTTP/3 numbers in one direction and hides congestion control's
  contribution in the other.
- **Handshake cost.** Connections are held open, so a TLS handshake is amortised
  across every request on it. A workload of many short connections would look
  different, and worse for whichever server has the slower handshake.
- **Anything dynamic.** Static files off a warm page cache only. No proxying, no
  application handlers, no cache.
- **Correctness under load.** A cell that returns 200 fast is not a cell that
  returned the right bytes. [`test/interop`](../../test/interop/README.md) is
  where responses are compared byte for byte.
- **Long runs.** Ten seconds per cell finds a throughput plateau. It does not
  find a leak, a fragmentation problem, or anything that needs an hour.

## Reproducing

`run.sh` needs `gh` authenticated (to fetch the pinned tools), `openssl`,
`python3` and a curl built with HTTP/3. It downloads `oha` 1.16.0 and Caddy
2.11.4 into `doc/bench/.tool/` on first use, and writes generated certificates,
content and configurations into `doc/bench/.work/`. Both directories are ignored
by git.

```sh
./doc/bench/run.sh --smoke   # one short cell per protocol, writes no results
./doc/bench/run.sh           # the full matrix, about 25 minutes
```

The matrix owns ports 18080, 18081, 18443 and 18444. It refuses to start if one
of them is busy rather than blaming the server for a port it did not open.

Set `HEDGE_BINARY` to measure a build from somewhere else. Otherwise `run.sh`
uses the release build in `out/`, and builds one if there is none.

## Reading a failure

A cell that fails is printed as `failed` in its table and named at the bottom of
the results file with what went wrong. Failures are never filled in with a
plausible number and never quietly dropped. If a cell fails, the harness or the
configuration is wrong, or the server is: all three have happened, and
[`COMPARISON.md`](COMPARISON.md) says which.
