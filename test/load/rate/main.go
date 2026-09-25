// Closed-loop request and handshake rates against the real server.
//
// A fixed number of workers each keeps one operation in flight for a fixed
// duration after a warm-up, and the rate is what completed inside the window.
// In request mode each connection is opened once and carries requests back to
// back over HTTP/1.1, HTTP/1.1 over TLS, HTTP/2 over TLS or HTTP/3. In
// handshake mode every operation is a fresh TLS or QUIC connection that
// completes its handshake and is closed, with no session resumption, so the
// rate is full handshakes.
//
// In churn mode the load is open-loop instead: operations start at a fixed
// -rate, each a fresh connection that carries one request and closes, and a
// start that finds every worker busy is counted as missed rather than queued.
// It prints a sample of the running totals, with the server's CPU time and
// resident set, every -sample, which is what the churn cell reads for flat
// memory and CPU over a long run.
//
// Otherwise the load is closed-loop: a worker offers its next operation only
// when the last one finished, so the rate is what the server sustained, never
// what was offered. Given the server's pid it reads the server's own CPU time over the
// same window.
package main

import (
	"context"
	"crypto/tls"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/quic-go/quic-go"
	"github.com/quic-go/quic-go/http3"
)

type options struct {
	address     string
	serverName  string
	path        string
	protocol    string
	mode        string
	connections int
	streams     int
	duration    time.Duration
	warmup      time.Duration
	timeout     time.Duration
	bodyBytes   int
	label       string
	serverPid   int
	clockTicks  int
	// churn: operations started per second, and how often to print a sample
	rate   float64
	sample time.Duration
}

type tally struct {
	ok        atomic.Int64
	failed    atomic.Int64
	firstErr  atomic.Pointer[string]
	latencyMu sync.Mutex
	latencies []time.Duration
}

func (t *tally) fail(err error) {
	t.failed.Add(1)
	message := err.Error()
	t.firstErr.CompareAndSwap(nil, &message)
}

func (t *tally) record(d time.Duration) {
	t.ok.Add(1)
	t.latencyMu.Lock()
	t.latencies = append(t.latencies, d)
	t.latencyMu.Unlock()
}

// every connection offers X25519 alone and keeps no session cache, so a TLS
// or QUIC handshake is always a full one with one key exchange
func tlsConfig(o *options, protocols []string) *tls.Config {
	return &tls.Config{
		ServerName:         o.serverName,
		InsecureSkipVerify: true,
		NextProtos:         protocols,
		CurvePreferences:   []tls.CurveID{tls.X25519},
		MinVersion:         tls.VersionTLS13,
	}
}

// hedge's preflight drops an Initial with an empty source connection id,
// which is what quic-go sends when it owns the socket, so every QUIC
// connection gets its own socket and an eight-byte connection id
func dialQUIC(ctx context.Context, o *options, protocols []string) (*quic.Conn, *net.UDPConn, error) {
	address, err := net.ResolveUDPAddr("udp", o.address)
	if err != nil {
		return nil, nil, err
	}
	socket, err := net.ListenUDP("udp", nil)
	if err != nil {
		return nil, nil, err
	}
	transport := &quic.Transport{Conn: socket, ConnectionIDLength: 8}
	conn, err := transport.Dial(ctx, address, tlsConfig(o, protocols), &quic.Config{
		HandshakeIdleTimeout: o.timeout,
		MaxIdleTimeout:       30 * time.Second,
	})
	if err != nil {
		socket.Close()
		return nil, nil, err
	}
	return conn, socket, nil
}

// one round tripper per connection, so the connection count is exact rather
// than what a shared pool decides to open
func roundTripper(o *options) (http.RoundTripper, func(), error) {
	switch o.protocol {
	case "h1", "tls", "h2":
		transport := &http.Transport{
			DisableCompression:  true,
			MaxConnsPerHost:     1,
			MaxIdleConnsPerHost: 1,
			IdleConnTimeout:     0,
			TLSHandshakeTimeout: o.timeout,
		}
		switch o.protocol {
		case "tls":
			transport.TLSClientConfig = tlsConfig(o, []string{"http/1.1"})
			transport.TLSNextProto = map[string]func(string, *tls.Conn) http.RoundTripper{}
		case "h2":
			transport.TLSClientConfig = tlsConfig(o, []string{"h2"})
			transport.ForceAttemptHTTP2 = true
			protocols := new(http.Protocols)
			protocols.SetHTTP2(true)
			transport.Protocols = protocols
		}
		return transport, transport.CloseIdleConnections, nil
	case "h3":
		var socket *net.UDPConn
		transport := &http3.Transport{
			TLSClientConfig: tlsConfig(o, []string{http3.NextProtoH3}),
			Dial: func(ctx context.Context, _ string, _ *tls.Config, _ *quic.Config) (*quic.Conn, error) {
				conn, s, err := dialQUIC(ctx, o, []string{http3.NextProtoH3})
				socket = s
				return conn, err
			},
		}
		return transport, func() {
			transport.Close()
			if socket != nil {
				socket.Close()
			}
		}, nil
	}
	return nil, nil, fmt.Errorf("unknown protocol %q", o.protocol)
}

func scheme(o *options) string {
	if o.protocol == "h1" {
		return "http"
	}
	return "https"
}

func request(ctx context.Context, o *options, rt http.RoundTripper) error {
	url := fmt.Sprintf("%s://%s%s", scheme(o), o.address, o.path)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	req.Host = o.serverName
	req.Header.Set("Accept-Encoding", "identity")
	response, err := rt.RoundTrip(req)
	if err != nil {
		return err
	}
	n, err := io.Copy(io.Discard, response.Body)
	response.Body.Close()
	if err != nil {
		return err
	}
	if response.StatusCode != http.StatusOK {
		return fmt.Errorf("status %d", response.StatusCode)
	}
	if o.bodyBytes != 0 && n != int64(o.bodyBytes) {
		return fmt.Errorf("body %d bytes, expected %d", n, o.bodyBytes)
	}
	want := map[string]int{"h1": 1, "tls": 1, "h2": 2, "h3": 3}[o.protocol]
	if response.ProtoMajor != want {
		return fmt.Errorf("served over HTTP/%d, expected HTTP/%d", response.ProtoMajor, want)
	}
	return nil
}

// a full handshake on a fresh connection, then a close the server sees
func handshake(ctx context.Context, o *options) error {
	switch o.protocol {
	case "tls":
		dialer := &tls.Dialer{
			NetDialer: &net.Dialer{Timeout: o.timeout},
			Config:    tlsConfig(o, []string{"http/1.1"}),
		}
		conn, err := dialer.DialContext(ctx, "tcp", o.address)
		if err != nil {
			return err
		}
		return conn.Close()
	case "h3":
		conn, socket, err := dialQUIC(ctx, o, []string{http3.NextProtoH3})
		if err != nil {
			return err
		}
		err = conn.CloseWithError(0, "")
		socket.Close()
		return err
	}
	return fmt.Errorf("handshake mode takes tls or h3, not %q", o.protocol)
}

// user plus system CPU seconds of a process and all its threads, or a
// negative value when there is no process to read
func cpuSeconds(o *options) float64 {
	if o.serverPid == 0 {
		return -1
	}
	stat, err := os.ReadFile(fmt.Sprintf("/proc/%d/stat", o.serverPid))
	if err != nil {
		return -1
	}
	// the command name is parenthesised and may hold spaces, so fields are
	// counted from after its closing parenthesis, where state is field 3
	rest := string(stat[strings.LastIndexByte(string(stat), ')')+2:])
	fields := strings.Fields(rest)
	utime, err1 := strconv.ParseInt(fields[14-3], 10, 64)
	stime, err2 := strconv.ParseInt(fields[15-3], 10, 64)
	if err1 != nil || err2 != nil {
		return -1
	}
	return float64(utime+stime) / float64(o.clockTicks)
}

// the resident set of the server in bytes, or -1
func residentBytes(o *options) int64 {
	if o.serverPid == 0 {
		return -1
	}
	rollup, err := os.ReadFile(fmt.Sprintf("/proc/%d/smaps_rollup", o.serverPid))
	if err != nil {
		return -1
	}
	for _, line := range strings.Split(string(rollup), "\n") {
		fields := strings.Fields(line)
		if len(fields) >= 2 && fields[0] == "Rss:" {
			kib, err := strconv.ParseInt(fields[1], 10, 64)
			if err != nil {
				return -1
			}
			return kib * 1024
		}
	}
	return -1
}

// one fresh connection carrying one request, closed after its response
func churnOnce(ctx context.Context, o *options) error {
	rt, closer, err := roundTripper(o)
	if err != nil {
		return err
	}
	defer closer()
	if transport, ok := rt.(*http.Transport); ok {
		transport.DisableKeepAlives = true
	}
	return request(ctx, o, rt)
}

func churn(o *options) int {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	total := &tally{}
	var missed atomic.Int64
	// connections open at once, and the most since the last sample: a server
	// that keeps up holds about rate times latency, one that falls behind a
	// backlog that grows
	var inFlight, peak atomic.Int64
	jobs := make(chan struct{})
	var workers sync.WaitGroup
	for i := 0; i < o.connections; i++ {
		workers.Add(1)
		go func() {
			defer workers.Done()
			for range jobs {
				started := time.Now()
				now := inFlight.Add(1)
				for seen := peak.Load(); now > seen && !peak.CompareAndSwap(seen, now); seen = peak.Load() {
				}
				err := churnOnce(ctx, o)
				inFlight.Add(-1)
				if err != nil {
					total.fail(err)
					continue
				}
				total.record(time.Since(started))
			}
		}()
	}

	started := time.Now()
	pace := time.NewTicker(time.Duration(float64(time.Second) / o.rate))
	defer pace.Stop()
	var samples <-chan time.Time
	if o.sample > 0 {
		ticker := time.NewTicker(o.sample)
		defer ticker.Stop()
		samples = ticker.C
	}
	end := time.After(o.duration)
	offered := int64(0)
	printSample := func() {
		current := inFlight.Load()
		fmt.Printf("%s: sample t=%.1f offered=%d ok=%d failed=%d missed=%d in_flight=%d in_flight_peak=%d server_cpu=%.2f rss=%d\n",
			o.label, time.Since(started).Seconds(), offered, total.ok.Load(),
			total.failed.Load(), missed.Load(), current, peak.Swap(current),
			cpuSeconds(o), residentBytes(o))
	}
	printSample()
loop:
	for {
		select {
		case <-pace.C:
			offered++
			select {
			case jobs <- struct{}{}:
			default:
				missed.Add(1)
			}
		case <-samples:
			printSample()
		case <-end:
			break loop
		}
	}
	close(jobs)
	workers.Wait()
	elapsed := time.Since(started)
	printSample()

	sort.Slice(total.latencies, func(i, j int) bool { return total.latencies[i] < total.latencies[j] })
	ok := total.ok.Load()
	fmt.Printf("%s: protocol=%s mode=churn offered=%d ok=%d failed=%d missed=%d elapsed=%.2fs rate=%.1f p50=%.2fms p99=%.2fms\n",
		o.label, o.protocol, offered, ok, total.failed.Load(), missed.Load(),
		elapsed.Seconds(), float64(ok)/elapsed.Seconds(),
		float64(percentile(total.latencies, 0.50))/1e6,
		float64(percentile(total.latencies, 0.99))/1e6)
	if message := total.firstErr.Load(); message != nil {
		fmt.Printf("%s: first error: %s\n", o.label, *message)
	}
	if ok == 0 || total.failed.Load() != 0 || missed.Load() != 0 {
		return 1
	}
	return 0
}

func percentile(sorted []time.Duration, p float64) time.Duration {
	if len(sorted) == 0 {
		return 0
	}
	return sorted[int(float64(len(sorted)-1)*p)]
}

func run(o *options) int {
	// the window opens after the warm-up and closes after the duration; only
	// operations that finish inside it count
	var counting atomic.Bool
	window := &tally{}
	warm := &tally{}
	current := func() *tally {
		if counting.Load() {
			return window
		}
		return warm
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var workers sync.WaitGroup

	workersPer := 1
	if o.mode == "requests" && (o.protocol == "h2" || o.protocol == "h3") {
		workersPer = o.streams
	}
	var closers []func()
	var closersMu sync.Mutex
	for c := 0; c < o.connections; c++ {
		var rt http.RoundTripper
		if o.mode == "requests" {
			var closer func()
			var err error
			rt, closer, err = roundTripper(o)
			if err != nil {
				fmt.Fprintln(os.Stderr, err)
				return 2
			}
			closersMu.Lock()
			closers = append(closers, closer)
			closersMu.Unlock()
		}
		for s := 0; s < workersPer; s++ {
			workers.Add(1)
			go func() {
				defer workers.Done()
				for ctx.Err() == nil {
					started := time.Now()
					var err error
					if o.mode == "requests" {
						err = request(ctx, o, rt)
					} else {
						err = handshake(ctx, o)
					}
					t := current()
					if err != nil {
						if ctx.Err() != nil {
							return
						}
						t.fail(err)
						continue
					}
					t.record(time.Since(started))
				}
			}()
		}
	}

	time.Sleep(o.warmup)
	counting.Store(true)
	cpuBefore := cpuSeconds(o)
	opened := time.Now()
	time.Sleep(o.duration)
	counting.Store(false)
	elapsed := time.Since(opened)
	cpuAfter := cpuSeconds(o)
	cancel()
	workers.Wait()
	for _, closer := range closers {
		closer()
	}

	sort.Slice(window.latencies, func(i, j int) bool { return window.latencies[i] < window.latencies[j] })
	ok := window.ok.Load()
	fmt.Printf("%s: protocol=%s mode=%s connections=%d streams=%d ok=%d failed=%d warmup_failed=%d elapsed=%.2fs rate=%.1f p50=%.2fms p99=%.2fms\n",
		o.label, o.protocol, o.mode, o.connections, workersPer, ok, window.failed.Load(),
		warm.failed.Load(), elapsed.Seconds(), float64(ok)/elapsed.Seconds(),
		float64(percentile(window.latencies, 0.50))/1e6,
		float64(percentile(window.latencies, 0.99))/1e6)
	// the server's CPU over the same window: per operation, and in cores
	if cpuBefore >= 0 && cpuAfter >= 0 && ok > 0 {
		cpu := cpuAfter - cpuBefore
		fmt.Printf("%s: server_cpu=%.2fs per_op=%.1fus cores=%.2f\n", o.label, cpu,
			cpu*1e6/float64(ok), cpu/elapsed.Seconds())
	}
	for _, t := range []*tally{warm, window} {
		if message := t.firstErr.Load(); message != nil {
			fmt.Printf("%s: first error: %s\n", o.label, *message)
			break
		}
	}
	if ok == 0 || window.failed.Load() != 0 || warm.failed.Load() != 0 {
		return 1
	}
	return 0
}

func main() {
	o := options{}
	flag.StringVar(&o.address, "address", "127.0.0.1:19140", "server address")
	flag.StringVar(&o.serverName, "server-name", "localhost", "TLS server name and request authority")
	flag.StringVar(&o.path, "path", "/small", "request path")
	flag.StringVar(&o.protocol, "protocol", "h1", "h1, tls, h2 or h3")
	flag.StringVar(&o.mode, "mode", "requests", "requests on held connections, handshakes on fresh ones (tls or h3), or churn: a connection per request at -rate")
	flag.IntVar(&o.connections, "connections", 64, "connections, or handshakes or churn operations in flight")
	flag.IntVar(&o.streams, "streams", 1, "requests in flight per HTTP/2 or HTTP/3 connection")
	flag.DurationVar(&o.duration, "duration", 10*time.Second, "measured window")
	flag.DurationVar(&o.warmup, "warmup", 2*time.Second, "load before the window opens")
	flag.DurationVar(&o.timeout, "timeout", 10*time.Second, "per-connection connect and handshake budget")
	flag.IntVar(&o.bodyBytes, "body-bytes", 0, "expected body length, or zero for any")
	flag.StringVar(&o.label, "label", "rate", "label for output lines")
	flag.Float64Var(&o.rate, "rate", 100, "churn: connections started per second")
	flag.DurationVar(&o.sample, "sample", 0, "churn: print running totals this often, or zero for none")
	flag.IntVar(&o.serverPid, "server-pid", 0, "report this process's CPU time over the window")
	flag.IntVar(&o.clockTicks, "clock-ticks", 100, "the kernel's clock ticks per second (getconf CLK_TCK)")
	flag.Parse()
	if o.connections <= 0 || o.streams <= 0 || o.duration <= 0 {
		fmt.Fprintln(os.Stderr, "connections, streams and duration must be positive")
		os.Exit(2)
	}
	switch o.mode {
	case "requests", "handshakes":
		os.Exit(run(&o))
	case "churn":
		if o.rate <= 0 {
			fmt.Fprintln(os.Stderr, "churn needs a positive -rate")
			os.Exit(2)
		}
		os.Exit(churn(&o))
	}
	fmt.Fprintln(os.Stderr, errors.New("mode is requests, handshakes or churn"))
	os.Exit(2)
}
