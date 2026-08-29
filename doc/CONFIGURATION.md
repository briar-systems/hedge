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
server_name = "example.com"

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

Each listener configures a native `backlog` and a pre-submitted `accept_depth`. Defaults are 256 and 8. Backlog is limited to the native signed 32-bit range. Accept depth is limited to 64 per listener. A named listener `budget` limits its accepted connections. Process-wide connection and per-peer limits come from `server.limits` and require restart to change.

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
