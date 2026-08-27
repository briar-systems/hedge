# Required mach-std work

This file records the standard-library contracts needed for a production service stack. Implementation is tracked in the [`mach-std` v0.29.0 milestone](https://github.com/briar-systems/mach-std/milestone/3). The contracts are defined against all supported platforms so downstream libraries do not freeze assumptions from one operating system.

## Dependency order

```text
1 handle and error model
  -> 2 endpoint model
  -> 3 socket creation and options
  -> 4 operation completion
       -> 5 timers and wakeups
       -> 6 cancellation
       -> 7 tcp and udp operations
       -> 8 asynchronous files

9 sleeping synchronization
  -> 10 bounded queues and workers

11 process lifecycle
  -> 12 graceful resource interruption

13 thread resource ownership
14 structured atomic output
15 checked byte cursor
16 test and fault facilities
17 target-native CI

4 operation completion
  -> 18 asynchronous name resolution
  -> 19 asynchronous local sockets
```

## 1. Native resource handles and normalized I/O errors

**Upstream issue:** [`mach-std#484`](https://github.com/briar-systems/mach-std/issues/484)

### Need

Portable networking currently exposes an `i32` file descriptor assumption. Windows sockets are pointer-width values. Raw negative error values and string errors also prevent portable retry, timeout, cancellation, reset, and close handling.

### Contract

- opaque socket and file handle types preserve native width and invalid sentinels
- handle conversion is contained inside target backends
- `IoError` has stable portable kinds plus target code and operation context
- kinds include interrupted, would-block, timeout, cancelled, refused, reset, aborted, closed, address-in-use, unreachable, permission, resource-exhausted, invalid, unsupported, and other
- errors preserve target detail without making callers switch on target numbers

### Acceptance

- Windows socket values round-trip without narrowing
- every network call maps documented platform errors
- retry classification is identical across targets
- no public API accepts a raw integer descriptor

## 2. General IPv4 and IPv6 endpoints

**Upstream issue:** [`mach-std#485`](https://github.com/briar-systems/mach-std/issues/485)

### Need

The address union already represents IPv6, but TCP endpoints remain IPv4-specific.

### Contract

- endpoint contains an address union, port, and optional IPv6 scope identifier
- parsing and formatting cover IPv4, bracketed IPv6, zones, and ports
- sockaddr conversion supports every target without exposing target layout
- unspecified, loopback, mapped-address, multicast, and classification helpers are available

### Acceptance

- round-trip tests cover canonical and noncanonical textual inputs
- live TCP and UDP tests bind and connect over IPv4 and IPv6
- scope identifiers are preserved where supported

## 3. Atomic socket creation and production options

**Upstream issue:** [`mach-std#486`](https://github.com/briar-systems/mach-std/issues/486)

### Need

Servers must not race while adding nonblocking or close-on-exec state after creating or accepting a socket.

### Contract

- creation and accept request nonblocking and non-inheritable state atomically where supported
- target backends use the nearest safe primitive where atomic flags are unavailable
- typed options cover reuse address, reuse port, exclusive address, nodelay, keepalive and probes, send and receive buffers, dual-stack policy, traffic class, fast open where supported, and linger
- local and remote endpoint queries are available
- unsupported options return `unsupported`, never success

### Acceptance

- child-process tests prove sockets are not inherited
- accepted sockets have requested flags before publication
- option get and set behavior has native target coverage

## 4. Portable operation-completion runtime

**Upstream issue:** [`mach-std#487`](https://github.com/briar-systems/mach-std/issues/487)

### Need

HTTP, TLS, QUIC, MQTT, LSP, files, timers, and process control need one scalable ownership model. A readiness-only public API cannot represent IOCP without downstream state duplication.

### Contract

- runtime has explicit create, submit, wait, wake, and close operations
- each submitted operation has a stable token and caller context
- operations retain borrowed buffers until one completion resolves them
- supported kinds include accept, connect, read, write, receive-from, send-to, file read, file write, timer, process wait, and user wakeup where the target permits them
- completion reports bytes or resource, normalized error, and end-of-stream state
- queue capacity and overflow behavior are explicit
- one runtime can be driven by one owner or an explicitly supported owner set

### Backends

- Linux uses epoll, io_uring, or both behind the same contract
- Darwin uses kqueue and nonblocking operations
- Windows uses IOCP and overlapped operations

### Acceptance

- buffers cannot complete twice
- closing a runtime resolves or rejects every outstanding operation
- fairness and starvation tests cover sustained mixed operation types
- a shared conformance suite runs against every backend

## 5. Monotonic timers and runtime wakeups

**Upstream issue:** [`mach-std#488`](https://github.com/briar-systems/mach-std/issues/488)

### Need

Connection deadlines, retries, QUIC recovery, ACME renewal, cache expiry, and graceful drain require timers in the same wait domain as I/O.

### Contract

- timers use absolute monotonic deadlines
- cancellation has a defined race with expiry
- large timer populations use bounded or amortized-efficient storage
- a user wakeup interrupts a blocked wait without a signal race
- wall-clock changes do not alter protocol deadlines

### Acceptance

- early and late tolerance is specified and measured
- clock adjustment tests leave monotonic timers ordered
- wakeup coalescing cannot lose the final wakeup

## 6. Hierarchical cancellation

**Upstream issue:** [`mach-std#489`](https://github.com/briar-systems/mach-std/issues/489)

### Need

Process shutdown, listener drain, connection close, request deadlines, upstream attempts, and application work form a cancellation tree.

### Contract

- a scope can create child scopes
- cancellation is idempotent and observable
- a scope can be paired with an absolute deadline
- operation submission either observes prior cancellation or becomes owned by the scope
- completion identifies cancellation separately from timeout and transport close

### Acceptance

- cancellation races with submission and completion are exhaustively tested
- cancelling a parent eventually resolves every child operation
- scope destruction with live operations is rejected or safely drains them

## 7. Complete asynchronous TCP and UDP operations

**Upstream issue:** [`mach-std#490`](https://github.com/briar-systems/mach-std/issues/490)

### Need

The blocking socket surface cannot drive high connection counts, TLS state, or QUIC efficiently.

### Contract

- listeners submit bounded accepts
- streams submit connect, read, write, vectored write, shutdown, and close
- UDP submits batched receive and send with peer and local-address metadata
- partial completion and zero-length datagrams are represented correctly
- write shutdown waits for prior writes according to an explicit rule
- datagram truncation is observable

### Acceptance

- fragmentation, reset, half-close, cancellation, timeout, and saturation tests run natively
- UDP preserves destination address and interface metadata needed by QUIC
- no backend allocates without charging the operation owner

## 8. Asynchronous and transfer-oriented files

**Upstream issue:** [`mach-std#491`](https://github.com/briar-systems/mach-std/issues/491)

### Need

Static files, logs, caches, certificates, and configuration reload require file work that cannot block the network owner.

### Contract

- offset-based reads and writes integrate with completion or a bounded worker adapter
- directory-relative open supports confinement
- metadata exposes stable identity, size, modification time, and type
- file replacement, synchronization, mapping, and watching have portable contracts
- platform transfer acceleration is exposed as an optional capability

### Acceptance

- root-confined path tests include traversal, links, rename races, and deletion
- short reads, truncation, replacement, and disk-full behavior are tested
- file work cannot create an unbounded worker population

## 9. Sleeping synchronization primitives

**Upstream issue:** [`mach-std#492`](https://github.com/briar-systems/mach-std/issues/492)

### Need

The current spin mutex is suitable only for extremely short contention. Work queues, caches, certificate generations, and telemetry need sleeping primitives.

### Contract

- mutex blocks without indefinite CPU spinning
- condition wait atomically releases and reacquires its mutex
- semaphore supports bounded resource accounting
- once publishes initialized state with defined memory ordering
- poisoning is either explicitly unsupported or fully specified

### Acceptance

- contention tests cover oversubscription and cancellation where applicable
- target-native race tests verify publication and wake behavior
- no primitive leaks a platform handle

## 10. Bounded queues and worker pools

**Upstream issue:** [`mach-std#493`](https://github.com/briar-systems/mach-std/issues/493)

### Need

File adapters, CPU-heavy cryptography, compression, application work, and telemetry require bounded handoff from I/O owners.

### Contract

- queue capacity is fixed or explicitly resized
- send supports immediate, blocking, deadline, and cancellation modes
- close wakes producers and consumers with a distinct result
- worker pool defines task ownership, panic or failure behavior, shutdown, and joining
- rejected work remains owned by the submitter

### Acceptance

- overload never allocates past configured capacity
- close and cancellation races do not lose tasks or wakeups
- worker resources return after shutdown on every target

## 11. Portable process lifecycle events

**Upstream issue:** [`mach-std#494`](https://github.com/briar-systems/mach-std/issues/494)

### Need

Production services must react to native stop, interrupt, reload, console, and service-control events without unsafe application signal handlers.

### Contract

- process events arrive through a waitable or runtime-integrated source
- supported events include terminate, interrupt, reload where conventional, and service stop where applicable
- registration and restoration are explicit
- SIGPIPE behavior is configured once before serving
- event coalescing and priority are specified

### Acceptance

- native tests deliver each supported event
- repeated events cannot corrupt state
- default process behavior is restored after the owner closes

## 12. Interruptible listeners and graceful resource close

**Upstream issue:** [`mach-std#495`](https://github.com/briar-systems/mach-std/issues/495)

### Need

Closing a listener or runtime during shutdown must reliably unblock waiters and resolve outstanding operations.

### Contract

- resources transition through open, closing, and closed states
- no new operations attach after closing begins
- close completion identifies when all prior operations have resolved
- graceful and abortive connection close are distinct
- duplicate close is safe and observable

### Acceptance

- close races with accept, read, write, timer, and cancellation on every backend
- all waiters wake without polling
- handles are released exactly once

## 13. Thread resource ownership

**Upstream issue:** [`mach-std#496`](https://github.com/briar-systems/mach-std/issues/496)

### Need

Thread stacks, startup contexts, handles, and completion state require one portable owner. Current target behavior is not uniform and the Windows startup allocation can outlive the thread permanently.

### Contract

- spawn accepts a context without global handoff state
- stack reserve and commit policy are configurable within platform constraints
- join reclaims every library-owned resource
- detached threads have explicit self-reclamation
- thread names and identifiers are available for diagnostics

### Acceptance

- repeated spawn and join returns memory and handle counts to baseline
- context destruction occurs exactly once
- failure at every spawn stage releases prior resources

## 14. Atomic structured output

**Upstream issue:** [`mach-std#497`](https://github.com/briar-systems/mach-std/issues/497)

### Need

Current logging emits one record through multiple writes, so concurrent records may interleave. Hedge also needs structured fields and bounded telemetry queues.

### Contract

- one logical record is serialized before publication
- sinks accept one byte region or vectored record atomically at the library boundary
- write failure and partial persistence are reported
- field values remain typed until encoding
- timestamp source and precision are explicit

### Acceptance

- concurrent writers never interleave one record in the process sink
- oversized records follow a documented truncate or reject policy
- failed sinks cannot block all producers indefinitely

## 15. Checked bounded byte cursor

**Upstream issue:** [`mach-std#498`](https://github.com/briar-systems/mach-std/issues/498)

### Need

HTTP, TLS, QUIC, DNS, MQTT, compression, and file formats all need bounds-checked incremental byte access. Reimplementing pointer arithmetic in every parser multiplies the memory-safety surface.

### Contract

- cursor tracks byte region, position, and remaining length
- reads and skips fail without advancing on insufficient input
- endian integer and subview operations check overflow
- builder writes fail without partial logical fields
- reservation and commit support length-prefixed encoding safely
- no operation constructs an out-of-region pointer

### Acceptance

- exhaustive small-region tests cover every offset and width
- property tests compare cursor behavior to a simple reference model
- optimizer and target regressions cover all primitive operations

## 16. Deterministic fault and network test facilities

**Upstream issue:** [`mach-std#499`](https://github.com/briar-systems/mach-std/issues/499)

### Need

Production protocol code must test every short operation and failure point without depending on timing or a live network.

### Contract

- scripted readers and writers produce chosen fragmentation and errors
- allocators fail on a selected allocation or budget
- clocks and timer delivery can be controlled in tests
- datagram networks can inject loss, duplication, delay, reordering, and address changes
- seeds and scripts serialize into reproducible failure artifacts

### Acceptance

- facilities themselves have deterministic self-tests
- a failure can be replayed without wall-clock sleeps
- test-only facilities cannot enter release artifacts accidentally

## 17. Native CI for supported runtime targets

**Upstream issue:** [`mach-std#500`](https://github.com/briar-systems/mach-std/issues/500)

### Need

Networking, signals, IOCP, kqueue, filesystem behavior, and thread lifetime cannot be qualified through cross-compilation or compatibility layers alone.

### Contract

- every supported production target runs the complete relevant standard-library suite natively
- target runners collect resource-leak and executable-format evidence
- known failures are explicit, owned, dated, and release-gating according to policy
- flaky tests are treated as defects in code or test ownership

### Acceptance

- Linux x86-64, Linux arm64, Darwin x86-64, Darwin arm64, and Windows x86-64 have native results
- release tags require the supported target matrix
- socket, timer, cancellation, thread, process, and file suites are never selectively omitted without a recorded support change

## 18. Asynchronous system name resolution

**Upstream issue:** [`mach-std#501`](https://github.com/briar-systems/mach-std/issues/501)

### Need

Outbound clients and certificate automation need system-policy name resolution without blocking an I/O owner or assuming one IPv4 result.

### Contract

- resolution is an asynchronous operation with a stable token and caller context
- queries cover host, service, family, socket kind, protocol, and resolver flags
- results are bounded, ordered endpoints with optional canonical names
- numeric addresses take a nonblocking fast path
- deadlines and cancellation resolve through the common operation model
- result storage has explicit allocator and lifetime ownership
- targets without native asynchronous resolution use a bounded worker adapter

### Acceptance

- tests cover numeric IPv4 and IPv6, local names, service names, no result, multiple results, cancellation, and deadlines
- resolution does not block the runtime owner
- fallback workers remain bounded under saturation
- controlled resolver inputs produce deterministic ordering

## 19. Asynchronous local transports

**Upstream issue:** [`mach-std#502`](https://github.com/briar-systems/mach-std/issues/502)

### Need

Administrative endpoints, process supervision, and local service integration need a portable asynchronous transport without forcing TCP onto the host network stack.

### Contract

- a tagged local endpoint represents filesystem paths, abstract names, and target-specific named endpoints
- listeners and streams support bind, listen, accept, connect, read, write, shutdown, and close through the common operation model
- byte streams are the portable baseline, with message or datagram behavior exposed only as capabilities
- path ownership, permissions, stale endpoint removal, cleanup, and rename behavior are explicit
- peer identity is exposed where the target can provide it
- truncation is observable for message-oriented variants

### Acceptance

- native lifecycle and cleanup tests run on Linux, Darwin, and Windows
- Linux tests cover filesystem and abstract namespace endpoints
- Windows tests cover AF_UNIX or a contract-compatible named-pipe backend
- peer identity, saturation, cancellation, and close races are tested where supported

## Synchronization policy

The upstream issue is the implementation-status source. Keep this file aligned with accepted contract changes, preserve cross-platform acceptance criteria when implementation lands incrementally, and link follow-up issues rather than weakening a public contract.
