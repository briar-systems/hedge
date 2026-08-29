// plain-http front end for pebble's https acme interface.
//
// mach-acme produces typed https wire requests. tls termination belongs to
// mach-tls and is not part of the acme state machine, so the conformance
// harness speaks plain http to this proxy and the proxy speaks https to
// pebble. acme bytes, urls, headers, and status codes pass through unchanged,
// so the library still drives a real acme server.
package main

import (
	"context"
	"crypto/tls"
	"flag"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
)

func main() {
	listen := flag.String("listen", "127.0.0.1:14001", "plain http listen address")
	upstream := flag.String("upstream", "127.0.0.1:14000", "pebble https address")
	flag.Parse()

	target, err := url.Parse("https://" + *upstream)
	if err != nil {
		log.Fatalf("invalid upstream: %v", err)
	}

	proxy := &httputil.ReverseProxy{
		Director: func(r *http.Request) {
			r.URL.Scheme = target.Scheme
			r.URL.Host = target.Host
		},
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
			DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
				return net.Dial("tcp", *upstream)
			},
		},
		ErrorHandler: func(w http.ResponseWriter, r *http.Request, err error) {
			log.Printf("upstream error: %v", err)
			w.WriteHeader(http.StatusBadGateway)
		},
	}

	log.Printf("acme plain-http proxy %s -> %s", *listen, target)
	log.Fatal(http.ListenAndServe(*listen, proxy))
}
