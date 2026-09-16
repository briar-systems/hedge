#!/usr/bin/env python3
"""Per-connection service counts under concurrent load.

Each worker owns one connection and issues requests on it back to back. What
this reports is not throughput but the spread across connections, because the
defect this lane exists for served some connections normally while leaving
others unread.

The run is bounded by a service target rather than a clock: it stops as soon as
the median connection has completed `target` requests, and the verdict compares
every other connection against that median. A wall clock would make the verdict
depend on how fast the machine is; a ratio taken inside one run does not.
"""

from __future__ import annotations

import argparse
import http.client
import ssl
import statistics
import sys
import threading
import time
from collections import Counter


def worker(index: int, args, counts: list[int], errors: list[str | None],
           ready: threading.Barrier, stop: threading.Event) -> None:
    try:
        if args.tls:
            context = ssl.create_default_context()
            context.check_hostname = False
            context.verify_mode = ssl.CERT_NONE
            connection = http.client.HTTPSConnection(
                args.host, args.port, context=context, timeout=args.socket_timeout)
        else:
            connection = http.client.HTTPConnection(
                args.host, args.port, timeout=args.socket_timeout)
        connection.connect()
    except Exception as error:
        errors[index] = f"connect: {type(error).__name__}: {error}"
        ready.wait()
        return

    # every connection is established before any request is sent, so the
    # measurement covers steady-state service and not the accept ramp.
    ready.wait()
    try:
        while not stop.is_set():
            connection.request("GET", args.path,
                               headers={"Accept-Encoding": "identity"})
            response = connection.getresponse()
            body = response.read()
            if response.status != 200:
                errors[index] = f"status {response.status}"
                return
            if args.body_bytes and len(body) != args.body_bytes:
                errors[index] = f"body {len(body)} bytes, expected {args.body_bytes}"
                return
            counts[index] += 1
    except Exception as error:
        errors[index] = f"{type(error).__name__}: {error}"
    finally:
        try:
            connection.close()
        except Exception:
            pass


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--path", required=True)
    parser.add_argument("--connections", type=int, required=True)
    parser.add_argument("--target", type=int, required=True,
                        help="stop once the median connection has served this many")
    parser.add_argument("--body-bytes", type=int, default=0,
                        help="expected response body length, 0 to not check")
    parser.add_argument("--tls", action="store_true")
    parser.add_argument("--label", required=True)
    # a safety bound only. reaching it is a failure, not a result: it means the
    # median connection never got its target and the run has nothing to compare.
    parser.add_argument("--deadline", type=float, default=180.0)
    parser.add_argument("--socket-timeout", type=float, default=60.0)
    # the floor every connection must clear, as a fraction of the median.
    parser.add_argument("--floor", type=float, default=0.5)
    args = parser.parse_args()

    counts = [0] * args.connections
    errors: list[str | None] = [None] * args.connections
    ready = threading.Barrier(args.connections + 1)
    stop = threading.Event()

    threads = [threading.Thread(target=worker,
                                args=(i, args, counts, errors, ready, stop),
                                daemon=True)
               for i in range(args.connections)]
    for thread in threads:
        thread.start()
    ready.wait()

    started = time.monotonic()
    expired = False
    while statistics.median(counts) < args.target:
        if time.monotonic() - started > args.deadline:
            expired = True
            break
        time.sleep(0.05)
    stop.set()
    for thread in threads:
        thread.join(timeout=90)
    elapsed = time.monotonic() - started

    median = statistics.median(counts)
    floor = median * args.floor
    starved = sum(1 for n in counts if n < floor)
    reported = [e for e in errors if e]

    print(f"{args.label}: connections={args.connections} elapsed={elapsed:.1f}s "
          f"median={median:.0f} min={min(counts)} max={max(counts)} "
          f"served={sum(counts)} below_floor={starved}")
    if reported:
        for message, seen in Counter(reported).most_common(3):
            print(f"  {seen} connection(s): {message}")

    if expired:
        print(f"  the median connection never reached {args.target} requests "
              f"within {args.deadline:.0f}s, so this run has no verdict")
        return 2
    if reported:
        return 3
    if starved:
        print(f"  {starved} connection(s) served fewer than "
              f"{args.floor:.0%} of the median")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
