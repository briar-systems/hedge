# Configuration model

Hedge configuration describes desired server state. It does not contain imperative startup steps.

## Sources

The primary document is TOML. A deployment may provide explicit environment substitutions and secret providers.

Configuration accepts no arbitrary code. Application modules are build-time dependencies selected by the site artifact.

Includes use a top-level `include = ["base.toml"]` array. Included documents are loaded before the including document and duplicate named objects are rejected. Include depth and source size are bounded. Missing sources and include cycles are configuration errors.

General string fields may use an exact `${ENV:NAME}` reference. Resolution is explicit through the loader's environment resolver. Missing and oversized values fail validation. Secret values use the typed secret provider model below and are never interpolated into the general graph.

## Top-level model

```toml
[server]
name = "example"

[[listener]]
name = "public-tcp"
address = "[::]:443"
protocols = ["http/1.1", "h2"]
tls = "public"
backlog = 512
accept_depth = 16

[[listener]]
name = "edge"
address = "[::]:8443"
protocols = ["http/1.1", "h2"]
tls = "public"
proxy_protocol = "required"
trusted_peers = ["10.0.0.0/8"]

[tls.public]
identity = [
  { server_name = "example.com", certificate = "certs/example.pem", key = "certs/example.key" },
  { server_name = "*.example.com", certificate = "certs/wild.pem", key = "certs/wild.key" },
]
default = "example.com"

[host.example]
listener = "public-tcp"
names = ["example.com", "www.example.com", "*.cdn.example.com"]

[[route]]
name = "assets"
host = "example"
path = "/assets/**"
service = "assets"

[[route]]
name = "application"
host = "example"
path = "/**"
service = "application"

[service.assets]
kind = "static"
root = "./public"

[service.application]
kind = "laurel"
application = "site"
```

A `laurel` service names an application that the embedding program registers before startup. The program assembles the laurel application, binds it with `hedge.service.laurel.make`, registers `bound_handler` under that name in a `service.Applications` it owns, and passes the registry as `composition.Options.applications`. Composition resolves every `laurel` service against that registry at startup and again at each reload, so the registry and every application in it must stay live and unchanged until `composition.stop` returns. The program also owns the application's lifecycle, so it starts the application before `composition.start` and drains and stops it after `composition.stop`. A configuration that names an unregistered application fails with `no application is registered under this name`. Register an application with the request memory it needs (see [Request memory](#request-memory)). A laurel application's per-request state alone is several kilobytes before its sessions, forms and response bodies.

A laurel handler that waits on a request body suspends rather than blocking. The adapter reports the request as pending, the connection keeps reading, and when the body advances the adapter resumes laurel at the step that suspended: the handler is entered once however many reads its body takes. A suspended request holds its exchange, its request memory and one of the application's `max_active_requests` slots until it finishes, so a body that never arrives is bounded by the listener's request timeout rather than by the application. A connection that dies while a handler is suspended is abandoned through laurel, which runs every middleware exit half that is owed before the request's context is released.

The implemented schema accepts these top-level sections:

- `server` with bounded `limits`, `timeouts`, and feature selection
- `listener` arrays with `tcp`, `local` or `quic` transport and explicit
  protocol sets. A `quic` listener binds a UDP endpoint, becomes ready, and
  serves HTTP/3 to clients that select `h3` through ALPN inside QUIC
- named `tls`, `host`, `service`, `budget`, and `secret` tables
- direct `route` arrays or named `routes` groups
- bounded `telemetry` and isolated `admin` policy
- `cache` policy and `acme` certificate management

Every collection has a compile-time upper bound. Every string is copied into generation-owned bounded storage. A configuration that exceeds a bound fails before publication.

## Workers

hedge runs a supervisor and one worker per CPU. The supervisor takes the
signals, reloads the configuration, drives ACME and maintains the TLS policies.
Each worker serves connections on a thread of its own, with its own io runtime,
listeners, timers, buffer pool and proxy pools.

```toml
[server]
name = "example"
workers = 8
pin_workers = true
```

- `server.workers` is how many workers serve. It defaults to one per CPU the
  process may run on, and a process runs at most 256.
- `server.pin_workers` pins worker `i` to the `i`th CPU the process may run on.
  It defaults to true. Where pinning is unsupported or refused, the workers run
  unpinned and startup says so once. A single worker is never pinned.
- Both are fixed at startup, so a reload that changes either is refused.

How connections reach the workers depends on what the platform can do:

- On Linux every worker binds its own socket for each TCP listener with
  `SO_REUSEPORT`, and the kernel spreads connections across them.
- Elsewhere, and for local listeners, one worker has to accept and hand each
  connection to another, which waits on mach-std#891. Until then such a
  process runs one worker, and startup says why.
- A QUIC listener is served by the first worker until connection IDs route
  datagrams across workers (#174).
- While the cache is enabled, one worker serves, until the cache store is shared
  between threads (#285).

The caps stay process-wide. `max_connections`, `max_handshakes` and every
budget's `concurrency` and `memory_bytes` are held as per-worker allowances
drawn in batches from one shared pool, so the total never exceeds the cap. A
worker can refuse while another holds allowance it is not using, which is
bounded by the worker count times the batch. The per-peer caps are counted
across every worker. `server.limits.memory_bytes` sizes each worker's buffer
pool.

## TLS policies

A `tls` policy names the credentials one listener serves. The single-pair form
sets `certificate` and `key` to PEM paths, with an optional `server_name`; the
`identity` form is a table array of the same three keys and is what a listener
serving several names uses. `default` names the identity a client reaches when
its server name matches none of them. Omitting `default` is a policy decision,
not an oversight: an unmatched server name is then refused with
`unrecognized_name` rather than served somebody else's certificate.

`client_auth` requires and verifies a client certificate against `client_trust`.

Session resumption is disabled unless the policy contains a `resumption` table:

```toml
[tls.public.resumption]
key_lifetime_seconds = 3600
retirement_overlap_seconds = 1800
ticket_lifetime_seconds = 7200
replay = "single_use"
tickets_per_connection = 2
```

All three durations are positive seconds bounded at seven days, and one
connection may receive between one and four tickets. The retirement overlap may
span at most three key lifetimes, because the bounded four-key ring owns one
current key and at most three retired keys. A sealing key rotates before the
first handshake after its lifetime and remains usable only for the configured
retirement overlap. A ticket is usable for the shorter of its own lifetime and
the opening life of the key that sealed it.

`replay` is `permissive` or `single_use`. The default inside an enabled table is
`permissive`: Hedge implements no early data, so presenting a ticket cannot
replay an HTTP request, and allowing reuse matches common TLS client behavior.
`single_use` instead admits one presentation in a bounded 512-entry window. A
second presentation falls back to a full authenticated handshake rather than
failing the connection. The other defaults are the values in the example.

Each secure listener publishes its own immutable credential generation, and its
ALPN offer is that listener's protocol set in the listener's own order, so two
listeners sharing one certificate but serving different protocols do not share
one published generation. A connection pins the generation it handshook under
for its whole life, so rotation reaches new connections without disturbing
established ones.

Certificate material comes from files. Credentials obtained at runtime are not
expressible in this schema yet.

## The PROXY protocol

`proxy_protocol` is `off`, `optional`, or `required`. Decoding is only ever
believed from a peer named in `trusted_peers`, which takes IP addresses or CIDR
prefixes; a header from any other peer is refused rather than believed, because
believing it would let any client assert an arbitrary source address to every
policy downstream. Decoding without a trusted peer is a configuration error.

A decoded peer replaces the observed one for request metadata, so logging,
routing, and forwarded headers all name the same client. Both the v1 text and v2
binary forms are accepted, and a malformed header closes the connection rather
than being read as the start of a request.

Each listener configures a native `backlog` and a pre-submitted `accept_depth`. Defaults are 256 and 8. Backlog is limited to the native signed 32-bit range. Accept depth is limited to 64 per listener. Process-wide connection and per-peer limits come from `server.limits` and are reloadable.

A QUIC listener sizes its UDP socket's buffers with `receive_buffer_bytes` and `send_buffer_bytes`. When they are absent it asks for 4 MiB to receive and 1 MiB to send, because the kernel default (212 KiB on Linux, about 166 full-size datagrams) overflows under a burst of handshakes, and every dropped Initial costs a client a retransmission timeout. The kernel decides what it grants: Linux doubles the request and caps it at `net.core.rmem_max` and `net.core.wmem_max`. So hedge reads the size back and logs both at startup, as `hedge: socket buffers <listener> receive <granted> (asked <requested>) send <granted> (asked <requested>)`. If the granted size is well below the request, raise those sysctls. Either key on a TCP or local listener is a configuration error, as are zero and sizes past the native signed 32-bit range. Changing either needs a restart, like `backlog`, because the size is applied when the socket is bound.

A QUIC listener remembers the nonce of every Retry token it accepts until the token's age passes, so that a replayed token is refused. `max_retry_replay` bounds how many it remembers, 65536 by default. Each remembered nonce costs roughly 120 to 150 bytes in the listener's replay store, so the default bounds the store near 10 MiB. A reload briefly holds two stores, one for the outgoing generation and one for the new. While the store is full, an Initial carrying a Retry token is dropped rather than refused, and the client's retransmission is admitted once older nonces expire. Each such drop counts in `hedge_quic_retry_replay_full_total`. The key is refused on TCP and local listeners, and so is zero. A reload applies a changed value to the connections that arrive afterwards.

`server.limits.max_connections` is optional and absent by default. For TCP and
local listeners, connection storage grows with what is actually connected, so
leaving it out does not mean an unbounded server: it means the ceiling is the
descriptor table and the memory the allocator will give, rather than a number
an operator has to guess and then keep raising. Setting it makes it a policy
cap on every transport, and admission refuses past it exactly as a preallocated
pool did. A value of zero is a configuration error, not a way to spell no
limit, and is reported rather than accepted.

QUIC listeners grow the same way. A QUIC connection's record, its assembly and
TLS storage, its HTTP/3 session, its routes, its timer and any initial packet
queued for it are all claimed as the connection is admitted and given back when
it retires, so a server with a QUIC listener and no configured
`max_connections` is no more capped on HTTP/3 than it is on TCP, and an idle
QUIC listener holds none of that storage.

Under memory pressure an absent limit moves the refusal from a known number to
an unpredictable one. A connection the allocator cannot find storage for is
refused, not stalled and not crashed. Which layer refuses decides what the
client sees. When the listener cannot grow its pool the accepted socket is
closed abortively and the admission lease it took is returned, so the peer sees
a reset rather than a hang. When the listener admitted it but the serving pool
cannot grow, the connection is closed the same way and counted as rejected.
Storage already held by live connections is never disturbed to make room, so a
refusal costs the connection that arrived and nothing that is already being
served.

Both limits are reloadable. Neither sizes any storage, so a reload retunes them
like any other policy value. Lowering one below what is already connected stops
new admissions rather than evicting connections that are already being served.

`server.limits.max_connections_per_peer` defaults to 100 and is charged against
the address the transport reported when the connection was accepted, which is
before any PROXY header has been read. On a listener that decodes the PROXY
protocol that address is the hop rather than the client, so every connection
arriving through one load balancer, reverse proxy or NAT shares a single peer's
allowance. Size this bound for the topology in front of the listener, not for
the clients behind it. Charging it against the decoded source instead is #78.

`server.limits.max_handshakes` bounds the QUIC connections the process holds
admitted but not yet established. It is always set: the default is 256, and the
value in force is logged at startup. Past it, a token-bearing Initial waits in
the pending queue in arrival order and takes a slot when a handshake completes
or fails. The worker takes one unit of handshake work per turn and reads its
sockets between the Retries it sends, so a burst is read from the socket at
read speed rather than at the rate the crypto allows: an Initial the socket
delivered is held in the worker's own arrival queue, one socket buffer's worth
of them per listener, until its turn to be validated. Past that the queue
gives up, in order, a duplicate of a datagram it already holds, a version
negotiation, a first flight the server has not answered, and only then a
token-bearing Initial: a client that has answered a Retry has paid a round trip
and the server a token, so a full queue drops a first flight to hold its token
Initial rather than the other way round. The drop is counted in
`hedge_quic_arrivals_dropped_total{class}` (`token`, `untoken`, `other`,
`duplicate`) for the client's retransmission to carry. An Initial waits under its own `handshake_ms` deadline, which
counts from arrival whether it waits or not. One that the queue ahead of it
would carry past that deadline, at the cost per handshake the worker is
measuring, is turned away on arrival rather than started late, and so is one
whose turn comes with no time left. The refusal is a stateless
`CONNECTION_CLOSE` with `CONNECTION_REFUSED` under the Initial keys, so the
client learns within one round trip and can move on rather than retransmit
into its own timeout.
`server.limits.max_handshakes_per_peer` is absent by default and stops one
address holding the whole bound. Both are reloadable, and neither sizes
storage. Retries, version negotiation and established connections do not count
against them. The admission series are `hedge_quic_handshakes_in_flight`,
`hedge_quic_handshake_service_ns` (the running worker cost per handshake the
deadline rule charges for the work ahead of an Initial),
`hedge_quic_handshake_finish_ns` (the running wall time a promoted handshake
takes to reach established, which the rule requires a record to have left at
its turn, so none is promoted only to expire),
`hedge_quic_handshakes_deferred_total`, `hedge_quic_handshakes_promoted_total`,
`hedge_quic_handshakes_completed_total` (promoted handshakes that reached
established, so promoted minus completed minus in flight is what ended early),
`hedge_quic_handshakes_dropped_total`, `hedge_quic_handshakes_refused_total`
and `hedge_quic_handshakes_expired_total` (promoted handshakes that ended on
their own deadline, crypto spent and the client told nothing),
and `hedge_quic_retries_dropped_total` counts the Retries a pump dropped at its
stateless send ceiling. `hedge_quic_connections` is a gauge of the QUIC
connections the server holds, from admission until the record is released,
which for a connection the peer closed is after its draining period.

`server.limits.max_pipeline_depth` bounds HTTP/1 requests admitted into one
connection before earlier responses release their slots. The default and fixed
storage maximum are both 2. A value above 2 is rejected during validation rather
than accepted and silently clamped. When both slots are occupied, the HTTP/1
engine reports saturation and leaves later bytes in its bounded read buffer
until a slot is released.

## Request memory

Each request gets its own memory, which the services that handle it allocate from.
That memory is not reserved in advance. It is claimed in chunks of at least 16 KiB
as the request asks for it, and every chunk is returned for reuse when the request
settles, so an idle connection holds none and a request holds only what it used.

What bounds a request is how many bytes of chunk it may hold:

- `server.limits.call_memory_bytes` is the bound for every request until a route
  is selected, and for any service that does not say otherwise. It defaults to
  32768 (32 KiB).
- A registered application declares what it needs when it is registered, as the
  last argument to `service.register_application`. A `laurel` service uses that
  declaration instead of the server bound.
- `service.<name>.memory_bytes` overrides both, for a service whose needs depend
  on how it is configured.

Every bound must be between 16384 (16 KiB) and 268435456 (256 MiB). A request
budget's `memory_bytes` is charged this bound, not what the request goes on to use,
because the charge is taken before the handler runs.

A request that runs out is not silent. The allocation that failed is refused, and
the service answers however it answers a failed allocation. The request is then
logged as an error with `code = "memory_exhausted"`, naming the route and the
bound it hit, and `hedge_request_memory_refusals_total` counts it.

## Connection memory

Every buffer a connection uses comes from its worker's buffer pool: TLS records,
read and write buffers, and each request's parsed head. Nothing is reserved per
connection up front. Each connection instead opens an account on the pool with
a budget, and borrows against it as it needs memory.

- `server.limits.memory_bytes` is the pool's total budget, for each worker's
  pool. It defaults to
  `max_connections` connections' worth, or 256 connections' worth when
  `max_connections` is not set.
- `server.limits.connection_memory_bytes` is what one connection may hold. It
  defaults to what its fixed lanes need plus `max_pipeline_depth` requests at the
  configured header limits.

A connection's budget is split into lanes:

- the TLS lane gets 64 KiB, for record and handshake buffers.
- the I/O lane gets 64 KiB, for the read and write buffers of whichever protocol
  engine runs.
- the request lane gets the rest, for per-request memory such as a parsed HTTP/1
  head (target, fields and trailers) or an HTTP/2 or HTTP/3 stream.
- QUIC names its own send and receive lanes, sized by the QUIC engine.

Loading fails when `connection_memory_bytes` cannot fund both fixed lanes and one
request, when `memory_bytes` is smaller than one connection, or when
`max_connections` connections at `connection_memory_bytes` would exceed
`memory_bytes`.

When the pool runs short, hedge sheds load on purpose, so the connections it
already holds can finish:

- A new connection is admitted only while the pool's reservations stay under
  seven eighths of `memory_bytes`. The rest is headroom for open connections. A
  refused TCP connection is closed, and a refused QUIC Initial is dropped.
- On an open connection, HTTP/2 refuses a new stream with REFUSED_STREAM and
  HTTP/3 with REQUEST_REJECTED. HTTP/1 and TLS wait for memory.
- A connection that waits for memory longer than `server.timeouts.header_ms` is
  closed.

`hedge_memory_held_bytes`, `hedge_memory_refusals_total` and
`hedge_memory_timeouts_total` report each lane, labelled `lane`.
`hedge_connections_refused_memory_total` counts refused connections.

## Budgets

A named `budget` carries four bounds, and a listener that names one is held to
all of them:

- `concurrency` is how many connections it may serve at once
- `queue` is how many more may be accepted and made to wait for a turn
- `timeout_ms` is how long one of those may wait before it is closed
- `memory_bytes` is how many bytes the work may hold at once

A budget is charged before the work it authorises and released exactly once when
that work ends, so admitting something and then finding there is no room for it
cannot happen. A connection holding a place in a queue is accepted but not
served: that is what makes the queue a queue rather than a label. A charge larger
than the whole budget is refused rather than queued, because no amount of other
work finishing would make room for it.

A seam with no budget configured is not a seam with a budget of zero. It is
admitted without accounting.

A route is charged against the most specific budget that names it: its own,
otherwise the budget of the service it dispatches to, otherwise the budget of its
virtual host. The charge is taken after the route is selected and before the
handler runs, and a request refused for want of budget is answered
`503 Service Unavailable` rather than dropped. A proxy service that names a
budget also bounds the requests it may have in flight to its upstreams by that
budget's concurrency.

## Shutdown

Shutdown runs one ordered sequence: readiness goes false, the listeners stop
accepting, each protocol engine is asked to close gracefully — HTTP/2 sends
GOAWAY, HTTP/1 marks its responses for close and stops reading — exchanges
already in flight are given until the `drain_ms` deadline to finish, whatever
remains is cancelled, telemetry is flushed, and the resources are released last.

The exit status reports which of those happened. A clean drain exits 0. A drain
whose deadline passed with exchanges still running exits 75 and names how many
were abandoned, because that is not a clean shutdown even though it is a
complete one. A step of the sequence failing exits 70 and names the step.

Cancelling closes each remaining connection, and the stop waits for those closes
under `server.timeouts.stop_ms` (default 10000, 10 seconds). The deadline
starts when the wait does and starts again each time a connection closes, so a
stop with many connections only fails if none closes for that long. When it passes, the stop gives up
rather than waiting on a close that never finishes. The process exits 70 and
prints each TCP connection still open with what its close waits on, and how many
QUIC connections are still open. The same deadline bounds the wait for the
service planes to quiesce and for the QUIC runtime's release.

`SIGHUP` reloads the routing graph. The configuration is re-read, validated and
sealed into a second generation, a new plan is compiled beside the running one,
and connections accepted after it use the new plan. Connections accepted before
it keep the plan and generation they began under and are asked to finish, so a
superseded generation drains independently of the one that replaced it. A second
reload is deferred until the previous generation has drained, so only one
superseded generation exists at a time.

A reload changes routes, virtual hosts, budgets and service definitions. Each
plan bank owns its static roots, proxy routes and cache bindings. Connections
accepted before publication retain that complete service generation while they
drain. Only after its final connection closes are its roots, idle upstream
connections and binding slots released for reuse. Repeated reloads therefore
alternate between two bounded banks rather than appending service state.

Process-owned state still requires a restart. That includes feature selection,
TLS policy, secrets, telemetry, cache storage, ACME, administration, the server
name and process-wide connection limits. A reload may change plaintext listener
policy and may rebind a secure listener without changing its name, TLS policy or
protocol set. An unchanged listener set leaves the sockets untouched.

A host names itself with either `server_name` for a single name or `names` for several; declaring both is a conflict, and declaring neither uses the host block's own key as its name. Every name a host declares is a name it answers to, and each is compiled into its own routing pattern, so a host with three names serves all three rather than only the first. A name may be an exact host, a `*.suffix` wildcard, or carry an explicit port.

Precedence between names is by specificity and never by the order they are written: an exact name beats a wildcard suffix, a longer suffix beats a shorter one, and a pattern naming a port beats one that does not. Two hosts that claim the same name for the same path are refused at configuration time rather than one shadowing the other.

Services support `static`, `proxy`, `laurel`, `fixed`, `redirect`, and `native` kinds. Secret providers support `env`, `file`, `os`, and `application`. Availability is supplied as a target and build capability set, so unsupported providers and transports are rejected before construction.

Two of those kinds answer without touching a filesystem or an upstream. `fixed` returns one body to every request, and `redirect` returns a location.

```toml
[service.greeting]
kind = "fixed"
body = "hello from hedge\n"
content_type = "text/plain; charset=utf-8"

[service.docs]
kind = "redirect"
target = "https://example.test/docs/"
status = 308
```

A `fixed` service defaults to status 200 and `text/plain; charset=utf-8`. A `redirect` defaults to 302 and accepts 300 through 308, so a permanent redirect states its 301 or 308 explicitly.

## Automatic certificate management

```toml
[server.features]
acme = true

[acme]
directory = "https://acme-v02.api.letsencrypt.org/directory"
trust = "/etc/ssl/certs/ca-certificates.crt"
contact = "mailto:ops@example.com"
terms_agreed = true
storage = "/var/lib/hedge/acme"
listener = "public"
names = ["example.com", "www.example.com"]
challenge = "http-01"

[service.acme]
kind = "native"
target = "acme-challenge"

[[route]]
name = "acme"
host = "example"
path = "/.well-known/acme-challenge/**"
service = "acme"
```

One account and one certificate covering every configured name. Up to eight
names, which is what the durable record holds. `storage` is a directory the
process owns: it is created with owner-only permissions and every file in it,
including both private keys, is written owner-only and replaced atomically.

`listener` names the TCP listener with the TLS policy that owns the live
credential generation. Hedge copies a verified ACME chain and PKCS#8 key into
that listener before it begins serving, then rotates later renewals in the
same listener-owned two-bank store. Existing connections keep their leased
generation while new handshakes use the replacement.

`renew_before` is the lead, in seconds, before expiry at which a certificate is
renewed. It defaults to thirty days, which suits the ninety-day certificates
public authorities issue, and is bounded at one year.

`challenge` selects `http-01`, `dns-01`, or `tls-alpn-01`.

`http-01` requires a route to the native `acme-challenge` service, and a
configuration that enables `http-01` without one fails to load rather than
discovering it at the first renewal. The route must be reachable on port 80 for
the names being validated.

`dns-01` needs something that can write a zone. Hedge does not carry provider
integrations, so an embedder supplies a publisher through
`acme.open_with_publisher` and gets everything else unchanged. A TOML-only
deployment that selects it fails to load.

`tls-alpn-01` answers RFC 8737 through the named secure listener. During one
validation Hedge presents a transient certificate only when the client offers
`acme-tls/1` and its SNI exactly matches the authorization name. Its critical
`acmeIdentifier` extension is accepted only by that explicit challenge path;
ordinary TLS handshakes continue to select the listener's configured
certificate.

`trust` names a PEM anchor bundle used to authenticate every HTTPS URL the
authority publishes. A public deployment normally points it at the operating
system's CA bundle. Roots using algorithms outside this verifier are excluded
from the in-memory store. A missing, empty, truncated, undecodable, or wholly
unsupported bundle fails manager construction rather than opening an
unverified connection.

The authority client accepts ECDSA-SHA384 signatures from P-384 issuers. P-384
is a chain-verification algorithm here, not a key-exchange group or a local
client identity. The public staging check covers that WebPKI path, while local
Pebble issuance covers the complete authenticated transport and issuance path.

`origin` is how a local authority is reached: a `host:port` spoken to in
cleartext, for an authority whose URLs still say `https` because the protocol
requires it. It applies to the one configured authority and nothing else, and
cannot be combined with `trust`. Without either setting an `https` directory is
refused rather than silently reached in cleartext or without verification. A
conformance stack that terminates TLS in front of the authority and passes
every ACME byte through unchanged is exactly what `origin` is for.

Renewal is driven from the serving loop. A certificate inside its renewal lead
is renewed with jitter so a fleet does not renew in lockstep; a failure backs
off within a ceiling against a fixed attempt budget; and a clock that moves
backwards replans rather than firing. With `acme` disabled nothing is
allocated, no directory is opened, and the serving loop takes no ACME step.

## Telemetry and administration

```toml
[[listener]]
name = "admin"
address = "127.0.0.1:9090"
protocols = ["http/1.1"]

[secret.admin-token]
provider = "env"
key = "HEDGE_ADMIN_TOKEN"

[telemetry]
logs = true
metrics = true
traces = true
log_record_bytes = 2048
log_queue_depth = 256
metric_series = 1024
trace_state_bytes = 512

[admin]
enabled = true
listener = "admin"
auth_secret = "admin-token"
max_response_bytes = 8192
```

Log records use bounded structured fields and an atomic sink contract. Queued sinks must use exactly `log_queue_depth` caller-owned slots, must reject or drop on overload, and must provide a shutdown flush operation. Request progress never accepts a blocking overload policy. `log_record_bytes` is limited to 8192.

Metric storage is caller-owned and fixed at `metric_series`, which must cover at least the 38 built-in series. A metric has at most eight sorted labels. Label names and values, histogram buckets, counters, and rendered administration output are bounded. Registration fails when the series budget is exhausted and exposes the rejection count.

Trace propagation accepts strict W3C `traceparent` version 00 and bounded `tracestate`. An invalid or oversized `tracestate` is discarded without breaking a valid `traceparent`, as required by the W3C processing model. Trace IDs and span IDs use operating-system entropy. `trace_state_bytes` cannot exceed 512. Export is an application integration and is not configured by Hedge.

The administration listener cannot be referenced by a public virtual host. Authentication runs after listener identity is checked and before endpoint dispatch. The `env` and `file` secret providers resolve in the binary. Embedded deployments may supply `os` and `application` providers through the typed resolver contract. Resolved administration credentials are limited to 512 bytes, reject line breaks, remain in one production owner, and are cleared at shutdown.

The administration service exposes `GET /live`, `/ready`, `/metrics`, and `/state`. Liveness reports fatal process health. Readiness additionally requires accepting state, no active drain, and every required health check.

## Caching

```toml
[cache]
enabled = true
memory_bytes = 8388608
disk_bytes = 268435456
disk_root = "/var/cache/hedge"
max_entry_bytes = 1048576
entries = 256
heuristic_percent = 0

[service.assets]
kind = "static"
root = "./public"
cache = true
```

Caching is off by default and is opted into twice: once for the process with `cache.enabled`, and once for each service with `service.<name>.cache`. A service that does not ask for it is never wrapped, so it does not carry so much as a branch per request. With `cache.enabled` false nothing is constructed at all: no entry table, no body arena, no cache root handle, no worker, and no timer.

`memory_bytes` and `disk_bytes` are exact bounds, not targets. Admission reserves an entry's whole declared length before a byte is written and evicts least-recently-used entries until it fits, so the budget holds at every instant rather than on average. An entry longer than `max_entry_bytes` is refused outright. `entries` bounds the entry count independently of the byte budgets.

Size `entries` against the authorities clients actually use, not against the number of routes. A cache key includes the scheme and the authority the request carried, so one representation is stored once per name it is reached by. A host declaring three names holds three entries for the same file if clients use all three, and a `*.example.com` host holds one entry per distinct subdomain requested rather than one for the wildcard. `Vary` multiplies again on top of that, once per distinct combination of selecting values. None of this is visible from the route count, and running out of entries evicts rather than fails, so an undersized `entries` shows up as a hit rate that quietly falls instead of an error.

A representation larger than a quarter of the memory budget goes to disk when `disk_bytes` and `disk_root` are set. Cache file names come from an internal counter and never from request data. A graceful shutdown removes every file the store wrote; starting up removes any file a killed process left behind, so the disk bound holds across a crash. Only names the store's own counter could have produced are removed.

`heuristic_percent` is the fraction of a representation's age at its `Last-Modified` that a response with no explicit freshness may be assumed fresh for, capped at one day. It defaults to zero, which means a response that states no freshness of its own is not stored.

Hedge is a shared cache. `private`, `no-store`, `Vary: *`, an authorized request without an explicit invitation, and a `206 Partial Content` are all refused. A response carrying `Set-Cookie` is refused unless the origin named that field in a qualified `private="set-cookie"` or `no-cache="set-cookie"`, in which case the field is dropped and the rest of the representation is stored. Fields a qualified directive names are never stored, and hop-by-hop fields never cross into an entry.

A stored entry answers a request only when every field named by the response's `Vary` holds the same value it held for the request that produced the entry. A conditional request and a single byte range are both answered out of the store without reaching the service.

## Validation

Validation resolves:

- listener address conflicts
- protocol and TLS compatibility
- certificate coverage and key compatibility
- route precedence and unreachable routes
- filesystem roots and permissions
- upstream addresses and health policies
- cache and buffer budgets
- timeout relationships
- telemetry destinations
- telemetry storage dimensions and administration isolation
- application provider requirements

Unknown fields are errors. Deprecated fields produce actionable diagnostics and follow a published removal policy.

Diagnostics retain severity, stable code, source, field path, and message. The loader reports unknown fields, wrong types, missing values, duplicate names, address conflicts, unresolved references, unreachable routes, unsupported capabilities, include failures, and resource-bound violations in one bounded diagnostic set.

## Reload

Reload parses and validates a complete candidate configuration. It then constructs candidate certificates, route graphs, upstream pools, caches, and listeners, and resolves application services against the registry supplied at startup.

Activation is atomic. If any required component cannot be constructed, the current generation remains active. Diagnostics identify the candidate source and never mutate current state.

The listener owner binds every candidate TCP, UDP, IPv4, IPv6, and local endpoint before activation. It reserves the configured accept depth before readiness. On successful publication it cancels and closes only the replaced listeners. Connections retain the generation under which they were accepted. A failed bind or accept reservation closes the candidate without changing the active generation or its connections.

The generation store publishes only sealed candidates. Parsing, resolution, validation, and caller-supplied resource construction all complete before the pointer exchange. Readers retain a generation through an atomic publication gate. Replaced generations drain until their last retained reference is released. Failed attempts are observable through attempt count, failure count, candidate identity, and structured failure code.

## Secrets

TOML can reference a secret by provider and key. Secret values are not interpolated into the general configuration tree and never appear in rendered diagnostics.

Providers may include restricted files, environment delivery, operating-system stores, and application-defined services. Provider support is explicit per target.

## Lightweight behavior

Disabled sections create no worker, timer, cache, or background task. Default configuration does not enable proxying, caching, ACME, admin networking, templates, or application sessions.
