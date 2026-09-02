# hedge and Caddy

Caddy is the obvious thing to hold hedge against. It serves the same job from
one static binary, it is widely deployed, and it has spent years on exactly the
paths hedge is building. This is where hedge stands against it today, on the
numbers in [`results/`](results/) and on what it takes to operate each one.

hedge loses most of this comparison. That is the useful part: each place it
loses has a reason, and the reasons are different from each other.

## Throughput

Caddy is faster everywhere, and by a lot. On the published run the gaps are
roughly:

| protocol | hedge relative to Caddy |
| --- | --- |
| HTTP/1.1 cleartext, small bodies | about 8x slower |
| HTTP/1.1 cleartext, large bodies | about 60x slower |
| HTTP/1.1 over TLS | not measured; see below |
| HTTP/2 over TLS | unusable, see below |
| HTTP/3 | both measured by the curl harness; hedge is slower |

Three separate causes account for essentially all of it, and only one of them
is about hedge being young.

**hedge is single-threaded; Caddy uses every core.** hedge serves from one
process with one serving loop. Caddy runs a goroutine per connection across
sixteen hardware threads on this machine. Before any implementation quality
enters the picture, that is most of an order of magnitude on a machine this
wide. It is a design position rather than an oversight, and it is why hedge's
per-request latency matters more than its request rate: a single loop that
takes 0.9 ms per request cannot serve more than about 1,100 of them a second no
matter how many clients ask.

**TLS runs without SIMD.** Every project in this family builds with
`simd = "scalarize"`, so the AEAD is scalar code while Go reaches AES-NI and
CLMUL. Measured directly: a 1 KiB request costs about 0.65 ms of CPU in
cleartext and about 6 ms over TLS, and the TLS case is 99% CPU-bound. That
single factor accounts for the TLS rows without anything else being wrong, and
it is tracked as
[#72](https://github.com/briar-systems/hedge/issues/72). It is the largest
single lever available on hedge's TLS throughput.

**An idle QUIC listener taxes the TCP path.** A configuration that serves
HTTP/3 at all must carry a `transport = "quic"` listener, and merely having one
cuts cleartext HTTP/1.1 throughput by about 3x and raises peak RSS from 30 MiB
to over 600 MiB. Nothing sends a datagram; the cost is the serving loop bounding
its wait by the QUIC transport's deadline and advancing it every turn. Tracked
as [#71](https://github.com/briar-systems/hedge/issues/71). Every hedge row in
the results file pays this, because the benchmark serves all four protocols
from one process.

## Two rows hedge does not have

**HTTP/1.1 over TLS is missing** because hedge refuses any TLS client that
sends no ALPN extension, answering `no_application_protocol` instead of simply
not negotiating one. `oha` sends no ALPN in HTTP/1.1 mode, so every connection
in those cells was refused. curl does send ALPN, which is why the
interoperability matrix never caught it. Tracked as
[#69](https://github.com/briar-systems/hedge/issues/69).

**HTTP/2 over TLS does not work under concurrency.** One connection gets about
22 requests a second while hedge uses 18% of a core, and 16 or more connections
collapse into timeouts. Requests complete in timed bursts rather than
continuously, which is what a loop advancing on an expiring timer looks like.
Tracked as [#70](https://github.com/briar-systems/hedge/issues/70), and it is
the most serious of the four.

Both are recorded here rather than left out of the tables. A benchmark that
omits the rows a server fails is not a benchmark.

## Memory

This is the one column where the comparison is not one-sided, and it splits in
two.

Serving HTTP/1.1 and HTTP/2 with no QUIC listener, hedge idles at about 5 MiB
resident and peaks near 30 MiB under 64 connections. Caddy idles around 40 MiB
and peaks near 70 MiB. hedge's footprint is genuinely small, and its bounds are
declared rather than emergent: every collection in a configuration has a
compile-time maximum, admission reserves an entry's whole length before writing
a byte, and a disabled subsystem allocates nothing at all. `test/interop`
asserts that last part through `/proc` rather than trusting it.

Add a QUIC listener and hedge peaks above 600 MiB, roughly ten times Caddy,
before serving a single request. Whatever that preallocation is sized against,
it is not sized against a default deployment.

So: hedge is the smaller server until it serves HTTP/3, and then it is by far
the larger one.

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

hedge is not that yet. Its HTTP/2 path does not work under load, its TLS path is
an order of magnitude off because the whole toolchain is scalar, and enabling
HTTP/3 costs 600 MiB. What it has is a bounded, C-free implementation of the
whole stack with the defects above written down, filed, and measurable by
rerunning `doc/bench/run.sh` after each one closes. That is the state, and these
numbers exist so the next run can be compared to them.
