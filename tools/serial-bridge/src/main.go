//go:build windows
// +build windows

package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/Microsoft/go-winio"
	"github.com/gorilla/websocket"
)

var (
	flagPipe     = flag.String("pipe", "", `Named pipe path (e.g. \\.\pipe\openhvx-<guid>-com1)`)
	flagWS       = flag.String("ws", "", "WebSocket URL to broker (e.g. ws://broker:8081/ws/tunnel/<id>?ticket=...)")
	flagTTL      = flag.Int("ttl", 0, "Auto-close after N seconds (optional)")
	flagWakeCR   = flag.Int("wake-cr", 2, "Send N carriage returns to the pipe after connect")
	flagConnTO   = flag.Duration("connect-timeout", 15*time.Second, "Connect timeout for pipe and WS")
	flagVerbose  = flag.Bool("v", true, "Verbose logs to stderr")
	flagFromJSON = flag.Bool("json", false, "Read minimal JSON from STDIN: {\"pipe\":\"..\",\"ws\":\"..\",\"ttl\":900,\"wakeCr\":2}")
)

type stdinPayload struct {
	Pipe   string `json:"pipe"`
	WS     string `json:"ws"`
	TTL    int    `json:"ttl"`
	WakeCr int    `json:"wakeCr"`
}

func logf(format string, a ...any) {
	if *flagVerbose {
		ts := time.Now().Format("15:04:05.000")
		fmt.Fprintf(os.Stderr, "[serial-bridge %s] %s\n", ts, fmt.Sprintf(format, a...))
	}
}

func fatalf(code int, format string, a ...any) {
	logf("FATAL: "+format, a...)
	os.Exit(code)
}

func readJSONFromStdin() (*stdinPayload, error) {
	b, err := io.ReadAll(os.Stdin)
	if err != nil {
		return nil, err
	}
	b = []byte(strings.TrimSpace(string(b)))
	if len(b) == 0 {
		return nil, fmt.Errorf("empty STDIN")
	}
	var p stdinPayload
	if err := json.Unmarshal(b, &p); err != nil {
		return nil, err
	}
	return &p, nil
}

func main() {
	flag.Parse()

	// JSON (optionnel) -> flags
	if *flagFromJSON {
		p, err := readJSONFromStdin()
		if err != nil {
			fatalf(2, "invalid STDIN JSON: %v", err)
		}
		if p.Pipe != "" {
			*flagPipe = p.Pipe
		}
		if p.WS != "" {
			*flagWS = p.WS
		}
		if p.TTL > 0 {
			*flagTTL = p.TTL
		}
		if p.WakeCr >= 0 {
			*flagWakeCR = p.WakeCr
		}
	}

	if *flagPipe == "" || *flagWS == "" {
		fmt.Fprintln(os.Stderr, "Usage:")
		fmt.Fprintln(os.Stderr, `  openhvx-serial-bridge.exe -pipe \\.\pipe\openhvx-<guid>-com1 -ws ws://.../ws/tunnel/<id>?ticket=... [-ttl 900] [-wake-cr 2]`)
		fmt.Fprintln(os.Stderr, `  # or JSON via stdin: {"pipe":"\\.\pipe\name","ws":"ws://...","ttl":900,"wakeCr":2} with -json`)
		os.Exit(2)
	}

	logf("pipe=%s", *flagPipe)
	logf("ws=%s", *flagWS)
	if *flagTTL > 0 {
		logf("ttl=%ds", *flagTTL)
	}
	logf("wakeCR=%d", *flagWakeCR)

	// Contexte global + TTL + signaux
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	if *flagTTL > 0 {
		ctx, cancel = context.WithTimeout(ctx, time.Duration(*flagTTL)*time.Second)
		defer cancel()
	}
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	go func() {
		select {
		case <-sig:
			logf("signal received, shutting down")
			cancel()
		case <-ctx.Done():
		}
	}()

	// Connexion pipe (go-winio DialPipe with timeout pointer)
	start := time.Now()
	to := *flagConnTO
	pipeConn, err := winio.DialPipe(*flagPipe, &to)
	if err != nil {
		fatalf(3, "pipe dial failed: %v", err)
	}
	logf("pipe connected in %s", time.Since(start).Round(time.Millisecond))

	// Réveil getty (quelques CR) — NE PAS laisser un WriteDeadline actif
	if *flagWakeCR > 0 {
		for i := 0; i < *flagWakeCR; i++ {
			if _, werr := pipeConn.Write([]byte{13}); werr != nil {
				fatalf(3, "pipe wake write failed: %v", werr)
			}
			time.Sleep(120 * time.Millisecond)
		}
	}
	// 🔑 Très important: s'assurer qu'aucune deadline n'est restée posée
	_ = pipeConn.SetWriteDeadline(time.Time{})

	// Connexion WebSocket
	dialer := websocket.Dialer{
		Proxy:             http.ProxyFromEnvironment,
		HandshakeTimeout:  *flagConnTO,
		EnableCompression: false,
		ReadBufferSize:    4096,
		WriteBufferSize:   4096,
	}
	ws, _, err := dialer.Dial(*flagWS, nil)
	if err != nil {
		_ = pipeConn.Close()
		fatalf(4, "ws dial failed: %v", err)
	}
	logf("ws connected")

	// Keep-alive WS (ping)
	ws.SetPongHandler(func(string) error { return nil })
	pingStop := make(chan struct{})
	go func() {
		t := time.NewTicker(20 * time.Second)
		defer t.Stop()
		for {
			select {
			case <-pingStop:
				return
			case <-t.C:
				_ = ws.WriteControl(websocket.PingMessage, nil, time.Now().Add(5*time.Second))
			}
		}
	}()

	errCh := make(chan error, 2)

	// WS -> PIPE
	go func() {
		first := true
		for {
			mt, r, err := ws.NextReader()
			if err != nil {
				errCh <- fmt.Errorf("ws recv: %w", err)
				return
			}
			if mt != websocket.BinaryMessage && mt != websocket.TextMessage {
				continue
			}
			n, err := io.Copy(pipeConn, r)
			if first && n > 0 {
				logf("ws->pipe first frame %d bytes", n)
				first = false
			}
			if err != nil {
				errCh <- fmt.Errorf("pipe write: %w", err)
				return
			}
		}
	}()

	// PIPE -> WS
	go func() {
		buf := make([]byte, 4096)
		first := true
		for {
			n, rerr := pipeConn.Read(buf)
			if n > 0 {
				if first {
					logf("pipe->ws first frame %d bytes", n)
					first = false
				}
				if werr := ws.WriteMessage(websocket.BinaryMessage, buf[:n]); werr != nil {
					errCh <- fmt.Errorf("ws write: %w", werr)
					return
				}
			}
			if rerr != nil {
				if rerr == io.EOF {
					errCh <- io.EOF
				} else {
					errCh <- fmt.Errorf("pipe read: %w", rerr)
				}
				return
			}
		}
	}()

	// Attente fin (ctx / erreurs)
	var ferr error
	select {
	case <-ctx.Done():
		ferr = ctx.Err()
	case ferr = <-errCh:
	}

	// Cleanup
	close(pingStop)
	_ = ws.WriteControl(websocket.CloseMessage, websocket.FormatCloseMessage(websocket.CloseNormalClosure, "bye"), time.Now().Add(500*time.Millisecond))
	_ = ws.Close()
	_ = pipeConn.Close()

	if ferr != nil && ferr != context.Canceled && ferr != context.DeadlineExceeded && ferr != io.EOF {
		fatalf(5, "bridge ended with error: %v", ferr)
	}
	logf("bridge closed: %v", ferr)
}
