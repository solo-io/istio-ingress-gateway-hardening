// h2dial-light: minimal HTTP/2 (h2c) client for the Istio IGW hardening
// playground. Maintains a single shared http2.Transport (one TCP connection
// for the same host:port) and sends requests at a steady rate for a
// configured duration. Used to demonstrate that an existing long-lived
// HTTP/2 connection sees new routes per-request after an xDS push.
//
// Flags:
//   -url      Target URL (must be http:// — uses h2c upgrade or prior knowledge)
//   -host     Host header to send (defaults to URL host)
//   -d        Duration of test (e.g., 30s)
//   -rate     Requests per second (default 5)
//   -idle     Sleep forever (used for `kubectl exec` entry pattern)
//
// Output: one summary line per second of the form "t=Ns sent=N ok=N fail=N"
// followed by a final line "FINAL sent=N ok=N fail=N elapsed=Ns".

package main

import (
	"context"
	"crypto/tls"
	"flag"
	"fmt"
	"net"
	"net/http"
	"os"
	"sync/atomic"
	"time"

	"golang.org/x/net/http2"
)

func main() {
	idle := flag.Bool("idle", false, "Sleep forever (for keep-alive Deployment)")
	url := flag.String("url", "", "Target h2c URL (http://...)")
	host := flag.String("host", "", "Host header (defaults to URL host)")
	duration := flag.Duration("d", 30*time.Second, "Test duration")
	rate := flag.Int("rate", 5, "Requests per second")
	flag.Parse()

	if *idle {
		// Sleep loop (plain `select {}` triggers deadlock detection)
		for {
			time.Sleep(time.Hour)
		}
	}

	if *url == "" {
		fmt.Fprintln(os.Stderr, "ERROR: -url is required")
		os.Exit(2)
	}

	// h2c transport: HTTP/2 over cleartext TCP. One shared transport = one TCP
	// connection per host:port. This is the canonical Go pattern for a long-lived
	// HTTP/2 client.
	transport := &http2.Transport{
		AllowHTTP: true,
		DialTLSContext: func(_ context.Context, network, addr string, _ *tls.Config) (net.Conn, error) {
			return net.Dial(network, addr)
		},
	}
	client := &http.Client{Transport: transport, Timeout: 10 * time.Second}

	var sent, ok, fail int64
	deadline := time.Now().Add(*duration)
	interval := time.Second / time.Duration(*rate)
	startTs := time.Now()
	nextSummary := startTs.Add(time.Second)

	for time.Now().Before(deadline) {
		req, _ := http.NewRequest("GET", *url, nil)
		if *host != "" {
			req.Host = *host
		}
		atomic.AddInt64(&sent, 1)
		resp, err := client.Do(req)
		if err != nil {
			atomic.AddInt64(&fail, 1)
		} else {
			if resp.StatusCode == 200 {
				atomic.AddInt64(&ok, 1)
			} else {
				atomic.AddInt64(&fail, 1)
			}
			resp.Body.Close()
		}
		// Per-second progress line so external observers can correlate with
		// mid-flight events (e.g., a VS-v2 apply at t=15s).
		if now := time.Now(); now.After(nextSummary) {
			elapsed := int(now.Sub(startTs).Seconds())
			fmt.Printf("t=%ds sent=%d ok=%d fail=%d\n",
				elapsed, atomic.LoadInt64(&sent), atomic.LoadInt64(&ok), atomic.LoadInt64(&fail))
			nextSummary = now.Add(time.Second)
		}
		time.Sleep(interval)
	}

	fmt.Printf("FINAL sent=%d ok=%d fail=%d elapsed=%.1fs\n",
		atomic.LoadInt64(&sent), atomic.LoadInt64(&ok), atomic.LoadInt64(&fail),
		time.Since(startTs).Seconds())
}
