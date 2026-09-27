# the fuzz lane

`corpus/<boundary>/` holds the retained inputs for every untrusted-input entry
point of hedge. Each directory pairs with a row of the registry in
`src/boundaries.mach`, which names the harness that answers it:

| group | boundary | entry point |
|---|---|---|
| wire framing | `proxy-v1`, `proxy-v2` | `protocol.proxy_protocol.decode`, trusted and not |
| | `prologue` | `protocol.prologue.evaluate` under every PROXY mode, trust, TLS and end-of-input |
| | `cleartext` | `protocol.selection.select_cleartext` |
| | `acme-response` | `acme.wire.parse_response`, open and closed, GET and HEAD |
| QUIC and HTTP/3 | `routing` | `protocol.quic.routing` publish, withdraw and lookup |
| | `local-cid` | `protocol.quic.runtime.adopt_local_cid` |
| | `arrivals` | `protocol.quic.arrivals`: `class_of`, `hold`, `take` |
| | `stateless` | `protocol.quic.stateless`: `claim`, `release` |
| | `pending-initial` | `protocol.quic.holding`: `hold`, `release`, `move` |
| | `h3-request-headers` | `protocol.h3.session.copy_request_fields` |
| | `h3-response-headers` | `protocol.h3.session.response_headers` |
| request line and headers | `pseudo-method`, `pseudo-target` | `protocol.pseudo.method_of`, `target_of`, for HTTP/2 and HTTP/3 |
| | `dispatch` | `dispatch.plan.match` against a fixed plan |
| | `forwarding` | `proxy.forward.copy_fields` and `copy_request_fields` |
| | `forwarded` | `proxy.forward.format_forwarded` |
| | `trace` | `telemetry.trace.parse` and `parse_bounded` |
| | `admin` | `telemetry.admin.handle` and `authenticate_bearer` |
| HTTP semantics | `range` | `http.range.resolve` |
| | `http-date` | `http.date.parse` |
| | `cache-control` | `http.cache_control.parse`, and `cache.policy.reuse` under the result |
| | `validator` | `http.validator.strong_match`, `weak_match` and `evaluate` |
| | `cache-key`, `vary` | `cache.key.make`, `select`, `matches` |
| paths | `static-path` | `service.static.resolve` |
| | `accept-encoding` | `service.static.accepts` |
| | `media` | `http.media.for_path` |
| | `acme-challenge-path` | `acme.challenge.http01_token` |
| config and files | `config` | `config.loader.build` |
| | `trusted-peer` | `protocol.trust.parse` and `add` |
| | `pem-bundle` | `acme.anchors.load_bundle` |
| | `acme-durable` | `acme.durable.open` and `open_account_key` |
| | `acme-url` | `acme.wire.split_url` |

A boundary whose entry point takes more than one string reads its input as
lines, and field lines are `name: value`. A field an HTTP parser would refuse is
dropped, because hedge is only handed fields a parser accepted. The QUIC
queue boundaries read their input as a script of operations, answered against
a model of what the queue must hold.

## Answers

An input is answered when its entry point parses it or refuses it as it says it
will, and every view the parse publishes lies inside the input or the storage it
was copied into. A harness also checks what its parser promises: a PROXY header
decodes the same from its own bytes and every shorter prefix of it waits, a
cleartext connection is HTTP/2 only by the exact preface, a Range is served only
as RFC 9110 resolves it, an accepted HTTP-date names the instant it parsed to, a
hop-by-hop field never crosses the hop, a resolved static path never leaves its
root, a content coding is served exactly when the client gives it a weight, a
route resolves to the binding its owner published, an arrival is held or
dropped in class order, and an unauthenticated admin request never reaches
routing. Breaking any of these is a finding.

Each input is copied so that it ends on the last byte before an unreadable page
(`std.allocator.testing`), so a parser that reads one byte past its input
faults on the spot. A harness whose parser writes to its input places a copy per
parse. The QUIC queue harnesses allocate from the same guarded allocator and
check that an emptied table gives back everything it took. A crash is a finding.
So is a hang: every walk a harness drives is bounded by its input's length, and
the replay runs under a timeout.

## Running it

From the repository root:

```sh
mach dep pull test/fuzz
mach build test/fuzz
test/fuzz/out/linux-x86_64/debug/bin/fuzz replay
test/fuzz/out/linux-x86_64/debug/bin/fuzz one <boundary> <file>
test/fuzz/out/linux-x86_64/debug/bin/fuzz mutate <boundary|all> <runs> <seed> [--retain]
```

The file boundaries write their input under `test/fuzz/out/work`, so one lane
runs at a time in a checkout.

`replay` answers every retained input and fails on a finding, on an empty
boundary directory, or on a directory no boundary answers. CI replays it in both
profiles on the heavy tier: a pull request into `main`, or a dispatch with
`heavy: fuzz` or `heavy: all`. `mach build test/fuzz` runs on every pull request
so the lane cannot rot.

`mutate` is the on-demand search. It draws from a boundary's corpus, applies one
to three structural mutations (flip a bit, set a byte, truncate, extend, swap,
zero a run) from one seeded generator, and answers the result, so a seed and a
run count replay exactly. A finding is written to
`test/fuzz/out/findings/<boundary>/`. With `--retain`, an input whose outcome
the corpus does not hold yet is minimized, by cutting ever smaller chunks while
the outcome holds, and written to its boundary's directory as `m-<outcome>.bin`.

An outcome is what the entry point answered: its status or error, and for an
accepted input the shape it took. For a script it is the set of answers the
script reached. This is not code coverage. There is no coverage instrumentation
for Mach, so two inputs that reach different code with the same answer count as
one.

## The corpus

The named files are valid seeds, each accepted by its entry point: the inputs
of the unit tests the lane replaced, the configurations the demos and the
interop harness run, and the interop fixtures' certificates. The `m-*` files
were retained by `fuzz mutate all 20000 1 --retain`.

A file named for an issue, such as `373-q-zero`, is the minimized input behind
that issue. It stays in the corpus, so the replay keeps the issue fixed.

To retain a new input by hand, put the file in its boundary's directory.
