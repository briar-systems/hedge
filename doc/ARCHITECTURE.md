# Architecture

## Design rules

1. Data flows from listeners through transport, protocol, service, and response emission in one direction.
2. Each connection has one owner at every instant.
3. Every queue, buffer, parser dimension, timer, and retry policy is bounded or explicitly configured.
4. Cancellation and deadlines are part of contracts, not side channels.
5. Protocol engines do not own application policy.
6. Application handlers do not own connection state.
7. Optional capabilities add no idle work when disabled.
8. Unsupported configuration fails before listeners become ready.
9. Reload constructs and validates a complete replacement state before publishing it.
10. Errors retain structured causes until the product boundary renders or records them.

## Process model

One Hedge process contains five ownership domains:

```text
control plane
  configuration, certificates, admin, reload, shutdown

listener plane
  tcp acceptors, quic endpoints, local sockets

connection plane
  protocol selection, tls, quic, http engines

service plane
  static files, proxy pools, Laurel applications

telemetry plane
  logs, metrics, traces, health, readiness
```

The control plane publishes immutable runtime generations. A listener and every connection retain the generation under which they were created. Reload activates a new generation atomically. Old generations remain alive until their connections drain.

## Runtime generation

A generation owns:

- validated listener definitions
- virtual-host lookup tables
- route graphs
- TLS certificate sets and policies
- upstream pools and health state
- cache policy and storage handles
- application instances
- observability sinks
- resource budgets

Mutable per-connection data never enters the generation. Shared mutable services expose explicit synchronization or single-owner message contracts.

## I/O contract

Hedge consumes an operation-completion interface from `mach-std`. The contract must support readiness kernels and completion kernels without changing buffer ownership.

An operation contains:

- a stable token
- operation kind
- resource handle
- borrowed buffer with a lifetime ending at completion
- absolute deadline or no deadline
- cancellation scope
- caller context token

A completion contains:

- the same operation token
- completed byte count or accepted resource
- normalized result
- flags describing end-of-stream and truncation

Submission never implies completion. Cancellation is a request whose resolution also arrives as a completion. Buffers cannot be reused until completion resolves the operation.

Linux epoll and Darwin kqueue backends may perform nonblocking calls when readiness arrives. Windows IOCP submits native overlapped operations. The public ownership rule is identical.

## Transport contracts

### Ordered byte transport

TCP, local sockets, and TLS expose ordered byte reads and writes with:

- partial completion
- vectored I/O
- backpressure
- half-close
- absolute deadlines
- cancellation
- local and remote endpoint metadata
- negotiated protocol metadata

TLS may require reads while an application write is pending, or writes while an application read is pending. Its adapter drives handshake and record state through the same completion interface instead of exposing `want_read` and `want_write` as application concerns.

### Multiplexed transport

QUIC exposes connection and stream operations rather than pretending to be one byte stream. HTTP/3 maps its request streams and control streams directly onto that contract.

## Protocol selection

TCP connections pass through optional PROXY protocol decoding, optional TLS, and application protocol selection. Cleartext listeners select HTTP/1.1 or an explicit HTTP/2 prior-knowledge policy. TLS uses ALPN for HTTP/1.1 and HTTP/2.

QUIC listeners select HTTP/3 through TLS ALPN inside QUIC.

Each protocol engine translates its connection-specific state into the common HTTP service exchange. The common exchange supports streaming bodies, informational responses, trailers, cancellation, upgrades where the protocol permits them, and peer metadata.

## HTTP service exchange

A request exchange owns:

- immutable request head
- request body reader
- response head builder
- response body writer
- request allocator
- cancellation scope
- absolute handler deadline
- connection and security metadata
- structured telemetry context

The request allocator is reset only after request-body disposition and response completion are resolved. A handler that leaves a body unread must explicitly drain it, reject it, or make the connection non-reusable.

HTTP/1.1 processes ordered exchanges while respecting pipeline bounds. HTTP/2 and HTTP/3 process independent streams subject to connection and stream flow control. The service API does not expose those differences as mutable connection operations.

## Service dispatch

Virtual-host selection precedes route selection.

A host declares a set of names, and every one of them is a name that host answers to. A route on a host is compiled once per name, so the set is the contract rather than the first entry in it. Names within a host block are unordered: position confers no precedence, because every name of a host produces an equally specific pattern for the same route.

Precedence between patterns is by specificity, never by declaration order:

1. an exact name outranks a wildcard suffix, which outranks the any-host pattern
2. between two wildcard suffixes, the longer suffix wins
3. a pattern naming a port outranks one that does not
4. then path specificity, then method specificity, then configuration order

Only the last of those is positional, and it is reached only when two patterns are equally specific in every other respect. Two routes that compile to the same host pattern, path, and method are a configuration conflict and are refused before the generation is published, rather than one silently shadowing the other.

A route resolves to one of:

- static file service
- reverse proxy service
- load-balanced upstream service
- redirect or fixed response
- Laurel application
- native handler implementing the HTTP service contract

Middleware wraps services through explicit before, after, and error paths. The core does not build a heap-allocated chain for every request. A compiled route graph references immutable middleware plans.

## Static files

The static service owns path normalization, root confinement, index selection, metadata, conditional requests, ranges, precompressed variants, content type, cache headers, and file transfer.

Filesystem paths are never constructed by concatenating an untrusted request target. Resolution works from normalized decoded segments against an opened root. Symlink policy is explicit. File identity is revalidated when required by the platform.

Small files may use bounded memory reads. Large files use platform transfer or asynchronous file I/O when available. TLS and QUIC paths use bounded buffers because kernel file-to-socket transfer cannot cross encrypted userspace records directly.

## Reverse proxy

The proxy owns upstream selection, connection pooling, DNS refresh, health checks, retries, circuit breaking, request and response transformation, forwarded metadata, upgrade tunnelling, and backpressure.

Retries are allowed only when request replay safety is known. Body buffering is never silently enabled. Each upstream attempt receives a child deadline within the request deadline.

## Cache

Caching is an optional service layer with independent memory and disk stores. It implements HTTP cache semantics rather than path-based object reuse. Cache keys include the selected representation dimensions. Revalidation, stale policies, range handling, and authorization behavior are explicit.

## Web applications

Laurel applications receive only the common HTTP service exchange and framework services declared during composition. Hedge may supply configuration, secrets, storage, telemetry, and background-task facilities through typed providers.

Applications cannot reach listener or connection internals. Server reload can replace an application generation without invalidating exchanges already executing in the old generation.

## Configuration and reload

Configuration processing has four stages:

1. Parse source files and environment references.
2. Resolve names, files, secrets, addresses, and module selections.
3. Validate the complete graph and resource budgets.
4. Construct a sealed runtime generation.

Only the sealed generation is published. A failed reload leaves the current generation untouched. Listener transitions are planned before publication so address conflicts and unsupported socket options fail safely.

## Graceful shutdown

Shutdown proceeds through explicit states:

1. Mark readiness false.
2. Stop accepting new connections.
3. Send protocol-specific graceful signals where available.
4. Allow active exchanges to finish within the drain deadline.
5. Cancel remaining exchanges.
6. Flush bounded telemetry queues.
7. Close resources and exit with a reasoned status.

HTTP/2 uses GOAWAY. HTTP/3 closes request acceptance through its control and QUIC state. HTTP/1.1 marks responses for connection close and stops reading new requests.

## Telemetry ownership

One telemetry runtime owns the log sink contract, fixed metric registry, health checks, trace propagation bound, and administration handler for a server generation. Access and error events are encoded directly into a fixed record buffer. A direct sink completes within the call. A queued sink copies into a caller-bounded queue and reports enqueued, rejected, or dropped without waiting for space.

Metric series are registered against caller-owned storage. Tokens identify stable series, updates are atomic, and histogram samples commit bucket, count, and sum together. Rendering performs a sizing pass before writing so an undersized administration response cannot expose a partial metric document.

The administration handler has no public route access. Its listener identity and authentication callback are required policy inputs. Metrics and state renderers retain independent contexts. Shutdown makes readiness false before listener drain and invokes the telemetry flush operation exactly once.

## Lightweight composition

The product remains lightweight through structural choices:

- no garbage collector or hidden task scheduler
- no global application registry
- fixed or bounded connection bookkeeping
- immutable shared configuration
- per-feature modules linked only when selected by the build
- streaming by default
- no mandatory cache, proxy, ACME, template, or framework layer
- direct handler path with no framework allocation
- one telemetry event construction per event

Lightweight is measured with idle memory, idle wakeups, binary sections, allocations per request, and latency distributions. It is not inferred from source line count.
