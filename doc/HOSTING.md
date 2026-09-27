# Hosting applications

hedge hosts applications in-process. A hosted application is Mach code linked into the same binary as hedge: hedge accepts the connections, speaks HTTP, routes each request, and calls the application's handler for the requests routed to it. The application never sees a socket, a TLS session or a protocol engine.

This document is the **host contract**: the part of hedge's public surface a hosted application, or a binding that adapts a framework to hedge, may depend on. It says which items the contract is made of, what hedge promises about each, and what it asks of the code it hosts. Anything it does not name is internal to hedge, even when it is declared `pub`.

This is **host contract version 1**.

## Roles

- **hedge** is the host. It owns the process: the listeners, the workers, the configuration and its reloads, the signals, ACME, TLS and telemetry.
- **A hosted application** is a handler, and optionally a lifecycle, registered under a name. The configuration routes requests to it by that name.
- **A binding** adapts one framework's application model to this contract. [briar-systems/graft](https://github.com/briar-systems/graft) binds laurel, and it is the worked example (see [Writing a hedge binding](#writing-a-hedge-binding)). A framework needs no hedge symbol of its own. Only its binding imports hedge.
- **The embedding program** is the `main` that assembles the process: it builds the registry, hands it to hedge, and runs hedge until it stops. A binding usually supplies it.

## The contract items

These are the items of the host contract, by module. Types and constants from mach-http (`http.core.*`) and std that these items take or return are those projects' own contracts and follow their versions.

**`hedge.service`: handlers, lifecycles and the registry**

- `Handler`, `ServeFun`, `no_handler`, `has_handler`
- `Lifecycle`, `StepFun`, `DrainFun`, `Step`, `StepStatus`, `STEP_DONE`, `STEP_PENDING`, `STEP_FAILED`, `no_lifecycle`, `has_lifecycle`
- `Application`, `Applications`, `MAX_APPLICATIONS`, `make_applications`, `register_hosted`, `register_application`, `find_application`
- the response helpers: `commit`, `commit_bodyless`, `respond`, `respond_with_bytes`, `respond_with_text`, `add_field`, `arena_bytes`, `arena_number`, `text_view`

**`hedge.dispatch.call`: one request, as a handler sees it**

- `Call`, of which a handler reads exactly two fields, `exchange` and `telemetry`, and writes none
- the request and response: `request`, `response`, `limits`, `allocator_of`, `memory_refused`
- body ownership: `Disposition`, `BODY_DELIVER`, `BODY_DRAIN`, `BODY_REJECT`, `BODY_CLOSE`, `resolve_body`, `disposition`
- waiting: `Wait`, `WAIT_BODY`, `WAIT_WAKE`, `park`, `yield_turn`, `waker`
- cancellation: `scope`, `deadline`, `cancelled`, `entered`
- per-request state: `Finalizer`, `FinalizeFun`, `attach_finalizer`, `finalizer_state`, `detach_finalizer`

**`hedge.telemetry.trace`**: `Context`, read-only, of which a handler reads `trace_id`, `parent_id` and `flags`.

**`hedge.wake`**: `Waker`, `wake`, `Posted`, `post`.

**`hedge.clock`**: `instant`, `monotonic_ns`, `to_ns`, `from_ns`, `after`, `after_ns`, `between_ns`.

**Process assembly.** hedge has no single entry point that runs a process around a registry yet, so an embedding program assembles one from these items (see [Running a process](#running-a-process)):

- `hedge.composition`: `Options`, `default_options`, `Runtime`, `start_process`, `close`, `StartReport`, `StartStatus`, `START_OK`, `START_CONFIG`, `START_RUNTIME`, `StopReport`
- `hedge.supervisor`: `Supervisor`, `Loader`, `make`, `attach_reloads`, `start`, `run`, `stop`, `request_stop`, `request_reload`
- `hedge.config.loader`: `Resolver`, `ResolveFun`, `Capabilities`, `build`
- `hedge.config.schema`: `Graph`, `Diagnostics`, `Diagnostic`, `reset_diagnostics`, `text`
- `hedge.generation`: `Generation`, `make_candidate`, `seal`, `ConstructFun`
- `hedge.spread`: `count`
- `hedge.connection`: `config_from`, `message_limits`
- `hedge.lifecycle`: `Reason`, `DRAINED`, `DEADLINE`, `IMMEDIATE`, `FAILED`

Of the records here, a program reads `StartReport.status` and `.detail`, the `StopReport` fields, `Generation.graph` and `.id`, and `Diagnostics.items`, `.count` and `.truncated`. The rest of each record is hedge's.

Everything else is internal, and that includes the rest of `hedge.dispatch.call` (`bind`, `enter`, `stir`, `due`, `unpark`, the recorder, interceptor and observer hooks), `service.Resolver`, `service.Factory` and the `native` service factory, `service.ListenerService`, `hedge.serve`, `hedge.worker`, `hedge.telemetry` and every module under `hedge.acme`, `hedge.protocol`, `hedge.proxy` and `hedge.cache`.

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

## The lifecycle hooks

An application with state of its own to start and stop registers a lifecycle beside its handler. hedge's supervisor drives it for the whole process:

```mach
pub rec Lifecycle {
    ctx:   ptr;
    start: StepFun;   # fun(ptr) Step
    ready: StepFun;   # fun(ptr) Step
    drain: DrainFun;  # fun(ptr, time.Instant) Step
    stop:  StepFun;   # fun(ptr) Step
}
```

Each step answers a `Step`: `STEP_DONE`, `STEP_PENDING` or `STEP_FAILED`, with a `detail` naming what failed or what is still pending. A step that answers pending is called again every 10 ms until it is done or fails. A lifecycle is whole or absent: `register_hosted` refuses one with only some steps set, and `register_application` registers a handler with none.

1. **start.** Every hosted application is started before any worker binds a listener, so no request reaches an application that has not started. A start that fails, or a stop requested while a start is still pending, refuses the process's start. The application must be registered assembled and not yet started, because hedge starts it.
2. **ready.** Once started, each application gets a required readiness check named after it in the process's health, and `ready` is polled until it answers done. The process reports ready only once its workers serve and every hosted application is ready. A readiness that fails stops the process.
3. **drain(deadline).** When shutdown begins, every application that was started is asked to drain toward `deadline`, an absolute instant on `hedge.clock`. It is the same deadline the workers drain toward, `server.timeouts.drain_ms` after shutdown began. hedge does not interrupt a drain: the application enforces the deadline itself. A drain still pending once the deadline has passed is **abandoned**.
4. **stop.** Every application that was started, including one whose start, readiness or drain failed, is stopped after the last worker has stopped, so no request can still be inside it. A stop still pending after `server.timeouts.stop_ms` is abandoned.

What each overrun or failure costs:

| event | reported as | process outcome |
|---|---|---|
| start fails | `telemetry.error`, operation `start` | the process refuses to start |
| ready fails | operation `ready` | the process stops, reason `FAILED` |
| drain fails | operation `drain` | reason `FAILED` |
| drain overruns its deadline | operation `drain`, code `deadline` | counted in `StopReport.applications_abandoned`, reason `DEADLINE` (exit 75) |
| stop fails | operation `stop` | counted as a cleanup failure |
| stop overruns `stop_ms` | operation `stop`, code `deadline` | counted as abandoned and as a cleanup failure |

Every failure is also printed to stderr with the application's name and the step's `detail`.

**Steps run on the supervisor's thread.** That thread also takes signals, reloads the configuration and drives ACME, and the steps are polled in its loop. A step that blocks stalls all of that, and a blocked drain or stop cannot be abandoned, since abandoning it needs the step to return. A step therefore does its work elsewhere and answers pending until that work is done.

**Reloads.** The registry lives for the whole process. A reload rebuilds the services that reach an application, and resolves each against the same registry again, but never restarts, drains or stops the application.

## Registering and running

### Registering

The embedding program owns the registry and its storage:

```mach
var slots:    [1]service.Application;
var registry: service.Applications;
service.make_applications(?registry, ?slots[0], 1);
service.register_hosted(?registry, "site", handler, hosted, memory_bytes);
```

A registry holds at most `service.MAX_APPLICATIONS` (32), and each name at most once. A configuration routes to an application by naming it as the `application` of a service whose `kind` is `laurel`, the application kind today whatever the framework (see [CONFIGURATION.md](CONFIGURATION.md)). A configuration that names an unregistered application fails with `no application is registered under this name`, at startup or at a reload.

`memory_bytes` is the request memory each request to the application may hold, or zero for the server's `call_memory_bytes`. A service's own `memory_bytes` overrides it. See [Request memory](CONFIGURATION.md#request-memory).

### Running a process

The program then assembles the process around the registry. This is the sequence hedge's own `src/bin/main.mach` runs, with the registry added:

1. Load and seal the first configuration generation: `generation.make_candidate`, `loader.build` into its `graph`, then `generation.seal`.
2. Set `Options.applications` on `composition.default_options()` and call `composition.start_process` with `spread.count(graph)` workers.
3. `supervisor.make`, then `supervisor.attach_reloads` with a `Loader` that seals each reload's candidate into the generation slot the active one is not using.
4. `supervisor.start`, which starts the hosted applications and then the workers. On `START_OK`, `supervisor.run`, which returns once the process has been asked to stop and every worker and every hosted drain has settled.
5. `supervisor.stop`, which joins the workers, stops the hosted applications and returns the `StopReport` the exit status is chosen from.

`connection.message_limits(graph, connection.config_from(graph))` gives the limits hedge commits every response under, for a framework that assembles its application against them before registering it.

## Facilities for hosted code

What hosted code receives from hedge today:

- **Per request, through the call**: the request arena (`call.allocator_of`), the exchange's cancellation scope and deadline (`call.scope`, `call.deadline`, `call.cancelled`), the request's trace context (`active.telemetry`, a W3C trace context hedge parsed or started), and a waker (`call.waker`). hedge logs every request it serves, including the ones a hosted handler answers.
- **Through the lifecycle**: when to start, a readiness check in the process's health, and a drain deadline.
- **Through the embedding program**: the program supplies hedge with things, rather than receiving them. It can hand a `loader.Resolver` that answers the configuration's environment references, a `secret.Resolver` in `composition.Options.telemetry.secrets` for the configuration's `os` and `application` secret providers, and a log sink in `.telemetry.downstream` that receives hedge's own records.

Not yet supplied to hosted code:

- **Background tasks.** A supervisor-owned task facility is [#305](https://github.com/briar-systems/hedge/issues/305). Until it lands, work that runs on its own schedule belongs to the application's own lifecycle components.
- **Secrets.** The secrets a configuration declares are resolved for hedge's own use, the administration credential. Hosted code has no way to borrow one.
- **Configuration.** Hosted code does not read hedge's configuration. What it is told is its registered name and the limits above.
- **Telemetry.** Hosted code cannot write to hedge's log or metrics, or add health checks beyond the readiness check hedge registers for it.

Each of these reaches hosted code through this contract when it lands, as a new item in a minor version of it.

## Memory rules

- **The registry** and its slot storage, every registered `name`, and every `ctx` of a handler or lifecycle stay live and unchanged from registration until `supervisor.stop` returns. hedge only reads them after startup.
- **The request arena** (`call.allocator_of`) lives until the exchange settles, and hedge reclaims it then in one step. A handler allocates its per-request state and response bytes there and frees nothing. Bytes a handler hands to `respond_with_bytes` must live until the exchange settles, which arena bytes do. An allocation the arena refuses is the request's bound running out: `call.memory_refused` says so, and the handler fails or answers without it.
- **Nothing per request outlives the exchange.** A handler that keeps anything past its request copies it into memory it owns, and synchronizes it as the concurrency rule above requires.
- **A step's `detail`** is read before the step returns and never kept, so it may point at the application's own storage.
- **The trace context and the waker** are valid for the exchange and no longer.

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
