# A static site

The smallest thing hedge does: hand a directory to a `static` service and route
everything to it.

## Run it

```sh
./demo/static/run.sh
```

The server prints two lines and then waits:

```
hedge: listening public 127.0.0.1:8080
hedge: ready
```

## Check it

```sh
curl http://localhost:8080/
curl http://localhost:8080/hello.txt
```

The second prints `hello from hedge`. The first prints the index page, because
`index = "index.html"` makes a request for a directory serve that file.

The listener also offers HTTP/2, which a cleartext client reaches by prior
knowledge rather than by negotiation:

```sh
curl --http2-prior-knowledge -o /dev/null -w '%{http_code} HTTP/%{http_version}\n' \
    http://localhost:8080/hello.txt
```

prints `200 HTTP/2`.

## The configuration

[`hedge.toml`](hedge.toml) has four blocks and nothing else.

`[[listener]]` binds an address and names the protocols it will serve.
`[host.site]` says which names that listener answers to. `[service.files]`
points a static service at a directory. `[[route]]` sends every path to it.

The name matters. hedge routes on the `Host` header, so a request to
`http://127.0.0.1:8080/` is answered `404`: `127.0.0.1` is not a name any host
in this configuration declares. Use `localhost`, or add it to the host block.

Nothing else is switched on. No cache is constructed, no proxy pool is
allocated, no telemetry worker starts. Those cost nothing until a configuration
asks for them.
