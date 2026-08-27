# Required mach-std work

This file is the temporary issue backlog for upstream `mach-std`. Each numbered section is intended to become one focused issue. The contracts are defined against all supported platforms so downstream libraries do not freeze assumptions from one operating system.

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
```

## 1. Native resource handles and normalized I/O errors

**Proposed issue:** `feat(os): define native resource handles and normalized I/O errors`

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

**Proposed issue:** `feat(net): make endpoints dual-stack and transport-neutral`

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

**Proposed issue:** `feat(net): expose atomic socket flags and production socket options`

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

**Proposed issue:** `feat(io): add a portable operation-completion runtime`

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

**Proposed issue:** `feat(io): integrate monotonic timers and wakeups`

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

**Proposed issue:** `feat(sync): add hierarchical cancellation scopes`

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

**Proposed issue:** `feat(net): implement asynchronous tcp and udp over std io`

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

**Proposed issue:** `feat(io): add asynchronous file operations and transfer metadata`

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

**Proposed issue:** `feat(sync): add mutex, condition, semaphore, and once primitives`

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

**Proposed issue:** `feat(sync): add bounded channels and worker pools`

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

**Proposed issue:** `feat(process): expose termination and reload events`

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

**Proposed issue:** `feat(io): define close and drain behavior for live resources`

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

**Proposed issue:** `fix(sync): make thread resources reclaimable on every target`

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

**Proposed issue:** `feat(io): support atomic record writes for concurrent logs`

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

**Proposed issue:** `feat(types): add checked byte cursor and builder primitives`

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

**Proposed issue:** `feat(test): add deterministic io and allocation fault facilities`

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

**Proposed issue:** `ci: run the complete runtime suite on native supported targets`

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

## Upstream issue conversion

When these sections move upstream:

1. Verify the current `mach-std` source because its active branch may already address part of a requirement.
2. Open one issue per numbered contract.
3. Preserve cross-platform acceptance criteria even when the first implementation lands on one target.
4. Link dependent issues rather than weakening their public contract.
5. Remove a section from this file only after the upstream issue exists and is linked here.

