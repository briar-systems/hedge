#!/usr/bin/env python3
"""The hedge serving matrix.

run.sh provisions the binaries, credentials, content and configurations; this
module owns the measurement. One cell is one (protocol, body size, concurrency,
server) combination. Every cell gets a freshly started server, so the peak
resident set it reports is that cell's peak and not a high-water mark left
behind by an earlier one.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import signal
import socket
import statistics
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass, field
from datetime import date
from pathlib import Path

TICKS = os.sysconf("SC_CLK_TCK")

SIZES = [("1k", 1024), ("64k", 65536), ("1m", 1048576)]
CONNECTIONS = [64, 256]
DURATION = 10
WARMUP = 1.0


@dataclass(frozen=True)
class Endpoint:
    """Where one server answers one protocol."""

    url: str
    insecure: bool


@dataclass(frozen=True)
class Protocol:
    key: str
    title: str
    driver: str  # "oha" or "curl-h3"
    oha_version: str | None
    hedge: Endpoint
    caddy: Endpoint

    def endpoint(self, server: str) -> Endpoint:
        return self.hedge if server == "hedge" else self.caddy


PROTOCOLS = [
    Protocol(
        key="h1-cleartext",
        title="HTTP/1.1, cleartext",
        driver="oha",
        oha_version="1.1",
        hedge=Endpoint("http://localhost:18080", False),
        caddy=Endpoint("http://localhost:18081", False),
    ),
    Protocol(
        key="h1-tls",
        title="HTTP/1.1 over TLS 1.3",
        driver="oha",
        oha_version="1.1",
        hedge=Endpoint("https://localhost:18443", True),
        caddy=Endpoint("https://localhost:18444", True),
    ),
    Protocol(
        key="h2-tls",
        title="HTTP/2 over TLS 1.3",
        driver="oha",
        oha_version="2",
        hedge=Endpoint("https://localhost:18443", True),
        caddy=Endpoint("https://localhost:18444", True),
    ),
    Protocol(
        key="h3",
        title="HTTP/3 over QUIC",
        driver="curl-h3",
        oha_version=None,
        hedge=Endpoint("https://localhost:18443", True),
        caddy=Endpoint("https://localhost:18444", True),
    ),
]


@dataclass
class Result:
    protocol: str
    size: str
    connections: int
    server: str
    requests_per_sec: float = 0.0
    mib_per_sec: float = 0.0
    p50_ms: float = 0.0
    p99_ms: float = 0.0
    peak_rss_kib: int = 0
    cpu_seconds: float = 0.0
    ok: bool = True
    note: str = ""


@dataclass
class Server:
    """A server process under measurement."""

    name: str
    argv: list[str]
    cwd: Path
    env: dict[str, str] = field(default_factory=dict)
    proc: subprocess.Popen | None = None
    log: Path | None = None

    def start(self, work: Path) -> None:
        self.log = work / f"{self.name}.log"
        handle = self.log.open("wb")
        environment = dict(os.environ)
        environment.update(self.env)
        self.proc = subprocess.Popen(
            self.argv,
            cwd=str(self.cwd),
            stdout=handle,
            stderr=subprocess.STDOUT,
            env=environment,
            start_new_session=True,
        )
        handle.close()

    def stop(self) -> None:
        if self.proc is None:
            return
        if self.proc.poll() is None:
            self.proc.send_signal(signal.SIGTERM)
            try:
                self.proc.wait(timeout=15)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(timeout=10)
        self.proc = None

    def alive(self) -> bool:
        return self.proc is not None and self.proc.poll() is None

    def usage(self) -> tuple[int, float]:
        """Peak resident set in KiB and CPU seconds across every thread."""
        if self.proc is None:
            return (0, 0.0)
        pid = self.proc.pid
        peak = 0
        try:
            for line in Path(f"/proc/{pid}/status").read_text().splitlines():
                if line.startswith("VmHWM:"):
                    peak = int(line.split()[1])
                    break
        except OSError:
            pass
        cpu = 0.0
        try:
            stat = Path(f"/proc/{pid}/stat").read_text()
            fields = stat[stat.rindex(")") + 2 :].split()
            cpu = (int(fields[11]) + int(fields[12])) / TICKS
        except (OSError, ValueError):
            pass
        return (peak, cpu)

    def tail(self, lines: int = 20) -> str:
        if self.log is None or not self.log.exists():
            return ""
        return "\n".join(self.log.read_text(errors="replace").splitlines()[-lines:])


def wait_for_tcp(port: int, deadline: float) -> bool:
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.5):
                return True
        except OSError:
            time.sleep(0.05)
    return False


def wait_for_udp_reply(curl: str, url: str, deadline: float) -> bool:
    """QUIC has no connect(2) to poll, so the readiness probe is a real request."""
    while time.monotonic() < deadline:
        done = subprocess.run(
            [curl, "-s", "-o", "/dev/null", "--http3-only", "--insecure", "-4",
             "--max-time", "5", f"{url}/1k"],
            capture_output=True,
        )
        if done.returncode == 0:
            return True
        time.sleep(0.2)
    return False


def ports_free(ports: list[int]) -> list[int]:
    busy = []
    for port in ports:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.3):
                busy.append(port)
        except OSError:
            pass
    return busy


def run_oha(oha: str, protocol: Protocol, url: str, connections: int,
            duration: int, insecure: bool) -> tuple[dict, str]:
    argv = [
        oha, "--no-tui", "--output-format", "json", "--disable-compression",
        "--ipv4", "-z", f"{duration}s", "-c", str(connections),
        "--http-version", protocol.oha_version,
        # wait for the requests already in flight when the clock runs out.
        # without this every HTTP/1 cell ends with one aborted request per
        # connection, which is an artefact of the stopwatch and not of the
        # server. HTTP/2 waits regardless.
        "-w",
        "-t", "30s",
    ]
    if insecure:
        argv.append("--insecure")
    argv.append(url)
    done = subprocess.run(argv, capture_output=True, text=True)
    if done.returncode != 0:
        return ({}, f"oha exited {done.returncode}: {done.stderr.strip()[:200]}")
    try:
        return (json.loads(done.stdout), "")
    except json.JSONDecodeError as error:
        return ({}, f"oha output was not JSON: {error}")


def seconds(value) -> float:
    """A percentile oha did not compute is None, not zero."""
    return float(value) if isinstance(value, (int, float)) else 0.0


def read_oha(payload: dict) -> tuple[float, float, float, float, str]:
    summary = payload.get("summary") or {}
    percentiles = payload.get("latencyPercentiles") or {}
    codes = payload.get("statusCodeDistribution") or {}
    errors = payload.get("errorDistribution") or {}

    rps = seconds(summary.get("requestsPerSec"))
    size_per_sec = seconds(summary.get("sizePerSec"))
    p50 = seconds(percentiles.get("p50")) * 1000.0
    p99 = seconds(percentiles.get("p99")) * 1000.0

    notes = []
    non_200 = {code: n for code, n in codes.items() if str(code) != "200"}
    if non_200:
        notes.append(f"non-200 responses: {non_200}")
    if errors:
        notes.append(f"errors: {dict(list(errors.items())[:3])}")
    if not codes and not errors:
        notes.append("oha reported neither a response nor an error")
    return (rps, size_per_sec / (1024 * 1024), p50, p99, "; ".join(notes))


# a cell may overrun its duration by at most this, to let the batch in flight
# when the clock runs out finish. a server that cannot finish it inside the
# grace fails the cell rather than stalling the matrix: one stalled HTTP/3 cell
# held the run for over ten minutes before this bound existed.
H3_GRACE = 30.0

# how many bytes one batch asks for. large enough that process startup is noise,
# small enough that a slow server still completes a batch inside the grace.
H3_BATCH_BYTES = 32 * 1024 * 1024


def run_curl_h3(curl: str, url: str, path: str, body_bytes: int, connections: int,
                duration: int, work: Path) -> tuple[float, float, float, float, str]:
    """An HTTP/3 cell.

    curl is the only HTTP/3 client on this machine, and it is a transfer tool
    rather than a load generator: it has no run-for-a-duration mode, so the cell
    is a sequence of parallel batches repeated until the duration is spent. curl
    multiplexes onto one QUIC connection, so `connections` here bounds concurrent
    streams and not sockets.

    Every batch is bounded by a wall clock as well as by curl's per-transfer
    `--max-time`, because `--max-time` bounds one transfer and says nothing
    about how long a batch of several hundred takes against a server that has
    stopped making progress. A batch that runs out of clock is killed and
    whatever it printed before then is still counted, since curl writes its
    per-transfer line as each transfer completes.
    """
    per_batch = max(connections,
                    min(connections * 4, max(1, H3_BATCH_BYTES // max(body_bytes, 1))))
    config = work / "h3-urls.conf"
    config.write_text(
        "".join(f'url = "{url}{path}"\noutput = "/dev/null"\n' for _ in range(per_batch))
    )
    argv = [curl, "--http3-only", "--insecure", "-4", "-s",
            "--parallel", "--parallel-max", str(connections),
            "--max-time", "30",
            "-w", "%{http_code} %{size_download} %{time_total}\n",
            "--config", str(config)]

    requests = 0
    total_bytes = 0
    failures = 0
    truncated = False
    times: list[float] = []
    started = time.monotonic()
    deadline = started + duration
    while time.monotonic() < deadline:
        budget = deadline - time.monotonic() + H3_GRACE
        try:
            output = subprocess.run(argv, capture_output=True, text=True,
                                    timeout=budget).stdout
        except subprocess.TimeoutExpired as expired:
            truncated = True
            output = expired.stdout or ""
            if isinstance(output, bytes):
                output = output.decode(errors="replace")
        for line in output.splitlines():
            parts = line.split()
            if len(parts) != 3:
                continue
            code, size, seconds = parts
            if code != "200":
                failures += 1
                continue
            requests += 1
            total_bytes += int(size)
            times.append(float(seconds))
        if truncated:
            break
    elapsed = time.monotonic() - started

    notes = []
    if truncated:
        notes.append(f"a batch of {per_batch} requests did not finish within "
                     f"{duration}s + {H3_GRACE:.0f}s of grace")
    if failures:
        notes.append(f"{failures} failed requests")
    if not times:
        notes.append("no HTTP/3 request completed")
        return (0.0, 0.0, 0.0, 0.0, "; ".join(notes))

    times.sort()
    p50 = times[int(len(times) * 0.50)] * 1000.0
    p99 = times[min(int(len(times) * 0.99), len(times) - 1)] * 1000.0
    return (requests / elapsed, total_bytes / (1024 * 1024) / elapsed, p50, p99,
            "; ".join(notes))


def build_servers(args: argparse.Namespace) -> dict[str, Server]:
    root = Path(args.root)
    work = Path(args.work)
    caddy_env = {
        "XDG_CONFIG_HOME": str(work / "caddy-config"),
        "XDG_DATA_HOME": str(work / "caddy-data"),
    }
    return {
        "hedge": Server("hedge", [args.hedge_binary, args.hedge_config], root),
        "caddy": Server(
            "caddy",
            [args.caddy, "run", "--config", args.caddyfile, "--adapter", "caddyfile"],
            root,
            caddy_env,
        ),
    }


def measure(args: argparse.Namespace, protocol: Protocol, size_name: str,
            body_bytes: int, connections: int, server_name: str, duration: int,
            work: Path) -> Result:
    result = Result(protocol.key, size_name, connections, server_name)
    endpoint = protocol.endpoint(server_name)
    server = build_servers(args)[server_name]

    port = int(endpoint.url.rsplit(":", 1)[1])
    busy = ports_free([port])
    if busy:
        result.ok = False
        result.note = f"port {port} was already in use before the cell started"
        return result

    # the server is stopped whatever happens below. a harness fault that left a
    # process holding a port would fail every cell that followed it, and the
    # failure would name the port rather than the fault.
    try:
        server.start(work)
        deadline = time.monotonic() + 30
        if protocol.driver == "curl-h3":
            ready = wait_for_udp_reply(args.curl, endpoint.url, deadline)
        else:
            ready = wait_for_tcp(port, deadline)
        if not ready or not server.alive():
            result.ok = False
            result.note = ("server did not become ready: "
                           + server.tail(8).replace("\n", " | "))
            return result

        time.sleep(WARMUP)

        if protocol.driver == "oha":
            payload, error = run_oha(args.oha, protocol,
                                     f"{endpoint.url}/{size_name}",
                                     connections, duration, endpoint.insecure)
            if error:
                result.ok = False
                result.note = error
            else:
                rps, mib, p50, p99, note = read_oha(payload)
                result.requests_per_sec, result.mib_per_sec = rps, mib
                result.p50_ms, result.p99_ms, result.note = p50, p99, note
                result.ok = rps > 0 and not note
        else:
            rps, mib, p50, p99, note = run_curl_h3(
                args.curl, endpoint.url, f"/{size_name}", body_bytes, connections,
                duration, work)
            result.requests_per_sec, result.mib_per_sec = rps, mib
            result.p50_ms, result.p99_ms, result.note = p50, p99, note
            result.ok = rps > 0 and not note

        if not server.alive():
            result.ok = False
            result.note = ((result.note + "; ") if result.note else "") + \
                "the server exited during the cell: " + \
                server.tail(8).replace("\n", " | ")
        else:
            result.peak_rss_kib, result.cpu_seconds = server.usage()
        return result
    finally:
        server.stop()
        time.sleep(0.4)


def command_output(argv: list[str]) -> str:
    try:
        done = subprocess.run(argv, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        return "unavailable"
    text = (done.stdout or done.stderr).strip().splitlines()
    return text[0] if text else "unavailable"


def machine_description(args: argparse.Namespace) -> list[tuple[str, str]]:
    model = "unknown"
    cores = "unknown"
    threads = "unknown"
    for line in command_all(["lscpu"]).splitlines():
        if line.startswith("Model name:"):
            model = line.split(":", 1)[1].strip()
        elif line.startswith("CPU(s):"):
            threads = line.split(":", 1)[1].strip()
        elif line.startswith("Core(s) per socket:"):
            cores = line.split(":", 1)[1].strip()

    memory = "unknown"
    try:
        for line in Path("/proc/meminfo").read_text().splitlines():
            if line.startswith("MemTotal:"):
                memory = f"{int(line.split()[1]) // 1024 // 1024} GiB"
                break
    except OSError:
        pass

    # the binary carries no version flag: it reads argv[1] as a configuration
    # path and fails on anything else. tools/check-version.sh holds mach.toml
    # and src/hedge.mach to one version, so the manifest is the authority.
    hedge_version = read_manifest_version(Path(args.root) / "mach.toml")

    return [
        ("CPU", f"{model}, {cores} cores / {threads} threads"),
        ("Memory", memory),
        ("Kernel", os.uname().release),
        ("Mach", command_output(["mach", "info"])),
        ("hedge", hedge_version),
        ("Caddy", command_output([args.caddy, "version"])),
        ("oha", command_output([args.oha, "--version"])),
        ("curl", command_output([args.curl, "--version"])),
        ("OpenSSL", command_output(["openssl", "version"])),
    ]


def command_all(argv: list[str]) -> str:
    try:
        done = subprocess.run(argv, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return done.stdout


def read_manifest_version(manifest: Path) -> str:
    try:
        for line in manifest.read_text().splitlines():
            if line.strip().startswith("version"):
                return "hedge " + line.split("=", 1)[1].strip().strip('"')
    except OSError:
        pass
    return "unknown"


def cell(results: dict, protocol: str, size: str, connections: int,
         server: str) -> Result | None:
    return results.get((protocol, size, connections, server))


def number(value: float, places: int = 0) -> str:
    if places:
        return f"{value:,.{places}f}"
    return f"{value:,.0f}"


def render(results: dict, args: argparse.Namespace, duration: int,
           elapsed: float) -> str:
    lines: list[str] = []
    add = lines.append

    add(f"# hedge serving benchmark, {date.today().isoformat()}")
    add("")
    add("Produced by `doc/bench/run.sh`. Read `doc/bench/README.md` for what each")
    add("column means and what the numbers do not say.")
    add("")
    add("## Machine")
    add("")
    add("| | |")
    add("| --- | --- |")
    for label, value in machine_description(args):
        add(f"| {label} | {value} |")
    add("")
    add(f"Every cell ran for {duration} seconds against a freshly started server,")
    add(f"after a {WARMUP:.0f} second warmup. The whole matrix took "
        f"{elapsed / 60:.0f} minutes.")
    add("")

    for protocol in PROTOCOLS:
        add(f"## {protocol.title}")
        add("")
        if protocol.driver == "curl-h3":
            add("Driven by the curl batch harness, not by `oha`. These numbers are")
            add("comparable with each other and with nothing else in this file.")
            add("")
        add("| body | conns | server | req/s | MiB/s | p50 ms | p99 ms | peak RSS | CPU s |")
        add("| --- | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |")
        for size_name, _ in SIZES:
            for connections in CONNECTIONS:
                for server in ("hedge", "caddy"):
                    found = cell(results, protocol.key, size_name, connections, server)
                    if found is None:
                        continue
                    if not found.ok:
                        add(f"| {size_name} | {connections} | {server} | "
                            f"failed | | | | | |")
                        continue
                    rss = f"{found.peak_rss_kib / 1024:,.0f} MiB"
                    add(f"| {size_name} | {connections} | {server} | "
                        f"{number(found.requests_per_sec)} | "
                        f"{number(found.mib_per_sec, 1)} | "
                        f"{number(found.p50_ms, 2)} | "
                        f"{number(found.p99_ms, 2)} | "
                        f"{rss} | {number(found.cpu_seconds, 1)} |")
        add("")

    notes = [r for r in results.values() if r.note]
    if notes:
        add("## Cells that reported something")
        add("")
        for found in sorted(notes, key=lambda r: (r.protocol, r.size, r.connections)):
            add(f"- `{found.protocol}` {found.size} at {found.connections} "
                f"on {found.server}: {found.note}")
        add("")

    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    parser.add_argument("--hedge-binary", required=True)
    parser.add_argument("--oha", required=True)
    parser.add_argument("--caddy", required=True)
    parser.add_argument("--hedge-config", required=True)
    parser.add_argument("--caddyfile", required=True)
    parser.add_argument("--content", required=True)
    parser.add_argument("--work", required=True)
    parser.add_argument("--curl", default=shutil.which("curl") or "curl")
    parser.add_argument("--smoke", action="store_true",
                        help="one short cell per protocol; writes no results file")
    parser.add_argument("--out", default=None)
    args = parser.parse_args()

    work = Path(args.work)

    # one clear failure now beats every cell failing on a port it did not open.
    busy = ports_free([18080, 18081, 18443, 18444])
    if busy:
        print(f"ports {busy} are already in use; the matrix owns 18080, 18081, "
              f"18443 and 18444", file=sys.stderr)
        return 2

    duration = 2 if args.smoke else DURATION
    sizes = [SIZES[1]] if args.smoke else SIZES
    connections = [CONNECTIONS[0]] if args.smoke else CONNECTIONS

    results: dict = {}
    total = len(PROTOCOLS) * len(sizes) * len(connections) * 2
    index = 0
    started = time.monotonic()
    failures = 0

    for protocol in PROTOCOLS:
        for size_name, body_bytes in sizes:
            for count in connections:
                for server in ("hedge", "caddy"):
                    index += 1
                    label = (f"[{index}/{total}] {protocol.key} {size_name} "
                             f"c={count} {server}")
                    print(label, flush=True)
                    found = measure(args, protocol, size_name, body_bytes,
                                    count, server, duration, work)
                    results[(protocol.key, size_name, count, server)] = found
                    if found.ok:
                        print(f"    {found.requests_per_sec:,.0f} req/s  "
                              f"{found.mib_per_sec:,.1f} MiB/s  "
                              f"p50 {found.p50_ms:.2f}ms  p99 {found.p99_ms:.2f}ms  "
                              f"rss {found.peak_rss_kib / 1024:,.0f}MiB",
                              flush=True)
                    else:
                        failures += 1
                        print(f"    FAILED {found.note}", flush=True)

    elapsed = time.monotonic() - started

    if args.smoke:
        print(f"\nsmoke: {total - failures}/{total} cells produced numbers")
        return 1 if failures else 0

    document = render(results, args, duration, elapsed)
    if args.out:
        destination = Path(args.out)
    else:
        hostname = socket.gethostname().split(".")[0]
        destination = (Path(args.root) / "doc" / "bench" / "results" /
                       f"{date.today().isoformat()}-{hostname}.md")
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(document)
    print(f"\nwrote {destination}")
    if failures:
        print(f"{failures} of {total} cells failed; the results file names them")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
