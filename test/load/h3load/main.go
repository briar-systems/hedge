// Concurrent QUIC connections against the real server.
//
// Every connection completes its handshake before anything else happens, so a
// server that cannot hold them all open fails here as unconnected workers
// rather than as a slow run. With -expect-connected it proves a cap instead:
// exactly that many are admitted and the rest refused.
//
// With -serve each worker then issues HTTP/3 requests back to back, as
// fairness.py does over TCP, and the verdict is the spread across connections.
// hedge does not yet send stream data to this client (the mach-quic stall
// reported alongside hedge#140), so the load lane runs it with -serve=false
// and serves over curl until that fix lands.
package main

import (
	"context"
	"crypto/tls"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"sort"
	"sync"
	"sync/atomic"
	"time"

	"github.com/quic-go/quic-go"
	"github.com/quic-go/quic-go/http3"
	"github.com/quic-go/quic-go/qlog"
	"github.com/quic-go/quic-go/qlogwriter"
)

type options struct {
	address        string
	serverName     string
	path           string
	connections    int
	target         int
	bodyBytes      int
	label          string
	connectTimeout time.Duration
	deadline       time.Duration
	idleTimeout    time.Duration
	// when set, exactly this many connections must complete their handshake
	// and the rest must be refused, which is how a configured cap is proven
	expectConnected int
	// keep a passing run's connections open until standard input closes, so
	// another client can be measured against the load it leaves behind
	hold bool
	// issue requests on every admitted connection
	serve bool
	// at most this many handshakes in flight at once, or zero for all of them
	dialing int
}

type worker struct {
	count atomic.Int64
	err   atomic.Pointer[string]
	// the CRYPTO offsets this connection's Initials carried before and after
	// the server's Retry, from the connection's own qlog events. an offset
	// sent twice in one phase is a PTO retransmit: of a first flight the
	// server never answered, or of a token Initial it held or dropped. a
	// flight split across Initials carries each offset once
	trace   sync.Mutex
	retried bool
	sent    [2]map[int64]int
}

// handshakeTrace is a qlog trace that keeps only the counts the load lane
// reads, in place of a file per connection
type handshakeTrace struct{ w *worker }

func (t handshakeTrace) AddProducer() qlogwriter.Recorder { return t }
func (t handshakeTrace) SupportsSchemas(schema string) bool {
	return schema == qlog.EventSchema
}
func (t handshakeTrace) Close() error { return nil }
func (t handshakeTrace) RecordEvent(event qlogwriter.Event) {
	t.w.trace.Lock()
	defer t.w.trace.Unlock()
	switch e := event.(type) {
	case qlog.PacketReceived:
		if e.Header.PacketType == qlog.PacketTypeRetry {
			t.w.retried = true
		}
	case qlog.PacketSent:
		if e.Header.PacketType != qlog.PacketTypeInitial {
			return
		}
		phase := 0
		if t.w.retried {
			phase = 1
		}
		if t.w.sent[phase] == nil {
			t.w.sent[phase] = map[int64]int{}
		}
		for _, frame := range e.Frames {
			if crypto, ok := frame.Frame.(*qlog.CryptoFrame); ok {
				t.w.sent[phase][crypto.Offset]++
			}
		}
	}
}

func (w *worker) sawRetry() bool {
	w.trace.Lock()
	defer w.trace.Unlock()
	return w.retried
}

// true when this phase sent some CRYPTO offset more than once
func (w *worker) retransmitted(phase int) bool {
	w.trace.Lock()
	defer w.trace.Unlock()
	for _, count := range w.sent[phase] {
		if count > 1 {
			return true
		}
	}
	return false
}

type traceKey struct{}

func traceFor(ctx context.Context, _ bool, _ qlog.ConnectionID) qlogwriter.Trace {
	w, ok := ctx.Value(traceKey{}).(*worker)
	if !ok {
		return nil
	}
	return handshakeTrace{w: w}
}

func (w *worker) fail(format string, args ...any) {
	message := fmt.Sprintf(format, args...)
	w.err.CompareAndSwap(nil, &message)
}

func dial(ctx context.Context, o *options, w *worker) (*quic.Conn, error) {
	ctx, cancel := context.WithTimeout(context.WithValue(ctx, traceKey{}, w),
		o.connectTimeout)
	defer cancel()
	address, err := net.ResolveUDPAddr("udp", o.address)
	if err != nil {
		return nil, err
	}
	socket, err := net.ListenUDP("udp", nil)
	if err != nil {
		return nil, err
	}
	// hedge's preflight drops an Initial with an empty source connection id,
	// which is what quic-go sends when it owns the socket
	transport := &quic.Transport{Conn: socket, ConnectionIDLength: 8}
	return transport.Dial(ctx, address, &tls.Config{
		ServerName:         o.serverName,
		InsecureSkipVerify: true,
		NextProtos:         []string{http3.NextProtoH3},
	}, &quic.Config{
		MaxIdleTimeout:       o.idleTimeout,
		HandshakeIdleTimeout: o.connectTimeout,
		KeepAlivePeriod:      time.Second,
		Tracer:               traceFor,
	})
}

func serve(w *worker, o *options, client *http3.ClientConn, stop <-chan struct{}) {
	url := fmt.Sprintf("https://%s%s", o.serverName, o.path)
	for {
		select {
		case <-stop:
			return
		default:
		}
		request, err := http.NewRequest(http.MethodGet, url, nil)
		if err != nil {
			w.fail("request: %v", err)
			return
		}
		request.Header.Set("Accept-Encoding", "identity")
		response, err := client.RoundTrip(request)
		if err != nil {
			w.fail("round trip: %v", err)
			return
		}
		body, err := io.ReadAll(response.Body)
		response.Body.Close()
		if err != nil {
			w.fail("body: %v", err)
			return
		}
		if response.StatusCode != http.StatusOK {
			w.fail("status %d", response.StatusCode)
			return
		}
		if o.bodyBytes != 0 && len(body) != o.bodyBytes {
			w.fail("body %d bytes, expected %d", len(body), o.bodyBytes)
			return
		}
		w.count.Add(1)
	}
}

func median(values []int64) int64 {
	sorted := append([]int64(nil), values...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i] < sorted[j] })
	return sorted[len(sorted)/2]
}

func run(o *options) int {
	workers := make([]worker, o.connections)
	conns := make([]*quic.Conn, o.connections)
	started := time.Now()

	// every handshake is in flight at once unless -dialing bounds them, which
	// is the load the pool has to grow under, and none is torn down until the
	// verdict is in
	var dialing sync.WaitGroup
	var inFlight chan struct{}
	if o.dialing > 0 {
		inFlight = make(chan struct{}, o.dialing)
	}
	for i := range workers {
		dialing.Add(1)
		go func(i int) {
			defer dialing.Done()
			if inFlight != nil {
				inFlight <- struct{}{}
				defer func() { <-inFlight }()
			}
			conn, err := dial(context.Background(), o, &workers[i])
			if err != nil {
				workers[i].fail("connect: %v", err)
				return
			}
			conns[i] = conn
		}(i)
	}
	dialing.Wait()
	defer func() {
		for _, conn := range conns {
			if conn != nil {
				conn.CloseWithError(0, "")
			}
		}
	}()

	connected := 0
	for _, conn := range conns {
		if conn != nil {
			connected++
		}
	}
	fmt.Printf("%s: connected=%d/%d in %.1fs\n", o.label, connected,
		o.connections, time.Since(started).Seconds())
	// connections that retransmitted an Initial: the first flight before the
	// Retry came, the token Initial after it
	firstFlightRetransmits, tokenRetransmits, retried := 0, 0, 0
	for i := range workers {
		if workers[i].retransmitted(0) {
			firstFlightRetransmits++
		}
		if workers[i].retransmitted(1) {
			tokenRetransmits++
		}
		if workers[i].sawRetry() {
			retried++
		}
	}
	fmt.Printf("%s: retried=%d retransmitted first_flight=%d token=%d\n",
		o.label, retried, firstFlightRetransmits, tokenRetransmits)
	if o.expectConnected >= 0 {
		if connected != o.expectConnected {
			fmt.Printf("%s: expected exactly %d connections to be admitted\n",
				o.label, o.expectConnected)
			return 1
		}
		admitted := make([]*quic.Conn, 0, connected)
		for _, conn := range conns {
			if conn != nil {
				admitted = append(admitted, conn)
			}
		}
		conns = admitted
		workers = make([]worker, len(admitted))
		o.connections = len(admitted)
	} else if connected != o.connections {
		report(o, workers)
		return 1
	}

	// every connection is still open at this point, so the server is holding
	// all of them at once
	for _, conn := range conns {
		select {
		case <-conn.Context().Done():
			fmt.Printf("%s: a connection closed while the others were opening: %v\n",
				o.label, context.Cause(conn.Context()))
			return 1
		default:
		}
	}
	if !o.serve || len(conns) == 0 {
		return hold(o, len(conns))
	}

	stop := make(chan struct{})
	var serving sync.WaitGroup
	transport := &http3.Transport{}
	for i := range workers {
		serving.Add(1)
		client := transport.NewClientConn(conns[i])
		go func(i int) {
			defer serving.Done()
			serve(&workers[i], o, client, stop)
		}(i)
	}

	counts := make([]int64, o.connections)
	reached := false
	deadline := time.Now().Add(o.deadline)
	for time.Now().Before(deadline) {
		time.Sleep(100 * time.Millisecond)
		for i := range workers {
			counts[i] = workers[i].count.Load()
		}
		if median(counts) >= int64(o.target) {
			reached = true
			break
		}
	}
	close(stop)
	for i := range workers {
		counts[i] = workers[i].count.Load()
	}
	serving.Wait()

	middle := median(counts)
	least, most := counts[0], counts[0]
	below := 0
	for _, count := range counts {
		least = min(least, count)
		most = max(most, count)
		if count*2 < middle {
			below++
		}
	}
	fmt.Printf("%s: connections=%d elapsed=%.1fs median=%d min=%d max=%d below_floor=%d\n",
		o.label, o.connections, time.Since(started).Seconds(), middle, least, most, below)
	failed := report(o, workers)
	if !reached {
		fmt.Printf("%s: the median connection never reached %d requests within %s, so there is no verdict\n",
			o.label, o.target, o.deadline)
		return 1
	}
	if failed != 0 || below != 0 {
		return 1
	}
	return hold(o, len(conns))
}

// hold reports the passing count and, when asked, keeps the connections open
// until standard input closes
func hold(o *options, count int) int {
	if o.hold {
		fmt.Printf("held %d\n", count)
		io.Copy(io.Discard, os.Stdin)
	}
	return 0
}

// report prints a sample of worker failures and returns how many workers failed
func report(o *options, workers []worker) int {
	failed := 0
	for i := range workers {
		message := workers[i].err.Load()
		if message == nil {
			continue
		}
		if failed < 5 {
			fmt.Printf("%s: connection %d: %s\n", o.label, i, *message)
		}
		failed++
	}
	if failed != 0 {
		fmt.Printf("%s: %d of %d connections failed\n", o.label, failed, o.connections)
	}
	return failed
}

func main() {
	o := options{}
	flag.StringVar(&o.address, "address", "127.0.0.1:19102", "server UDP address")
	flag.StringVar(&o.serverName, "server-name", "localhost", "TLS server name and request authority")
	flag.StringVar(&o.path, "path", "/body", "request path")
	flag.IntVar(&o.connections, "connections", 1100, "concurrent QUIC connections")
	flag.IntVar(&o.target, "target", 4, "median requests per connection that ends the run")
	flag.IntVar(&o.bodyBytes, "body-bytes", 0, "expected body length, or zero for any")
	flag.StringVar(&o.label, "label", "h3", "label for output lines")
	flag.DurationVar(&o.connectTimeout, "connect-timeout", 30*time.Second, "per-connection handshake budget")
	flag.DurationVar(&o.deadline, "deadline", 120*time.Second, "safety deadline for reaching the target")
	flag.DurationVar(&o.idleTimeout, "idle-timeout", 60*time.Second, "QUIC idle timeout")
	flag.BoolVar(&o.serve, "serve", true, "issue requests on every admitted connection")
	flag.IntVar(&o.dialing, "dialing", 0, "handshakes in flight at once, or zero for all of them")
	flag.BoolVar(&o.hold, "hold", false, "after a passing run, print `held N` and keep the connections open until stdin closes")
	flag.IntVar(&o.expectConnected, "expect-connected", -1, "exact number of connections the server must admit, the rest refused")
	flag.Parse()
	if o.connections <= 0 || o.target <= 0 {
		fmt.Fprintln(os.Stderr, "connections and target must be positive")
		os.Exit(2)
	}
	os.Exit(run(&o))
}
