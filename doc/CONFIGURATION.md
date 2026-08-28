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
name = "public-quic"
address = "[::]:443"
transport = "quic"
protocols = ["h3"]
tls = "public"

[tls.public]
certificate = "acme:example"

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
- `listener` arrays with `tcp`, `quic`, or `local` transport and explicit protocol sets
- named `tls`, `host`, `service`, `budget`, and `secret` tables
- direct `route` arrays or named `routes` groups
- `telemetry` sinks

Every collection has a compile-time upper bound. Every string is copied into generation-owned bounded storage. A configuration that exceeds a bound fails before publication.

Each listener configures a native `backlog` and a pre-submitted `accept_depth`. Defaults are 256 and 8. Backlog is limited to the native signed 32-bit range. Accept depth is limited to 64 per listener. A named listener `budget` limits its accepted connections. Process-wide connection and per-peer limits come from `server.limits` and require restart to change.

Services support `static`, `proxy`, `laurel`, `fixed`, `redirect`, and `native` kinds. Secret providers support `env`, `file`, `os`, and `application`. Availability is supplied as a target and build capability set, so unsupported providers and transports are rejected before construction.

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
