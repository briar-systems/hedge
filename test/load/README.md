# Concurrent-connection fairness

This harness holds many connections open against the real Hedge executable at
once and asserts that service reaches all of them. It exists because
[#122](https://github.com/briar-systems/hedge/issues/122) shipped: TLS
connections went unserved under concurrent load for as long as there has been a
published benchmark, and no test noticed, because every other test in the suite
drives one connection at a time.

```sh
mach build . --profile release
./test/load/run.sh
```

`HEDGE_BINARY` qualifies a different build. `LOAD_CONNECTIONS` and `LOAD_TARGET`
change the shape of the load. The runner binds 127.0.0.1 ports 19100 and 19101
and releases the server on every exit path.

## What it asserts

Each of `LOAD_CONNECTIONS` workers owns one connection and issues requests on it
back to back. The run stops as soon as the median connection has completed
`LOAD_TARGET` requests, and then every connection must have completed at least
half of that median.

The verdict is a ratio taken inside a single run, never a duration. A slow
machine moves every connection's count together and the ratio does not move, so
the lane says the same thing on a loaded runner as on an idle one, and a failure
is a real loss of fairness rather than a missed deadline.

A run whose median connection never reaches the target inside the safety
deadline reports no verdict and fails. It has measured nothing, and saying so is
worth more than a number that came from a truncated run.

## Why there are two cells

The cleartext cell is the control. It shares the load generator, the machine and
the body with the TLS cell, so a cleartext failure means the run itself is not
trustworthy rather than that Hedge is unfair. Under the defect #122 tracked, the
cleartext cell passes and the TLS cell does not, which is what placed the fault
below TLS rather than in HTTP.

## Why it is not a `mach test` case

The property needs hundreds of live connections and a real TLS handshake on
each. `mach test` runs its cases as parallel processes sharing one machine, so a
case that saturates the box would change what every other case measures. It
belongs in a CI lane against a release build instead.

## Why it is not in CI yet

The TLS cell does not pass on this branch, and it is not supposed to. It fails
on mach-std v2.1.0, which is what `dev` pins, with around half the connections
served less than half of what the median connection got. That is
[#122](https://github.com/briar-systems/hedge/issues/122), still open, and this
lane is the thing that measures it.

Wiring it into `.github/workflows/ci.yml` therefore waits for the pin bump in
[#128](https://github.com/briar-systems/hedge/pull/128), which is where it first
goes green. Adding the step here would only put a permanently red check on
`dev`, and a check that always fails is ignored as quickly as one that can never
fail.

Until then it is run by hand, which is the point of landing it early: anything
touching how the connection plane schedules work can be measured against it
before the pin moves.
