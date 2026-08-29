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

The implemented schema accepts these top-level sections:

- `server` with bounded `limits`, `timeouts`, and feature selection
- `listener` arrays with `tcp` or `local` transport and explicit protocol sets.
  `quic` parses, and is refused before listeners become ready because this build
  composes no QUIC connection driver: a datagram listener would bind and then
  answer nothing
- named `tls`, `host`, `service`, `budget`, and `secret` tables
- direct `route` arrays or named `routes` groups
- bounded `telemetry` and isolated `admin` policy

Every collection has a compile-time upper bound. Every string is copied into generation-owned bounded storage. A configuration that exceeds a bound fails before publication.

## TLS policies

A `tls` policy names the credentials one listener serves. The single-pair form
sets `certificate` and `key` to PEM paths, with an optional `server_name`; the
`identity` form is a table array of the same three keys and is what a listener
serving several names uses. `default` names the identity a client reaches when
its server name matches none of them. Omitting `default` is a policy decision,
not an oversight: an unmatched server name is then refused with
`unrecognized_name` rather than served somebody else's certificate.

`client_auth` requires and verifies a client certificate against `client_trust`.

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

Each listener configures a native `backlog` and a pre-submitted `accept_depth`. Defaults are 256 and 8. Backlog is limited to the native signed 32-bit range. Accept depth is limited to 64 per listener. Process-wide connection and per-peer limits come from `server.limits` and require restart to change.

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

Route, service, host, and application budgets parse and validate today and are
not yet charged.

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

A reload publishes new listeners and a new plan for the connections accepted
after it. Connections accepted before it keep the plan and generation they began
under and are asked to finish, so a superseded generation drains independently of
the one that replaced it.

A host names itself with either `server_name` for a single name or `names` for several; declaring both is a conflict, and declaring neither uses the host block's own key as its name. Every name a host declares is a name it answers to, and each is compiled into its own routing pattern, so a host with three names serves all three rather than only the first. A name may be an exact host, a `*.suffix` wildcard, or carry an explicit port.

Precedence between names is by specificity and never by the order they are written: an exact name beats a wildcard suffix, a longer suffix beats a shorter one, and a pattern naming a port beats one that does not. Two hosts that claim the same name for the same path are refused at configuration time rather than one shadowing the other.

Services support `static`, `proxy`, `laurel`, `fixed`, `redirect`, and `native` kinds. Secret providers support `env`, `file`, `os`, and `application`. Availability is supplied as a target and build capability set, so unsupported providers and transports are rejected before construction.

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
endpoint = "https://collector.example/v1/traces"
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

Metric storage is caller-owned and fixed at `metric_series`. A metric has at most eight sorted labels. Label names and values, histogram buckets, counters, and rendered administration output are bounded. Registration fails when the series budget is exhausted and exposes the rejection count.

Trace propagation accepts strict W3C `traceparent` version 00 and bounded `tracestate`. An invalid or oversized `tracestate` is discarded without breaking a valid `traceparent`, as required by the W3C processing model. Trace IDs and span IDs use operating-system entropy. `trace_state_bytes` cannot exceed 512.

The administration listener cannot be referenced by a public virtual host. Authentication runs after listener identity is checked and before endpoint dispatch. It exposes `GET /live`, `/ready`, `/metrics`, and `/state`. Liveness reports fatal process health. Readiness additionally requires accepting state, no active drain, and every required health check.

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

Reload parses and validates a complete candidate configuration. It then constructs candidate certificates, route graphs, upstream pools, application instances, caches, and listeners.

Activation is atomic. If any required component cannot be constructed, the current generation remains active. Diagnostics identify the candidate source and never mutate current state.

The listener owner binds every candidate TCP, UDP, IPv4, IPv6, and local endpoint before activation. It reserves the configured accept depth before readiness. On successful publication it cancels and closes only the replaced listeners. Connections retain the generation under which they were accepted. A failed bind or accept reservation closes the candidate without changing the active generation or its connections.

The generation store publishes only sealed candidates. Parsing, resolution, validation, and caller-supplied resource construction all complete before the pointer exchange. Readers retain a generation through an atomic publication gate. Replaced generations drain until their last retained reference is released. Failed attempts are observable through attempt count, failure count, candidate identity, and structured failure code.

## Secrets

TOML can reference a secret by provider and key. Secret values are not interpolated into the general configuration tree and never appear in rendered diagnostics.

Providers may include restricted files, environment delivery, operating-system stores, and application-defined services. Provider support is explicit per target.

## Lightweight behavior

Disabled sections create no worker, timer, cache, or background task. Default configuration does not enable proxying, caching, ACME, admin networking, templates, or application sessions.
