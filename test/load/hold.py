#!/usr/bin/env python3
"""Hold served HTTP/1.1 connections open until told to let go.

Opens `--connections` connections, completes one request on each, and prints
`held N` where N is how many were served. It then keeps every connection open
until its standard input closes, so another client can be measured against a
server that is already carrying this load.
"""

from __future__ import annotations

import argparse
import http.client
import sys


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="localhost")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--path", default="/body")
    parser.add_argument("--connections", type=int, required=True)
    parser.add_argument("--timeout", type=float, default=30.0)
    args = parser.parse_args()

    held = []
    for _ in range(args.connections):
        connection = http.client.HTTPConnection(args.host, args.port,
                                                timeout=args.timeout)
        try:
            connection.request("GET", args.path,
                               headers={"Accept-Encoding": "identity"})
            response = connection.getresponse()
            response.read()
            if response.status == 200:
                held.append(connection)
                continue
        except OSError:
            pass
        connection.close()

    print(f"held {len(held)}", flush=True)
    sys.stdin.read()
    for connection in held:
        connection.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
