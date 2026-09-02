import socket
import sys


def exchange(reader, stream, path, extra=None):
    fields = [
        f"GET {path} HTTP/1.1",
        "Host: localhost",
        "Connection: keep-alive",
    ]
    fields.extend(extra or [])
    stream.sendall(("\r\n".join(fields) + "\r\n\r\n").encode("ascii"))
    status_line = reader.readline().decode("latin-1").rstrip("\r\n")
    if not status_line:
        raise RuntimeError("server closed before the response head")
    headers = {}
    while True:
        line = reader.readline()
        if line in (b"\r\n", b"\n", b""):
            break
        name, value = line.decode("latin-1").split(":", 1)
        headers.setdefault(name.lower(), []).append(value.strip())
    length = int(headers.get("content-length", ["0"])[-1])
    body = reader.read(length).decode("latin-1")
    return int(status_line.split(" ", 2)[1]), headers, body


stream = socket.create_connection(("127.0.0.1", 19090), timeout=10)
stream.settimeout(10)
reader = stream.makefile("rb")
scenario = sys.argv[1]

if scenario == "item":
    exchange(reader, stream, "/item")
    second = exchange(reader, stream, "/item")
    third = exchange(reader, stream, "/item")
    removed = "present" if "x-remove" in second[1] else "absent"
    print("/".join([
        str(second[0]), str(third[0]), second[2].strip(),
        second[1].get("etag", [""])[-1],
        second[1].get("x-refresh", [""])[-1],
        second[1].get("x-preserve", [""])[-1], removed,
    ]))
elif scenario == "covered":
    controls = ["Cache-Control: no-cache"]
    exchange(reader, stream, "/error-covered", controls)
    second = exchange(reader, stream, "/error-covered", controls)
    print(f"{second[0]}/{second[2].strip()}/{second[1].get('connection', [''])[0]}")
elif scenario == "leak":
    response = exchange(reader, stream, "/leak", ["Cache-Control: no-cache"])
    print(f"{response[0]}/{response[2].strip()}")
elif scenario == "refused":
    exchange(reader, stream, "/error-refused")
    second = exchange(reader, stream, "/error-refused")
    print(str(second[0]))
elif scenario == "multi":
    ranges = ["Range: bytes=0-1,8-9"]
    exchange(reader, stream, "/multi", ranges)
    second = exchange(reader, stream, "/multi", ranges)
    print(f"{second[0]}/{second[2]}")
else:
    raise RuntimeError(f"unknown scenario: {scenario}")

reader.close()
stream.close()
