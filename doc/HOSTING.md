# Hosting applications

hedge hosts applications in-process. A hosted application is Mach code linked into the same binary as hedge: hedge accepts the connections, speaks HTTP, routes each request, and calls the application's handler for the requests routed to it. The application never sees a socket, a TLS session or a protocol engine.

This document is the **host contract**: the part of hedge's public surface a hosted application, or a binding that adapts a framework to hedge, may depend on. It says which items the contract is made of, what hedge promises about each, and what it asks of the code it hosts. Anything it does not name is internal to hedge, even when it is declared `pub`.

This is **host contract version 1.7**. Version 1.1 added the outbound HTTPS client ([Outbound HTTPS](#outbound-https)), version 1.2 added background tasks ([Background tasks](#background-tasks)), version 1.3 reported where the listeners bound ([Where the listeners bound](#where-the-listeners-bound)), version 1.4 let a handler upgrade its connection ([Upgrades](#upgrades)), version 1.5 added secrets for hosted code ([Secrets](#secrets)), version 1.6 added an application's settings and the lifecycle's reload step ([Settings](#settings)), and version 1.7 adds logs, metrics and health checks from hosted code ([Telemetry](#telemetry)).

## Roles

- **hedge** is the host. It owns the process: the listeners, the workers, the configuration and its reloads, the signals, ACME, TLS and telemetry.
- **A hosted application** is a handler, and optionally a lifecycle, registered under a name. The configuration routes requests to it by that name.
- **A binding** adapts one framework's application model to this contract. [briar-systems/graft](https://github.com/briar-systems/graft) binds laurel, and it is the worked example (see [Writing a hedge binding](#writing-a-hedge-binding)). A framework needs no hedge symbol of its own. Only its binding imports hedge.
- **The embedding program** is the `main` that assembles the process: it builds the registry, hands it to hedge, and runs hedge until it stops. A binding usually supplies it.

## The contract items

These are the items of the host contract, by module. Types and constants from mach-http (`http.core.*`), mach-tls (`tls.cert.*`) and std that these items take or return are those projects' own contracts and follow their versions.

**`hedge.service`: handlers, lifecycles and the registry**

- `Handler`, `ServeFun`, `no_handler`, `has_handler`
- `Lifecycle` (its optional `reload` step since 1.6), `StepFun`, `DrainFun`, `Step`, `StepStatus`, `STEP_DONE`, `STEP_PENDING`, `STEP_FAILED`, `no_lifecycle`, `has_lifecycle`
- `Application`, `Applications`, `MAX_APPLICATIONS`, `make_applications`, `register_hosted`, `register_application`, `find_application`
- the response helpers: `commit`, `commit_bodyless`, `respond`, `respond_with_bytes`, `respond_with_text`, `add_field`, `arena_bytes`, `arena_number`, `text_view`

**`hedge.dispatch.call`: one request, as a handler sees it**

- `Call`, of which a handler reads exactly two fields, `exchange` and `telemetry`, and writes none
- the request and response: `request`, `response`, `limits`, `allocator_of`, `memory_refused`
- body ownership: `Disposition`, `BODY_DELIVER`, `BODY_DRAIN`, `BODY_REJECT`, `BODY_CLOSE`, `resolve_body`, `disposition`
- waiting: `Wait`, `WAIT_BODY`, `WAIT_WAKE`, `park`, `yield_turn`, `waker`
- cancellation: `scope`, `deadline`, `cancelled`, `entered`
- per-request state: `Finalizer`, `FinalizeFun`, `attach_finalizer`, `finalizer_state`, `detach_finalizer`
- upgrades (see [Upgrades](#upgrades)): `tunnel`, `TunnelOwner`, `no_tunnel_owner`, `TunnelFun`, `TunnelAbandonFun`, `Tunnel`, `TunnelStatus`, `TUNNEL_PENDING`, `TUNNEL_DONE`, `TUNNEL_FAILED`, of which a program writes the fields of `TunnelOwner` and `Tunnel.wake_at`, and reads the rest of `Tunnel`

**`hedge.telemetry.trace`**: `Context`, read-only, of which a handler reads `trace_id`, `parent_id` and `flags`.

**`hedge.wake`**: `Waker`, `wake`, `Posted`, `post`.

**`hedge.clock`**: `instant`, `monotonic_ns`, `to_ns`, `from_ns`, `after`, `after_ns`, `between_ns`.

**`hedge.outbound`: the outbound HTTPS client** (see [Outbound HTTPS](#outbound-https))

- the loop: `Loop`, `open_loop`, `client`, `turn`, `fetch`, `close_loop`
- the client: `Client`, `set_user_agent`, `route`, `Origin`, `no_origin`, `secure_origin`, `cleartext_origin`, `close_kept`, `MAX_CONNECTIONS`, `MAX_ROUTES`, `IDLE_NS`
- requests and responses: `Request`, `request`, `secret_header`, `Response`, `DEFAULT_TIMEOUT_NS`, `MIN_TIMEOUT_NS`
- the exchange: `Exchange`, `make_exchange`, `begin`, `poll`, `deadline`, `response`, `finish`, `idle`, `releasing`, `destroy_exchange`, `stage`, `cause`, `tls_failure`
- outcomes: `Status`, `OK`, `PENDING`, `FAILED`, `INVALID`, `Stage` and its values (`IDLE`, `QUEUED`, `RESOLVING`, `CONNECTING`, `HANDSHAKING`, `WRITING`, `READING`, `COMPLETE`, `BROKEN`), `Cause` and its values (`CAUSE_NONE`, `CAUSE_ADDRESS`, `CAUSE_CONNECT`, `CAUSE_WRITE`, `CAUSE_READ`, `CAUSE_PROTOCOL`, `CAUSE_TOO_LARGE`, `CAUSE_TIMEOUT`, `CAUSE_TRUST`, `CAUSE_HANDSHAKE`, `CAUSE_UNTRUSTED`, `CAUSE_REQUEST`, `CAUSE_CAPACITY`)

Of these records, a program writes the fields of `Request` and reads those of `Response`. `Loop`, `Client`, `Exchange` and `Origin` are hedge's.

**`hedge.task`: background tasks** (see [Background tasks](#background-tasks))

- the facility: `Tasks`, `Options`, `default_options`, `make`, `MAX_TASKS`, `MIN_SNAPSHOT_SLOTS`, `MAX_SNAPSHOT_SLOTS`, `MAX_NAME_BYTES`, `MAX_ERROR_BYTES`, `MAX_SECRET_BYTES`, `MAX_RUN_EXCHANGES`, `STEP_INTERVAL_NS`
- secrets: `Resolver`, `ResolveFun`, `Secrets`, `no_secrets`, `register_secrets`, `unregister_secrets`, `MAX_RESOLVERS`
- registering and triggering: `Spec`, `StepFun`, `Handle`, `register`, `trigger`, `name_valid`, `spec_valid`
- a run: `Run`, `Cause` and its values (`CAUSE_PERIOD`, `CAUSE_TRIGGER`), `begin`, `borrow`, `UseFun`, `Borrow` and its values (`BORROW_OK`, `BORROW_MISSING`, `BORROW_REFUSED`, `BORROW_INVALID`), `Draft`, `draft`, `commit`, `discard`, `publish`
- reading: `Lease`, `read`, `release`, `lease_view`
- reporting: `Report`, `report`, `report_error`, `success_age_ns`, `draining`, `Outcome` and its values (`OUTCOME_NONE`, `OUTCOME_COMPLETED`, `OUTCOME_FAILED`, `OUTCOME_ABANDONED`)
- outcomes: `Status` and its values (`STATUS_OK`, `STATUS_INVALID`, `STATUS_DRAINING`, `STATUS_FULL`, `STATUS_EMPTY`, `STATUS_COALESCED`, `STATUS_BUSY`)

Of these records, a program writes the fields of `Spec`, `Options` and `Resolver`, and reads those of `Run`, `Draft`, `Lease` and `Report`. `Tasks`, `Handle` and `Secrets` are hedge's.

**`hedge.secret`: secrets for hosted code** (see [Secrets](#secrets))

- borrowing: `Source`, `source`, `borrow`, `UseFun`, `Borrow` and its values (`BORROW_OK`, `BORROW_MISSING`, `BORROW_REFUSED`, `BORROW_INVALID`), `name_valid`, `MAX_SECRET_BYTES`, `MAX_NAME_BYTES`
- providers: `Provider`, `ProvideFun`, `Providers`, `no_providers`, `register_provider`, `unregister_provider`, `MAX_PROVIDERS`

Of these records, a program writes the fields of `Provider`. `Source` and `Providers` are hedge's.

**`hedge.settings`: an application's settings** (see [Settings](#settings))

- `Source`, `source`, `View`, `current`, `key_valid`, `MAX_KEY_BYTES`
- reading: `read`, `Read`, `read_integer`, `read_float`, `read_boolean`, `Kind` and its values (`KIND_STRING`, `KIND_INTEGER`, `KIND_FLOAT`, `KIND_BOOLEAN`, `KIND_ARRAY`, `KIND_TABLE`, `KIND_SECRET`), `Status` and its values (`READ_FOUND`, `READ_MISSING`, `READ_TOO_LARGE`, `READ_INVALID`, `READ_SECRET`, `READ_MISMATCH`)

Of these records, a program reads the fields of `Read`. `Source` and `View` are hedge's.

**`hedge.observe`: logs, metrics and health checks from hosted code** (see [Telemetry](#telemetry))

- `Source`, `source`, `Status` and its values (`STATUS_OK`, `STATUS_INVALID`, `STATUS_FULL`, `STATUS_OFF`)
- logs: `log`, `MAX_LOG_FIELDS`
- metrics: `metric`, `Metric`, `Kind` and its values (`COUNTER`, `GAUGE`, `HISTOGRAM`), `Label`, `add`, `set`, `record_value`, `MAX_APPLICATION_SERIES`, `MAX_METRIC_NAME_BYTES`, `MAX_LABELS`, `MAX_BUCKETS`
- health: `check`, `Check`, `set_ready`, `MAX_APPLICATION_CHECKS`

Of these records, a program writes the fields of `Label`. `Source`, `Metric` and `Check` are hedge's. The log fields are std's `std.log.record.Field` and levels `std.log.record.Level`.

**Process assembly.** hedge has no single entry point that runs a process around a registry yet, so an embedding program assembles one from these items (see [Running a process](#running-a-process)):

- `hedge.composition`: `Options` (its `applications`, `tasks` and `providers`), `default_options`, `Runtime`, `start_process`, `close`, `StartReport`, `StartStatus`, `START_OK`, `START_CONFIG`, `START_RUNTIME`, `StopReport`, `Bound`, `bound_count`, `bound`
- `hedge.supervisor`: `Supervisor`, `Loader`, `make`, `attach_reloads`, `start`, `run`, `stop`, `request_stop`, `request_reload`
- `hedge.config.loader`: `Resolver`, `ResolveFun`, `Capabilities`, `build`
- `hedge.config.schema`: `Graph`, `Diagnostics`, `Diagnostic`, `reset_diagnostics`, `text`, `TRANSPORT_TCP`, `TRANSPORT_QUIC`, `TRANSPORT_LOCAL`, `PROTOCOL_HTTP1`, `PROTOCOL_HTTP2`, `PROTOCOL_HTTP3`
- `hedge.generation`: `Generation`, `make_candidate`, `seal`, `ConstructFun`
- `hedge.spread`: `count`
- `hedge.connection`: `config_from`, `message_limits`
- `hedge.lifecycle`: `Reason`, `DRAINED`, `DEADLINE`, `IMMEDIATE`, `FAILED`

Of the records here, a program reads `StartReport.status` and `.detail`, the `StopReport` fields, the `Bound` fields, `Generation.graph` and `.id`, and `Diagnostics.items`, `.count` and `.truncated`. The rest of each record is hedge's.

Everything else is internal, and that includes the rest of `hedge.dispatch.call` (`bind`, `enter`, `stir`, `due`, `unpark`, `allow_tunnel`, `tunnel_owner`, `release_to_tunnel`, the recorder, interceptor and observer hooks), `service.Resolver`, `service.Factory` and the `native` service factory, `service.ListenerService`, `hedge.serve`, `hedge.worker`, `hedge.telemetry`, the rest of `hedge.outbound`, the rest of `hedge.task` (`drain`, `stop`, `poll`, `next_due`, `spawn`, `close`, `thread_state` are the supervisor's), the rest of `hedge.secret` (`resolve`, `clear`, and the per-generation store composition keeps), the rest of `hedge.settings` (its store), the rest of `hedge.observe` (`open`, `close`), and every module under `hedge.acme`, `hedge.outbound`, `hedge.protocol`, `hedge.proxy` and `hedge.cache`.

## The handler contract

Every service hedge serves, its own static files and proxies included, reduces to one handler over one call:

```mach
pub def ServeFun: fun(ptr, *call.Call) exchange.ServiceStatus;

pub rec Handler {
    ctx:   ptr;
    serve: ServeFun;
}
```

hedge calls `serve(ctx, active)` for each request routed to the handler. `active` is bound to one exchange: `call.request(active)` is the parsed request, `call.response(active)` is the response the handler fills in, and `call.limits(active)` are the limits hedge commits it under. The handler answers with one of mach-http's service statuses:

- **`SERVICE_COMPLETE`**: the response is committed, and the request body's fate is resolved.
- **`SERVICE_PENDING`**: the handler is waiting. It must have said on what, by returning `call.park(active, wait, deadline_ns)` or `call.yield_turn(active)`. A handler that reports itself pending without parking is treated as failed, since nothing would ever give it another turn.
- **`SERVICE_FAILED`**: the handler could not answer. If no response was committed, hedge answers `500 Internal Server Error` itself.

**Committing.** A handler commits through the helpers in `hedge.service` (`commit`, `commit_bodyless`, `respond`, `respond_with_bytes`, `respond_with_text`), never through mach-http's `exchange.commit` directly. The helpers add the `Date` field every hedge response carries and run hedge's response interception, such as the cache's. Before it completes, a handler resolves the request body once with `call.resolve_body`: `BODY_DELIVER` to read it, `BODY_DRAIN` to have hedge discard what remains so the connection can be reused, `BODY_REJECT` or `BODY_CLOSE` to refuse it.

**Waiting.** A handler never blocks the worker it runs on. It parks instead, naming what it waits for:

- `WAIT_BODY`: the request body. hedge enters the handler again when more of the body has arrived.
- `WAIT_WAKE`: something the handler handed `call.waker(active)` to. hedge enters the handler again once that waker is woken.
- `deadline_ns`: a monotonic instant on `hedge.clock`. hedge enters the handler again once it passes, whether or not anything else moved.

A handler that is entered again resumes the request, it does not start it over. hedge gives it no memory of its own between entries, so a handler keeps its per-request state in the request arena and finds it again through the finalizer slot: it attaches a `Finalizer` on the first entry, and on each later entry `call.finalizer_state(active, finish)` returns the state it attached. The finalizer runs exactly once when the exchange settles, however it settled, and it is where the handler releases what it holds for the request.

**Concurrency.** Every worker is handed the same registry, so one handler is entered by every worker at once, with the same `ctx` on each. A request belongs to one worker, and only that worker enters, resumes or finalizes it. Anything a handler shares between requests (its `ctx` and whatever it reaches) must therefore be safe to use from several threads at once: atomic, locked, or written before the process starts and only read after.

## Upgrades

A handler can answer a request by giving up HTTP on its connection: a `101 Switching Protocols` to a request that asked to upgrade, a WebSocket's for instance, or a `2xx` to a `CONNECT`. The connection is then a byte stream the application runs, a **tunnel**. It has the shape of mach-http's `Handler.tunnel` (see mach-http's `doc/server.md`, Tunnels), so a binding whose framework already runs tunnels on mach-http's server passes them through:

```mach
pub def TunnelFun:        fun(ptr, *Tunnel, *transport.Completion) TunnelStatus;
pub def TunnelAbandonFun: fun(ptr, *Tunnel);
pub rec TunnelOwner { ctx: ptr; drive: TunnelFun; abandon: TunnelAbandonFun; }
```

**Asking for one.** Before it commits the response, the handler names who will run the tunnel with `call.tunnel(active, owner)`. It answers false where the connection cannot hand itself over, and the handler then answers without upgrading. Once the response is written and the exchange has settled, finalizer included, hedge hands the stream to `owner` as a `Tunnel`. A response that upgrades nothing, or an exchange that fails before its response is written, never enters the owner, and a `101` whose handler named no owner closes the connection after it. A `CONNECT` reaches a handler only through a route that matches its authority-form target, and a configured route path cannot match one yet, so today a hosted handler's tunnel follows an upgrade.

- `transport` is the stream, an `http.core.transport.Transport`, and `scope` the scope to submit its operations under. The owner reads and writes through it, and settles every completion it is handed with `transport.complete`. Only hedge shuts it down or closes it.
- `input` holds the bytes the client sent past the request, valid while the tunnel lives.
- `allocator` is the upgrading request's arena, which the tunnel keeps: what the handler allocated there while negotiating, the owner's `ctx` included, lives as long as the tunnel does.
- `waker` wakes the tunnel as a call's waker wakes its handler, by `wake.wake` on the worker and `wake.post` from any other thread. `wake_at` is an instant on `hedge.clock` the owner asks to be entered again at, cleared before every entry.
- `draining` says the tunnel's generation is shutting down, and `drain_at` is an instant on `hedge.clock` before which hedge does not cut it.

**Driving.** `drive` is entered at the handoff, again with each completion of an operation the owner submitted, and after each wake, `wake_at` or the start of a drain, with a nil completion. It returns `TUNNEL_PENDING` while it runs. `TUNNEL_DONE` hands the stream back with nothing of the owner's in flight, and hedge ends it gracefully. `TUNNEL_FAILED` ends it abortively. `abandon` is called exactly once for a tunnel hedge cuts while `drive` last returned `TUNNEL_PENDING`, and hedge then cancels and settles what the owner left in flight before the tunnel's memory goes. Both run on the worker that owns the connection, and never block it.

**Bounds.** A tunnel holds its connection, which counts against `max_connections` and the per-peer limit, its request arena within the request memory it was admitted with, and the connection's buffers within the worker's memory. It holds no exchange, so it gives back its route's budget when the upgrading exchange settles. `server.timeouts.tunnel_ms` cuts one whose bytes have stood still in both directions for that long.

**Drain.** When shutdown begins, or a reload supersedes the tunnel's generation, the owner is entered with `draining` set and `drain_at` the drain deadline, so it winds down on its own terms, a WebSocket with a `1001` close for instance. A shutdown that begins while a reload's drain runs brings `drain_at` forward, and the owner is entered again when it does. Where the configuration gives the drain no time, `drain_at` is the instant it began. At the deadline hedge cuts every tunnel still running, as it cuts every exchange.

**Telemetry.** The upgrading request is logged and counted as any request. hedge reports the tunnels open (`hedge_tunnels_open`), opened (`hedge_tunnels_total`) and cut while their owner ran them (`hedge_tunnels_abandoned_total`).

**Protocols.** HTTP/1.1 connections, in cleartext and over TLS, hand themselves over today. On HTTP/2 and HTTP/3 `call.tunnel` answers false. The contract is shaped for their extended `CONNECT` (RFC 8441, RFC 9220), where the tunnel is one stream of a multiplexed connection: `transport` is then that stream, `input` whatever arrived on it with the request, `TUNNEL_DONE` ends the stream and `TUNNEL_FAILED` resets it, and the connection's other streams go on. An owner that neither shuts down nor closes its transport, and settles only its own completions, runs unchanged on either.

## The lifecycle hooks

An application with state of its own to start and stop registers a lifecycle beside its handler. hedge's supervisor drives it for the whole process:

```mach
pub rec Lifecycle {
    ctx:   ptr;
    start: StepFun;   # fun(ptr) Step
    ready: StepFun;   # fun(ptr) Step
    drain: DrainFun;  # fun(ptr, time.Instant) Step
    stop:  StepFun;   # fun(ptr) Step
    reload: StepFun;  # optional: fun(ptr) Step
}
```

Each step answers a `Step`: `STEP_DONE`, `STEP_PENDING` or `STEP_FAILED`, with a `detail` naming what failed or what is still pending. A step that answers pending is called again every 10 ms until it is done or fails. A lifecycle is whole or absent: `register_hosted` refuses one with only some steps set, and `register_application` registers a handler with none.

1. **start.** Every hosted application is started before any worker binds a listener, so no request reaches an application that has not started. A start that fails, or a stop requested while a start is still pending, refuses the process's start. The application must be registered assembled and not yet started, because hedge starts it.
2. **ready.** Once started, each application gets a required readiness check named after it in the process's health, and `ready` is polled until it answers done. The process reports ready only once its workers serve and every hosted application is ready. A readiness that fails stops the process.
3. **drain(deadline).** When shutdown begins, every application that was started is asked to drain toward `deadline`, an absolute instant on `hedge.clock`. It is the same deadline the workers drain toward, `server.timeouts.drain_ms` after shutdown began. hedge does not interrupt a drain: the application enforces the deadline itself. A drain still pending once the deadline has passed is **abandoned**.
4. **stop.** Every application that was started, including one whose start, readiness or drain failed, is stopped after the last worker has stopped and the task facility has drained, so no request or task run can still be inside it. A stop still pending after `server.timeouts.stop_ms` is abandoned.

What each overrun or failure costs:

| event | reported as | process outcome |
|---|---|---|
| start fails | `telemetry.error`, operation `start` | the process refuses to start |
| ready fails | operation `ready` | the process stops, reason `FAILED` |
| drain fails | operation `drain` | reason `FAILED` |
| drain overruns its deadline | operation `drain`, code `deadline` | counted in `StopReport.applications_abandoned`, reason `DEADLINE` (exit 75) |
| stop fails | operation `stop` | counted as a cleanup failure |
| stop overruns `stop_ms` | operation `stop`, code `deadline` | counted as abandoned and as a cleanup failure |
| a task run overruns the drain deadline | component `tasks`, operation `drain`, code `deadline` | counted in `StopReport.tasks_abandoned`, reason `DEADLINE` (exit 75) |

Every failure is also printed to stderr with the application's name and the step's `detail`.

**Steps run on the supervisor's thread.** That thread also takes signals, reloads the configuration and drives ACME, and the steps are polled in its loop. A step that blocks stalls all of that, and a blocked drain or stop cannot be abandoned, since abandoning it needs the step to return. A step therefore does its work elsewhere and answers pending until that work is done.

**Reloads.** The registry lives for the whole process. A reload rebuilds the services that reach an application, and resolves each against the same registry again, but never restarts, drains or stops the application. It hands the application the new generation instead: once a reload has published, the optional `reload` step of every started application that has one is called, and called again every 10 ms while it answers pending. From then on `settings.current` names the new generation and a secret borrow reads its secrets. A reload step that fails is reported with operation `reload` and leaves the application running on what it had. A lifecycle that sets `reload` must set the other four steps too.

## Registering and running

### Registering

The embedding program owns the registry and its storage:

```mach
var slots:    [1]service.Application;
var registry: service.Applications;
service.make_applications(?registry, ?slots[0], 1);
service.register_hosted(?registry, "site", handler, hosted, memory_bytes);
```

A registry holds at most `service.MAX_APPLICATIONS` (32), and each name at most once. A configuration routes to an application by naming it as the `application` of a service whose `kind` is `application`, whatever the framework (see [CONFIGURATION.md](CONFIGURATION.md)). A configuration that names an unregistered application fails with `no application is registered under this name`, at startup or at a reload.

`memory_bytes` is the request memory each request to the application may hold, or zero for the server's `call_memory_bytes`. A service's own `memory_bytes` overrides it. See [Request memory](CONFIGURATION.md#request-memory).

### Running a process

The program then assembles the process around the registry. This is the sequence hedge's own `src/bin/main.mach` runs, with the registry added:

1. Load and seal the first configuration generation: `generation.make_candidate`, `loader.build` into its `graph`, then `generation.seal`.
2. Set `Options.applications` on `composition.default_options()` and call `composition.start_process` with `spread.count(graph)` workers.
3. `supervisor.make`, then `supervisor.attach_reloads` with a `Loader` that seals each reload's candidate into the generation slot the active one is not using.
4. `supervisor.start`, which starts the hosted applications and then the workers. On `START_OK`, `supervisor.run`, which returns once the process has been asked to stop and every worker and every hosted drain has settled.
5. `supervisor.stop`, which joins the workers, stops the hosted applications and returns the `StopReport` the exit status is chosen from.

### Where the listeners bound

Once `supervisor.start` answers `START_OK`, the program can read every listener the configuration declares, in the order it declares them, as the process bound it. `composition.bound_count(runtime)` is how many there are, and none before the first worker serves. `composition.bound(runtime, i)` is the `i`th, or nil past the last:

- `name`: the listener's configured name, read with `schema.text(?bound.name)`.
- `transport`: `schema.TRANSPORT_TCP`, `TRANSPORT_QUIC` or `TRANSPORT_LOCAL`.
- `protocols`: the protocols it serves, as `schema.PROTOCOL_HTTP1`, `PROTOCOL_HTTP2` and `PROTOCOL_HTTP3` bits, and `secure`, whether it serves them over TLS.
- `address`: for a TCP or QUIC listener, the address its socket is bound to. A configured port of 0 reads as the port the system chose, which every worker shares.
- `local`: for a local listener, its configured endpoint, a filesystem path or an abstract name.

This is how a binding's `run` announces where it serves, and how a test binds `127.0.0.1:0` and connects to the port it got. hedge's own `main` prints its `hedge: listening` lines from it. A listener that bound but cannot say where fails the start with `START_RUNTIME`. Listeners change only with a restart, since a reload that changes one is refused, so what `bound` reports holds until `supervisor.stop` returns. It is written before `supervisor.start` returns and read-only after, so any thread may read it.

`connection.message_limits(graph, connection.config_from(graph))` gives the limits hedge commits every response under, for a framework that assembles its application against them before registering it.

## Facilities for hosted code

What hosted code receives from hedge today:

- **Per request, through the call**: the request arena (`call.allocator_of`), the exchange's cancellation scope and deadline (`call.scope`, `call.deadline`, `call.cancelled`), the request's trace context (`active.telemetry`, a W3C trace context hedge parsed or started), and a waker (`call.waker`). hedge logs every request it serves, including the ones a hosted handler answers.
- **Through the lifecycle**: when to start, a readiness check in the process's health, and a drain deadline.
- **Outbound HTTPS**: a client for requests to other services, verified against anchors the application chooses. See [Outbound HTTPS](#outbound-https).
- **Background tasks**: work on its own schedule on a thread hedge owns, with snapshots handlers read without waiting. See [Background tasks](#background-tasks).
- **Secrets**: the secrets the configuration grants the application, borrowed by name from any thread. See [Secrets](#secrets).
- **Settings**: the application's own section of the configuration, read by key per generation. See [Settings](#settings).
- **Telemetry**: structured log records, metric series and health checks in hedge's own sinks, attributed to the application. See [Telemetry](#telemetry).
- **Through the embedding program**: the program supplies hedge with things, rather than receiving them. It can hand a `loader.Resolver` that answers the configuration's environment references, a `secret.Resolver` in `composition.Options.telemetry.secrets` for the administration credential's `os` and `application` secret providers, a `secret.Providers` in `.providers` for the secrets hosted code borrows, and a log sink in `.telemetry.downstream` that receives hedge's own records and those hosted code writes.

## Outbound HTTPS

`hedge.outbound` sends HTTP/1.1 requests, over TLS for an `https` URL, and reads their responses. It is the client hedge's own certificate manager uses to reach its authority.

A **loop** (`outbound.Loop`) is a runtime, name resolution and one client, opened on the thread that drives it. An **exchange** (`outbound.Exchange`) carries one request at a time, in buffers the caller owns. `begin` starts a request, `turn` waits on the loop's runtime and delivers what completed, `poll` advances the exchange, and `finish` ends it. `fetch` does all of that for one request and returns when it has completed or failed.

```mach
var anchors: bundle.Loaded;
if (bundle.load(?heap, "/etc/ssl/certs/ca-certificates.crt", ?anchors) != bundle.OK) { ret 1; }
var loop: outbound.Loop;
if (!outbound.open_loop(?loop, ?anchors.bundle.store)) { ret 2; }

var request:  [4096]u8;
var response: [16384]u8;
var items:    [64]field.Field;
var exchange: outbound.Exchange;
outbound.make_exchange(?exchange, ?request[0], 4096, ?response[0], 16384,
    ?items[0], 64, field.limits(64, 16384, 128, 4096));

var headers: [1]field.Field;
headers[0] = field.Field{name: view.view("accept", 6),
    value: view.view("application/vnd.github+json", 27), sensitive: false};
var zen: outbound.Request = outbound.request(method.GET,
    view.view("https://api.github.com/zen", 26));
zen.headers      = ?headers[0];
zen.header_count = 1;
zen.timeout_ns   = 10000000000;

if (outbound.fetch(?loop, ?exchange, zen) == outbound.OK) {
    val answer: outbound.Response = outbound.response(?exchange);
    # answer.status is 200 and answer.body is one line of zen
}
outbound.finish(?exchange);
for (!outbound.idle(?exchange)) { outbound.turn(?loop, 10); }
outbound.destroy_exchange(?exchange);
for (outbound.close_loop(?loop) == outbound.PENDING) {}
bundle.release(?heap, ?anchors);
```

**Threads.** A loop, its client and the exchanges begun on it belong to the thread that opened the loop, and only that thread turns it or touches them. `turn` with a wait and `fetch` block that thread on the loop's own runtime, so a loop runs on a thread the application owns, started from its lifecycle's `start` and joined from its `stop`. It never runs in a handler, which must not block its worker, or in a lifecycle step, which must not block the supervisor. What the thread fetches reaches handlers as the concurrency rule above requires. The steps themselves never wait: `begin`, `poll` and `turn(loop, 0)` return at once, which is what lets a loop share a thread with other work. The background task thread is such a thread, with a loop of its own that every task reaches (see [Background tasks](#background-tasks)).

**Trust.** An `https` request is verified against the anchors `open_loop` was given, for the host the URL names, typically a system bundle loaded with mach-tls's `tls.cert.bundle`. Without anchors it fails with `CAUSE_TRUST` and never leaves the process. A chain that does not verify, or a certificate that does not name the host, fails with `CAUSE_UNTRUSTED`, and the request is never sent. `route` sends one host's requests to a fixed endpoint, still verified for the URL's host, or in cleartext to a front end that terminates TLS for it, which is only ever a decision the application makes.

**Requests.** A credential goes into a header with `secret_header(field, name, prefix, secret, storage, capacity)`, which writes `prefix` and then the secret-typed `secret` into `storage`, the one place the client declassifies a secret. The client writes `host`, `content-length` and, unless the request carries one, `user-agent` (`hedge` by default, or `set_user_agent`). A request that supplies `host`, `content-length`, `transfer-encoding`, `connection`, `te`, `upgrade`, `trailer`, `keep-alive` or `proxy-connection`, an invalid field, a body on a `GET` or `HEAD`, or more than the exchange's request buffer holds fails with `CAUSE_REQUEST`. Methods are `GET`, `HEAD`, `POST`, `PUT`, `PATCH`, `DELETE` and `OPTIONS`.

**Responses.** A response is framed by `content-length`, by chunked transfer coding, which is decoded in place, or by the peer closing. Interim `1xx` responses are passed over. A response larger than the request's `max_response_bytes`, or the exchange's response buffer when that is zero, fails with `CAUSE_TOO_LARGE`, and one whose head exceeds 16 KiB or the exchange's field limits does too. An exchange that has not completed by its deadline, `timeout_ns` after `begin` and never less than `MIN_TIMEOUT_NS`, fails with `CAUSE_TIMEOUT`. The two limits are separate causes, as are resolution (`CAUSE_ADDRESS`), connection (`CAUSE_CONNECT`), a malformed response (`CAUSE_PROTOCOL`) and a handshake that failed for a reason other than trust (`CAUSE_HANDSHAKE`).

**Connections.** After a response that delimits itself, from a peer that speaks HTTP/1.1 and did not ask to close, the connection is kept for the next exchange to the same host, port and scheme, for up to `IDLE_NS`. A client keeps at most `MAX_CONNECTIONS`, and gives up the one unused longest to reach another host. A kept connection the peer has closed meanwhile is found out by the exchange that reuses it, which reconnects once when its request is `replay_safe` (by default, when its method is idempotent). TLS sessions are drawn from one bounded table for the whole process, hedge's own certificate manager included, and an exchange that finds it full fails with `CAUSE_CAPACITY`.

**Memory.** The loop and every exchange stay where they were made while in use. The anchors stay alive and unchanged while the loop is open. Every byte a `Request` points at, its headers included, stays alive until the exchange completes. A `Response` points into the exchange's buffers and is valid until `finish`. After `finish` a connection that was cancelled may still write into those buffers until its operations land, which `releasing` reports: a `begin` in the meantime is held until they have, and `destroy_exchange` refuses until then. Every exchange is finished before `close_loop`, which answers `PENDING` until the loop's connections and lookups have settled.

## Background tasks

`hedge.task` runs work on its own schedule next to request handling: a periodic refresh, an on-demand rebuild a handler can fire, and a snapshot every handler reads without waiting. It is one facility for the whole process. The embedding program makes it and hands it to hedge, and hands it to its hosted code as well, typically through a handler's or lifecycle's `ctx`, and hosted code registers its tasks in it:

```mach
# a module-level record: a resolver is secret welded, so it never erases to ptr
var vault_resolver: task.Resolver = task.Resolver{ctx: nil, resolve: resolve_from_vault};

var secrets: task.Secrets;
task.register_secrets(?vault_resolver, ?secrets);
var tasks: task.Tasks;
var options: task.Options = task.default_options();
options.trust   = ?anchors.bundle.store;
options.secrets = secrets;
task.make(?tasks, options);

var process: composition.Options = composition.default_options();
process.tasks = ?tasks;
```

**Where tasks run.** The supervisor starts one task thread before any hosted application starts, and joins it after the last one has stopped. The thread has an io runtime of its own, which an outbound loop waits on, so a task never runs on a worker or on the supervisor's thread, and a task that misbehaves cannot stall signals, reloads or ACME. Tasks are process-scoped: they are registered once, and a configuration reload never touches them. A process run with `supervisor.start`, `run` and `stop` runs its tasks. The facility is given only through `composition.Options.tasks`, and a process without one has no task thread.

**Registering.** `task.register(tasks, spec, handle)` takes a `Spec` and returns an opaque `Handle`:

- `name` is a printable identifier of at most `MAX_NAME_BYTES`, for reports.
- `state` is the task's own state, and `step` its function. `state` is erased to `ptr`, so it holds public data only (see Secrets below).
- `period_ns`, when not zero, runs the task that long after the facility first sees it, then that long after each run ends. A task without a period runs only when triggered, and one that wants an immediate first run triggers it.
- `timeout_ns`, when not zero, bounds each run.
- `slots`, `slot_bytes` and `slot_count` are the task's snapshot storage: `slot_count` slots of `slot_bytes` each, from `MIN_SNAPSHOT_SLOTS` to `MAX_SNAPSHOT_SLOTS`. A task with `slot_count` 0 publishes nothing.

A facility holds at most `MAX_TASKS` tasks, and registration is refused with `STATUS_DRAINING` once drain has begun. Every bound is a compile-time constant. A task may be registered before the process starts, from a lifecycle's `start`, or later.

**Steps.** A run is a sequence of non-blocking steps. `step(state, run)` answers a `service.Step`: `STEP_DONE` when the run is complete, `STEP_PENDING` to be stepped again, or `STEP_FAILED` with a `detail` that fails the run. A step that is pending is stepped again when the task thread's loop delivers something, and at least every `STEP_INTERVAL_NS`. A step never blocks, so one task cannot hold up another. `Run` is valid only during the step. It carries the run's cancellation scope, its deadline, its cause (`CAUSE_PERIOD` or `CAUSE_TRIGGER`), a sequence number, and the task thread's outbound loop. The scope is cancelled when drain begins and times out at the run's deadline, and a run still pending once its deadline has passed fails.

**Triggering.** `task.trigger` may be called from any thread, a handler's included, and it never waits on a run. It is single-flight: it returns `STATUS_OK` when it queues a run, and `STATUS_COALESCED` when a run is already queued, in which case that run serves both callers. A trigger while a run is in flight queues one follow-up, so a change that arrives mid-run is never missed and at most one run is ever in flight. Once drain begins, every trigger is refused with `STATUS_DRAINING`.

**Snapshots.** A run publishes with `task.draft`, writing into the slot it returns, and `task.commit`, or with `task.publish` for bytes it already has. The committed slot becomes the task's current snapshot. `task.discard` gives an uncommitted draft back, and a run that ends with one open has it discarded. `task.read` never waits on a run: it returns a `Lease` on the current snapshot, or `STATUS_EMPTY` before the first publish. A lease is a reference on its slot until `task.release`, and a leased slot is never reused, so a handler reads a stable snapshot for as long as it holds the lease. A publish needs a slot that is neither current, leased nor drafting. When every slot is held, `draft` and `publish` return `STATUS_FULL` and the current snapshot stays in place, so a task whose refresh fails keeps serving its last good snapshot.

**Secrets.** mach refuses to erase anything that reaches secret-typed data to `ptr`, so task state, which is erased, holds no secret. A `Resolver` writes the named secret into secret-typed (`^u8`) storage, and since its callback type mentions a secret it cannot be erased either. So the embedding program registers it with `task.register_secrets` into a bounded table (`MAX_RESOLVERS`), and the facility holds only the public `Secrets` handle that call returns, in `Options.secrets`. `task.borrow(run, name, use, use_ctx)` has the resolver fill secret scratch storage of at most `MAX_SECRET_BYTES`, hands it to `use` as `contracts.SecretBytes` for that call only, and clears it once `use` returns. Only a run in flight borrows. `task.unregister_secrets` is refused while a borrow is in flight. A secret an outbound request must carry, such as a bearer token, reaches public memory at exactly one place: `outbound.secret_header` declassifies it (`:>u8`) into header storage the task owns, marks the field sensitive, and the task clears that storage once the exchange is finished.

**Outbound HTTPS.** `task.begin(run, exchange, request)` begins a request on the task thread's loop, verified against `Options.trust` (see [Outbound HTTPS](#outbound-https)). Its timeout is cut to the run's deadline, and the facility finishes the exchange when the run ends, however it ended, so a run that fails or is abandoned never holds a connection open. The step advances the exchange with `outbound.poll` and reads it with `outbound.response` as usual, and routes a host with `outbound.route(outbound.client(run.loop), ...)`. A run begins at most `MAX_RUN_EXCHANGES` at once. The exchange and its buffers are the task's.

**Drain and stop.** When shutdown begins, the supervisor drains the facility toward the same deadline as the workers and the hosted applications. Drain cancels every running task's scope, refuses further triggers and registrations, and drops queued runs. Running tasks keep being stepped until they end or the deadline passes, and a run still in flight at the deadline is **abandoned**: it is never stepped again, its exchanges are finished, its report says `OUTCOME_ABANDONED`, and it is counted in `StopReport.tasks_abandoned`. On every path to `supervisor.stop`, a normal shutdown or not, the drain settles before any hosted application stops, so no task run is in flight or begins once an application's `stop` has been called. A stop with no drain window, such as one after a start that failed because a worker, a hosted application or the task thread could not start, drains toward a deadline already passed, so a run still in flight is abandoned at once. The supervisor waits for the drain to settle for at most `server.timeouts.stop_ms`. Only a step that blocks the task thread can keep it from settling, and the facility then fails to stop, which counts as a cleanup failure. After the hosted applications have stopped, the facility is stopped, which needs every lease released, and the thread closes its loop within `server.timeouts.stop_ms`. A lease still held, or a loop that did not close in time, counts as a cleanup failure. `task.draining` says whether drain has begun.

**Telemetry.** `task.report` returns a task's runs by outcome (`completed`, `failed`, `abandoned`), the triggers that coalesced, the last and the longest run's duration, when the last completed run ended (`success_age_ns` gives its age), whether a run is running or queued, the sequence of the current snapshot, and the last failure's detail (`report_error`). Runs abandoned at drain are reported to the operator and to telemetry with component `tasks`.

## Secrets

`hedge.secret` lends hosted code the secrets its configuration grants it. The configuration declares each secret once, in a `[secret]` table, and gives each application the ones it may borrow, under names of its own, in its section (see [Secrets for hosted applications](CONFIGURATION.md#secrets-for-hosted-applications)):

```toml
[secret.db-password]
provider = "file"
key = "/run/secrets/db"

[application.site.secrets]
database = "db-password"
```

The embedding program names each application for borrowing once it has registered it, and hands the `Source` to the application's code the way it hands it anything else, typically through the handler's or the lifecycle's `ctx`:

```mach
var site: secret.Source;
secret.source(?registry, "site", ?site);

fun connect(context: ptr, password: contracts.SecretBytes) bool {
    # password.data and password.len are valid for this call only
    ret open_database(context::*Database, password);
}

if (secret.borrow(site, view.view("database", 8), connect, (?db)::ptr) != secret.BORROW_OK) {
    # BORROW_MISSING: nothing is granted under that name
}
```

**Scope.** A `Source` names one registered application, and a borrow through it reaches that application's grants and no other's. A name that is not granted to it is `BORROW_MISSING`, whether or not another application holds one by that name, so two applications may use the same name for different secrets. `source` refuses a name the registry does not hold.

**Borrowing.** `borrow(source, name, use, use_ctx)` copies the secret into secret-typed scratch storage, hands it to `use` as `contracts.SecretBytes` for that call only, and clears the storage once `use` returns. `use` answers whether it could use the secret, and a `false` is `BORROW_REFUSED`. A name that is not 1 to `MAX_NAME_BYTES` printable characters without spaces is `BORROW_INVALID`, and so is every borrow before the process has started or after it has stopped. Any thread may borrow, a handler, a lifecycle step or a task, and a borrow never waits on anything but a short lock, since the secret was resolved before its generation was published.

**Secret-typed end to end.** A secret lives in secret-welded memory from the time it is resolved to the time it is cleared, and hosted code sees it only as `^u8`. A `file` secret is read straight into that memory. `os` and `application` secrets come from a `Provider`, whose `provide(ctx, provider, key, output, capacity)` writes the secret the configuration names by `provider` and `key` into secret `output` and returns its length, or -1 for none. A provider mentions a secret in its callback type, so it cannot be erased to `ptr`: the embedding program registers it with `register_provider` into a bounded table (`MAX_PROVIDERS`), and hands hedge the public `Providers` handle in `composition.Options.providers`. `unregister_provider` is refused while hedge is resolving through it. A secret leaves secret-typed memory only where its consumer declassifies it (`:>`) into its own sink, as `outbound.secret_header` does for a request header, and the consumer clears that sink.

**Generations.** Every configuration generation resolves the secrets it grants before it is published, and a secret that cannot be resolved refuses the generation, at startup or at a reload. A borrow reads the generation the process has published. A reload resolves every grant again, beside the ones borrows read now, and the process switches to them when the reload is published, clearing the ones they replace. A secret rotated at its source therefore reaches hosted code with the next reload, and an application that keeps a copy of one, in a connection it opened with it for instance, renews it when its lifecycle or its own schedule says so.

## Settings

`hedge.settings` hands hosted code its own section of the configuration. hedge carries the section's `settings` table without interpreting it, checks it only for its shape, and flattens it under dotted keys (see [Application settings](CONFIGURATION.md#application-settings)):

```toml
[application.site.settings]
greeting = "hello"
peers = ["a", "b"]

[application.site.settings.database]
pool = 8
password = "${SECRET:database}"
```

reads as `greeting`, `peers` (an array of 2), `peers.0`, `peers.1`, `database` (a table of 2), `database.pool` and `database.password`. The embedding program names an application with `settings.source(registry, name, source)`, as it does for secrets, and hands the `Source` to the application's code.

**Generations.** `settings.current(source)` is a `View` of the application's settings in the generation the process has published. A view keeps reading that generation, whole, through the next reload, and once a second reload has published every read through it answers `READ_INVALID`. An application that reads settings outside a request takes `current` again in its lifecycle's `reload` step, which a published reload calls (see [The lifecycle hooks](#the-lifecycle-hooks)). A handler takes `current` per request, so a request reads one generation from start to finish.

**Reading.** `read(view, key, output, capacity)` copies the value's text and answers a `Read` with its `status`, its `kind` and its length: a string as written, an integer in decimal, a float in its shortest round-trip decimal, a boolean as `true` or `false`, and an array's or a table's member count. A value longer than `capacity` answers `READ_TOO_LARGE` with the length it needs, and a key the section does not hold answers `READ_MISSING`, whether or not another application's section holds it. `read_integer`, `read_float` and `read_boolean` answer the typed value, or `READ_MISMATCH` for a value of another kind. A key that is not 1 to `MAX_KEY_BYTES` printable characters without spaces, dotted without an empty segment, answers `READ_INVALID`.

**Secret references.** A string value `${SECRET:name}` names one of the application's own grants, and a configuration whose reference names anything else is refused. It is never read as the secret: `read` answers `READ_SECRET`, `kind` `KIND_SECRET`, and the grant's name, which the application then borrows through `hedge.secret` (see [Secrets](#secrets)).

Any thread may read. A read never waits on anything but a short lock, since a generation's settings were copied before it was published.

## Telemetry

`hedge.observe` lets hosted code write to the log, the metrics and the health hedge writes its own to, so what it reports reaches the operator's pipeline alongside hedge's. The embedding program names an application with `observe.source(registry, name, source)`, as it does for secrets and settings. Everything here may be called from any thread, and everything is attributed to the application the `Source` names.

**Logs.** `log(source, level, message, fields, count, trace)` writes one record to hedge's log sink, under the same bounds, queue and overload policy as hedge's own records. hedge adds `kind="application"`, `application` with the application's name, and, when `trace` is a request's trace context (`active.telemetry`), its `trace_id`, which is the one hedge's access record for that request carries. Those three keys are hedge's: a record that sets one, or that carries more than `MAX_LOG_FIELDS` fields, is `STATUS_INVALID`. A record below the configured level, one the sink drops under overload, and any record when the operator turned logs off answer `STATUS_OFF`. hedge redacts nothing inside a record, and a secret never reaches one unless the code declassifies it (`:>`) into a field itself.

**Metrics.** `metric(source, kind, name, labels, label_count, bounds, bucket_count, metric)` registers a series and returns its `Metric`, or finds the one registered already with the same kind, name and labels. The series is named `app_<name>`, where `name` is up to `MAX_METRIC_NAME_BYTES` of `[a-zA-Z_][a-zA-Z0-9_]*`. It is labelled `application` with the application's name beside at most `MAX_LABELS` labels of its own, whose keys are sorted and never `application`. So one application's series can never be taken for another's or for hedge's. A histogram takes up to `MAX_BUCKETS` ascending `bounds`. `add`, `set` and `record_value` update a counter, a gauge and a histogram. Every distinct set of label values is a series of its own, and an application registers at most `MAX_APPLICATION_SERIES` (64), which bounds its cardinality. Past that, a new series is `STATUS_FULL` while the ones it has keep working. Hosted series share the process's `telemetry.metric_series` with hedge's built-in series, and a registration that finds it spent is `STATUS_FULL` too. With metrics off, `metric` is `STATUS_OFF`. Series are process-scoped: a reload keeps them.

**Health checks.** `check(source, name, required, ready, check)` adds a check named `<application>.<name>` beside the readiness check hedge registers under the application's name, and `set_ready(check, ready)` moves it. A required check that is not ready holds the process's readiness, exactly as a hosted readiness does. An application adds at most `MAX_APPLICATION_CHECKS` (4) checks, and a check lives for the process.

**Traces.** hedge starts a trace for every request and hands it to the handler as `active.telemetry`. A framework's request span joins it by taking its `trace_id` and parenting on its `parent_id`, which is hedge's span for the request, and a record logged with that context carries the same `trace_id`. hedge exports no spans itself (see [CONFIGURATION.md](CONFIGURATION.md#telemetry-and-administration)).

## Memory rules

- **The registry** and its slot storage, every registered `name`, and every `ctx` of a handler or lifecycle stay live and unchanged from registration until `supervisor.stop` returns. hedge only reads them after startup.
- **The request arena** (`call.allocator_of`) lives until the exchange settles, and hedge reclaims it then in one step, or, for an exchange that upgraded into a tunnel, once the tunnel has ended. A handler allocates its per-request state and response bytes there and frees nothing. Bytes a handler hands to `respond_with_bytes` must live until the exchange settles, which arena bytes do. An allocation the arena refuses is the request's bound running out: `call.memory_refused` says so, and the handler fails or answers without it.
- **Nothing per request outlives the exchange.** A handler that keeps anything past its request copies it into memory it owns, and synchronizes it as the concurrency rule above requires.
- **A step's `detail`** is read before the step returns and never kept, so it may point at the application's own storage.
- **The trace context and the waker** are valid for the exchange and no longer.
- **A `Source`**, a secret's or a setting's, is valid while the registry it came from is, and holds no secret. A settings `View` is a value, valid to read as long as its generation is kept. A `Metric` and a `Check` are values, valid until `supervisor.stop` returns, after which nothing here may be called. The fields handed to `log` are read before it returns. A secret handed to `use` is valid for that call and no longer, and a program that keeps one copies it into secret-typed memory it owns and clears. A registered `Provider` and its `ctx` stay live and unchanged until it is unregistered, which is after `supervisor.stop` returns.
- **The task facility** and its `Options` stay where they were made, and every registered task's `name`, `state` and snapshot `slots` stay live, until `supervisor.stop` returns. A `Lease`'s bytes are valid until it is released, and a `Draft`'s until it is committed or discarded.

## Cancellation rules

- **One authority.** The exchange's `cancel.Scope` (`call.scope`) is the single authority on whether a request is still wanted and by when. A client that goes away, a request timeout, a drain past its deadline: each cancels the scope. A handler with a shorter deadline of its own parks with it, and when it passes times the scope out (`cancel.timeout`), so hedge and the handler agree on the request's fate.
- **Cancellation reaches a parked handler.** hedge enters a parked handler again when its exchange is cancelled, and `call.cancelled(active)` is then true. The handler gives the request up and returns `SERVICE_FAILED`. Its finalizer still runs.
- **Deadlines are monotonic.** Every deadline hedge hands out or accepts, a scope's, a park's or a drain's, is an instant on `hedge.clock`'s monotonic clock. Wall time is for dates only.
- **Waking from another thread.** `wake.wake` touches the worker's queue without a lock, so it is called only on the worker that owns the call. Work finishing on any other thread hands the worker a `wake.Posted` with `wake.post`. Its `settle` runs on the worker's thread before the handler is entered again, which is where a result is handed over. A wake is a hint: waking a request that has since gone costs one wasted entry and nothing else.
- **Drain is cooperative.** hedge stops accepting and waits, it never interrupts a handler or a lifecycle step. An application that must not overrun the drain deadline checks it.

## Stability

- **What is promised.** Within one version of this contract, every item listed in [The contract items](#the-contract-items) keeps its name, signature and documented behaviour, and every rule in this document holds.
- **Versioning.** A change that breaks a contract item or rule is a new major version of the contract. A new item, or a new facility, is a minor version of it. The contract's version is stated at the top of this document.
- **How a change is marked.** A pull request that changes the host contract updates this document in the same change. Its issue carries the SemVer label for the hedge release the change requires (`major` for a break from hedge 1.0, and until then `minor`, as hedge's 0.x releases take breaking changes), and the release's CHANGELOG entry names the host contract, as a **Breaking** entry when the contract's major version moves.
- **What is not promised.** Every `pub` item this document does not list may change or disappear in any release. A binding that reaches one is on its own. If a binding needs something the contract lacks, the contract grows to include it, and the binding waits.

## Writing a hedge binding

A binding adapts one framework to this contract, so that the framework's applications run in hedge without the framework knowing hedge exists. [briar-systems/graft](https://github.com/briar-systems/graft) binds laurel and is the worked example. It is the template for a third-party framework's binding, which lives in that framework's own repository. A binding:

- **bridges requests.** It turns a `call.Call` into the framework's request and back: the exchange, deadline and cancellation, the trace id for the framework's request identifier, and the framework's suspension points onto `call.park`, with its per-request state found again through the finalizer slot.
- **bridges the lifecycle.** It maps the framework's start, readiness, drain and stop onto a `service.Lifecycle`, whose steps never block.
- **bridges facilities.** It feeds the framework's own provider interfaces from what hedge supplies to hosted code, and grows with the facilities above as they land.
- **registers and runs.** It offers a way to mount an application into a registry a program already has, and a way to run a whole process around one application.

A binding imports only the items this document lists. It pins a hedge version, and it moves to a new major version of the contract deliberately.
