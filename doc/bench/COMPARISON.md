# hedge and Caddy

Caddy is the obvious thing to hold hedge against. It serves the same job from
one static binary, it is widely deployed, and it has spent years on exactly the
paths hedge is building. This is where hedge stands against it today, on
measurement and on what it takes to operate each one.

hedge loses most of this comparison. That is the useful part: each place it
loses has a reason, and the reasons are different from each other.

The first published run is
[`results/2026-09-05-D00.md`](results/2026-09-05-D00.md), taken after the fixes
for [#69](https://github.com/briar-systems/hedge/issues/69),
[#70](https://github.com/briar-systems/hedge/issues/70) and
[#71](https://github.com/briar-systems/hedge/issues/71) landed. Read it for the
full matrix; this file reads it.

## Throughput

Caddy is faster everywhere, and on TLS the gap is not a factor but a different
order of thing. The 64 KiB body at 256 connections, which is the middle of the
matrix:

| protocol | hedge | caddy |
| --- | ---: | ---: |
| HTTP/1.1 cleartext | 3,628 req/s | 97,998 req/s |
| HTTP/1.1 over TLS | 56 req/s, 506 requests lost | 48,453 req/s |
| HTTP/2 over TLS | 55 req/s, 504 requests lost | 30,139 req/s |
| HTTP/3 over QUIC | served nothing | 6,464 req/s |

Three separate causes, and only one of them is hedge being young.

**hedge serves from one thread; Caddy uses every core.** One serving loop against
sixteen hardware threads is most of an order of magnitude before implementation
quality enters the picture. It is a design position, and it is why hedge's
per-request cost matters more than its request rate: a loop spending 0.3 ms on a
request cannot serve more than about 3,600 of them a second however many clients
ask.

**Cleartext is respectable and bounded by transfer rate.** hedge holds about 227
MiB/s across the 64 KiB and 1 MiB bodies, and 13,391 requests a second on 1 KiB
bodies. Caddy reaches 6,124 MiB/s on the same 64 KiB body, because it is handing
pages to the loopback where hedge is copying them. That is a real gap and an
ordinary one: it is the difference between a straightforward implementation and
a tuned one, not a defect.

**TLS is broken rather than slow, and this is the finding.** Every hedge TLS cell
serves a few dozen to a few hundred requests and loses most of the rest to
timeouts. Measured directly on an idle server, a TLS handshake costs about 513 ms
of CPU and each TLS record about 29 ms whatever it holds, both two to three
orders of magnitude above what scalar implementations cost. Because the server is
single-threaded those costs serialise, so 64 clients connecting at once put the
last handshake 33 seconds after the first, past the client's timeout. The TLS
rows are therefore not measuring bulk TLS performance; they are measuring how
many handshakes fit in ten seconds. Filed as
[#91](https://github.com/briar-systems/hedge/issues/91), which supersedes the
framing in [#72](https://github.com/briar-systems/hedge/issues/72) that this was
just the scalarized build.

**HTTP/3 does not survive concurrency.** Every hedge HTTP/3 cell either completed
nothing or lost most of its batch, which is
[#89](https://github.com/briar-systems/hedge/issues/89) and was known before the
run. Caddy serves the same cells at 6,464 requests a second.

## What the fixes bought

The same matrix before [#69](https://github.com/briar-systems/hedge/issues/69),
[#70](https://github.com/briar-systems/hedge/issues/70) and
[#71](https://github.com/briar-systems/hedge/issues/71):

| cell | before | after |
| --- | ---: | ---: |
| cleartext, 64 KiB, 64 connections | 1,202 req/s | 3,646 req/s |
| cleartext, 1 KiB, 64 connections | 9,452 req/s | 11,535 req/s |
| cleartext peak RSS | 675 MiB | 568 MiB |
| HTTP/1.1 over TLS | every connection refused | serves, then loses most |

Cleartext throughput roughly tripled on the larger bodies, the TLS listener
stopped refusing clients that offer no ALPN, and the QUIC listener's footprint
came down by about 100 MiB. HTTP/2 and HTTP/3 under concurrency did not improve.

## Where the load is lost

Every hedge cell that lost requests lost them to timeouts rather than to
refusals or errors, which is worth separating because it says the server is
behind rather than saying no.

| protocol, 64 KiB body | served in 10s | lost |
| --- | ---: | ---: |
| HTTP/1.1 over TLS, 64 connections | 64 | 120 |
| HTTP/1.1 over TLS, 256 connections | 66 | 506 |
| HTTP/2 over TLS, 64 connections | 66 | 124 |
| HTTP/2 over TLS, 256 connections | 60 | 504 |

The counts are close to the connection count in every case, which is the shape
of a server that answers a few connections and never reaches the rest inside the
client's patience. That follows from #91's per-handshake cost and a single
serving thread without needing any other explanation.

The 1 MiB HTTP/2 cells served nothing at all in ten seconds. The results file
records those as "served nothing" rather than as a rate, because a rate computed
from zero completions is not a measurement.

These rows are in the tables rather than omitted, and cells that lost requests
keep their numbers with a mark rather than being replaced by the word "failed".
A rate over what completed still says how far the server got, and hiding it
would make hedge look worse than it is in exactly the places it is already bad
enough.

## Memory

This is the one column where the comparison is not one-sided, and it splits in
two.

Serving HTTP/1.1 and HTTP/2 with no QUIC listener, hedge idles at about 5 MiB
resident and peaks near 30 MiB under 64 connections. Caddy's peak in the same
cells is around 70 MiB. hedge's footprint is genuinely small, and its bounds are
declared rather than emergent: every collection in a configuration has a
compile-time maximum, admission reserves an entry's whole length before writing
a byte, and a disabled subsystem allocates nothing at all. `test/interop`
asserts that last part through `/proc` rather than trusting it.

Add a QUIC listener and every hedge row in the published run sits between 560
and 586 MiB, against 67 to 131 MiB for Caddy serving the same cells. The fix for
[#71](https://github.com/briar-systems/hedge/issues/71) took roughly 100 MiB off
what it was, and what remains is still about eight times Caddy and is reached
before the first request. Whatever that preallocation is sized against, it is not
sized against a default deployment.

So: hedge is the smaller server until it serves HTTP/3, and then it is by far
the larger one. The published numbers are all from a configuration that binds a
QUIC listener, because the matrix serves all four protocols from one process, so
every hedge memory figure in the results file is the HTTP/3-enabled one.

## Configuration

Caddy's configuration is dramatically shorter for the common case, and the gap
is not stylistic.

A public static site with automatic certificates, HTTP/2 and HTTP/3, in Caddy:

```
example.com {
	root * /srv/www
	file_server
}
```

Three lines. That obtains and renews a certificate from Let's Encrypt, redirects
port 80, serves HTTP/1.1, HTTP/2 and HTTP/3, and needs no further decisions.

The same site in hedge needs, at minimum: a TCP listener, a QUIC listener, a TLS
policy naming an identity, an `[acme]` block with a directory URL, a trust
bundle path, a contact, terms agreement, a storage directory, a listener name
and a name list, a host block per listener, a static service, a route, and for
`http-01` a second cleartext listener on port 80 with its own host, a `native`
`acme-challenge` service and a route to it. That is on the order of fifty lines
and a dozen decisions to serve one directory.

The trade is deliberate on hedge's side. Its schema rejects unknown fields,
resolves route precedence by specificity rather than file order, refuses two
hosts claiming one name for one path, and validates certificate coverage,
unreachable routes, timeout relationships and telemetry dimensions before
anything binds. Caddy's brevity comes from defaults it picks for you; hedge
makes you name them, and tells you at load time when the set you named is
inconsistent. Whether that is worth forty extra lines depends entirely on
whether you would rather find a mistake at startup or in production.

One default is worth knowing before you deploy: hedge admits at most 100
connections from any single peer address, where Caddy ships no per-peer bound at
all. On a public listener facing the internet directly, that is hedge's default
doing its job. Behind a load balancer, a reverse proxy or a NAT it is a trap.
Every connection then arrives from one address, the whole site shares those 100
slots, and the bound stops being anti-abuse and becomes a capacity ceiling that
shows up as refused connections under load rather than as an error.

Enabling `proxy_protocol` does not rescue it. The bound is charged in
`admission.acquire` against the address the kernel reported at accept, and the
PROXY header is not decoded until the connection prologue runs, which is after
admission has already decided. A decoded peer reaches logging, routing and
forwarded headers; it does not reach the connection bound. Raising
`server.limits.max_connections_per_peer` to suit the topology is the only lever.
This benchmark raises it to 1024, because on loopback every connection is one
peer and the default would measure itself rather than the server.

Where hedge is clearly worse rather than merely more explicit is the
duplication: serving one name over TCP and QUIC needs two host blocks declaring
the same name, one of which exists only to attach a TLS policy and carries no
routes. That is the schema showing through rather than a decision anyone made.

## TLS and ACME

Caddy issues, installs and renews certificates with no configuration, for any
name that resolves to it, and has done for years across a very large number of
deployments.

hedge implements ACME with more of the surface visible: one account and one
certificate over up to eight names, `http-01`, `dns-01` and `tls-alpn-01`,
renewal driven from the serving loop with jitter and a bounded backoff, storage
the process owns with owner-only permissions and atomic replacement, and every
authority URL authenticated against an explicitly named trust bundle. `dns-01`
carries no provider integrations at all: an embedder supplies a publisher, and a
TOML-only deployment that selects it fails to load rather than discovering the
gap at first renewal.

Two things stop this being usable against a public authority today. The current
Let's Encrypt chain uses certificate algorithms mach-tls cannot verify
([#38](https://github.com/briar-systems/hedge/issues/38)), and a listener's
credential generation cannot yet be replaced
([#37](https://github.com/briar-systems/hedge/issues/37)), so a renewal cannot
reach a running server. Until those close, hedge's certificates come from files.

## HTTP/3

Caddy enables HTTP/3 by default on every HTTPS site. There is nothing to turn
on.

hedge needs a second listener with `transport = "quic"`, a second host block,
and an `h3` protocol list, and then costs 600 MiB and a 3x slowdown on the TCP
path for having it. It does work: `test/interop` drives it with curl over
ngtcp2 and compares a 156,000-byte response byte for byte, and the demo in
`demo/tls` answers HTTP/3 on the same port as HTTP/2. But enabling it is a
decision with consequences, where in Caddy it is not a decision at all.

## What hedge has that Caddy does not

Nothing in the tables, so it belongs here rather than being implied.

hedge carries no C runtime and no C protocol dependency. TLS, QUIC, HTTP and the
certificate machinery are all Mach. For a deployment whose reason for existing
is to not link OpenSSL, that is the entire point, and no amount of Caddy's
throughput substitutes for it.

Its resource story is bounded by construction rather than by tuning: the pipeline
depth, the cache byte budget, the entry count, the per-listener accept depth and
the per-peer connection count are all declared maxima that fail validation when
exceeded rather than being clamped silently. Its shutdown reports through the
exit status which of the seven ordered steps completed, so a drain that
abandoned live exchanges cannot be mistaken for a clean one by whatever
supervises the process.

Those are real, and they are worth something. They are not worth 60x, and this
document should not pretend otherwise.

## The short version

Use Caddy if you want a fast, finished web server today.

hedge is not that yet, and the published run says so precisely. Cleartext
HTTP/1.1 works and is about 25 times slower than Caddy, which is an ordinary gap
for a single-threaded server against one that uses every core. TLS does not work
under concurrency: a handshake costs half a second of CPU, so the connections
queue and time out. HTTP/3 does not survive a concurrent batch at all. Enabling
HTTP/3 costs about 560 MiB before the first request.

What hedge has is a bounded, C-free implementation of the whole stack, with
every one of those failures written down, filed, and measurable by rerunning
`doc/bench/run.sh` after each one closes. Two of the four defects this harness
found in its first run are already fixed, and the run above is what tells you by
how much. That is the point of the file: the next run can be compared to this
one.
