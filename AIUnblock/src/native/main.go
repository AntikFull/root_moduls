package main

import (
	"bufio"
	"bytes"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"encoding/binary"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

var version = "dev"

const (
	maxHelloBytes = 64 * 1024
	maxRoutes     = 512
)

type routeTable map[string]string // exact SNI -> gateway group

func main() {
	log.SetFlags(log.Ldate | log.Ltime | log.Lmicroseconds)
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	switch os.Args[1] {
	case "router":
		os.Exit(runRouter(os.Args[2:]))
	case "tls-probe":
		os.Exit(runTLSProbe(os.Args[2:]))
	case "probe":
		os.Exit(runProbe(os.Args[2:]))
	case "trace":
		os.Exit(runTrace(os.Args[2:]))
	case "dns":
		os.Exit(runDNS(os.Args[2:]))
	case "doh":
		os.Exit(runDoH(os.Args[2:]))
	case "resolve":
		os.Exit(runResolve(os.Args[2:]))
	case "self-test":
		os.Exit(runSelfTest())
	case "version", "--version", "-version":
		fmt.Printf("AIUnblock native %s (%s/%s)\n", version, runtime.GOOS, runtime.GOARCH)
	case "help", "--help", "-h":
		usage()
	default:
		fmt.Fprintf(os.Stderr, "unknown command %q\n", os.Args[1])
		usage()
		os.Exit(2)
	}
}

func usage() {
	fmt.Fprintf(os.Stderr, `AIUnblock native %s (%s/%s)
Usage:
  aiunblock-native router -listen 127.0.0.1:15359 -routes FILE -gateway-dir DIR
  aiunblock-native tls-probe -ip IPv4 -domain HOST [-timeout 4]
  aiunblock-native probe -candidates "IP IP" -domains "HOST HOST" [-timeout 4] [-max 8]
  aiunblock-native dns -server IPv4 -domain HOST [-timeout 3]
  aiunblock-native doh -resolver https://HOST/path -domain HOST -bootstrap "IP IP" [-timeout 6]
  aiunblock-native resolve -domain HOST -resolvers "URL URL" -dns "IP IP" -bootstrap "IP IP" [-timeout 6]
  aiunblock-native self-test
  aiunblock-native version
`, version, runtime.GOOS, runtime.GOARCH)
}

func runRouter(args []string) int {
	fs := flag.NewFlagSet("router", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	listenAddr := fs.String("listen", "127.0.0.1:15359", "loopback listener")
	routesPath := fs.String("routes", "", "exact SNI route file")
	gatewayDir := fs.String("gateway-dir", "", "directory with GROUP.current files")
	helloTimeout := fs.Duration("hello-timeout", 6*time.Second, "ClientHello timeout")
	dialTimeout := fs.Duration("dial-timeout", 6*time.Second, "upstream dial timeout")
	maxConn := fs.Int("max-connections", 256, "maximum concurrent proxied connections")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if *routesPath == "" || *gatewayDir == "" {
		fmt.Fprintln(os.Stderr, "router: -routes and -gateway-dir are required")
		return 2
	}
	host, _, err := net.SplitHostPort(*listenAddr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "router: invalid listen: %v\n", err)
		return 2
	}
	ip := net.ParseIP(host)
	if ip == nil || !ip.IsLoopback() {
		fmt.Fprintln(os.Stderr, "router: refusing non-loopback listener")
		return 2
	}
	// The router is an idle-most-of-the-time relay. Capping the scheduler keeps the
	// thread count and RSS low on many-core SoCs; throughput here is bound by the
	// network, not by CPU.
	if runtime.NumCPU() > 2 {
		runtime.GOMAXPROCS(2)
	}
	routes, err := loadRoutes(*routesPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "router: routes: %v\n", err)
		return 1
	}
	ln, err := net.Listen("tcp4", *listenAddr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "router: listen: %v\n", err)
		return 1
	}
	defer ln.Close()
	log.Printf("router ready on %s with %d exact domains; native=%s %s/%s", *listenAddr, len(routes), version, runtime.GOOS, runtime.GOARCH)
	if *maxConn < 8 {
		*maxConn = 8
	}
	sem := make(chan struct{}, *maxConn)
	for {
		c, err := ln.Accept()
		if err != nil {
			if ne, ok := err.(net.Error); ok && ne.Temporary() {
				time.Sleep(100 * time.Millisecond)
				continue
			}
			log.Printf("accept: %v", err)
			return 1
		}
		select {
		case sem <- struct{}{}:
			go func(conn net.Conn) {
				defer func() { <-sem }()
				handleConn(conn, routes, *gatewayDir, *helloTimeout, *dialTimeout)
			}(c)
		default:
			log.Printf("connection limit reached; rejecting %s", c.RemoteAddr())
			c.Close()
		}
	}
}

func loadRoutes(path string) (routeTable, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	out := make(routeTable)
	s := bufio.NewScanner(f)
	// Route lines are tiny, but allow future expansion without Scanner surprises.
	s.Buffer(make([]byte, 4096), 64*1024)
	line := 0
	for s.Scan() {
		line++
		t := strings.TrimSpace(s.Text())
		if t == "" || strings.HasPrefix(t, "#") {
			continue
		}
		fields := strings.Fields(t)
		if len(fields) != 2 {
			return nil, fmt.Errorf("line %d: expected GROUP DOMAIN", line)
		}
		group := strings.ToLower(fields[0])
		domain := strings.ToLower(strings.TrimSuffix(fields[1], "."))
		if !validToken(group) || !validHostname(domain) {
			return nil, fmt.Errorf("line %d: invalid group/domain", line)
		}
		if _, exists := out[domain]; exists {
			return nil, fmt.Errorf("line %d: duplicate domain %s", line, domain)
		}
		out[domain] = group
		if len(out) > maxRoutes {
			return nil, fmt.Errorf("too many routes (max %d)", maxRoutes)
		}
	}
	if err := s.Err(); err != nil {
		return nil, err
	}
	if len(out) == 0 {
		return nil, errors.New("no routes")
	}
	return out, nil
}

func validToken(s string) bool {
	if s == "" || len(s) > 64 {
		return false
	}
	for _, r := range s {
		if !(r == '-' || r == '_' || r >= 'a' && r <= 'z' || r >= '0' && r <= '9') {
			return false
		}
	}
	return true
}

func validHostname(s string) bool {
	if s == "" || len(s) > 253 || strings.Contains(s, "*") {
		return false
	}
	for _, p := range strings.Split(s, ".") {
		if p == "" || len(p) > 63 || p[0] == '-' || p[len(p)-1] == '-' {
			return false
		}
		for _, r := range p {
			if !(r == '-' || r >= 'a' && r <= 'z' || r >= '0' && r <= '9') {
				return false
			}
		}
	}
	return true
}

func handleConn(conn net.Conn, routes routeTable, gatewayDir string, helloTimeout, dialTimeout time.Duration) {
	defer conn.Close()
	tc, ok := conn.(*net.TCPConn)
	if !ok {
		return
	}
	_ = tc.SetKeepAlive(true)
	original, origErr := originalDst(tc)
	_ = conn.SetReadDeadline(time.Now().Add(helloTimeout))
	hello, sni, err := sniffClientHello(conn)
	if err != nil {
		log.Printf("client %s: ClientHello: %v", conn.RemoteAddr(), err)
		return
	}
	_ = conn.SetReadDeadline(time.Time{})

	target := ""
	routeGroup := ""
	if sni != "" {
		routeGroup = routes[strings.ToLower(strings.TrimSuffix(sni, "."))]
	}
	if routeGroup != "" {
		gateway, err := readGateway(gatewayDir, routeGroup)
		if err != nil {
			// Matched SNI must never silently bypass the configured smart route.
			log.Printf("matched SNI %q in group %q is fail-closed: %v", sni, routeGroup, err)
			return
		}
		target = net.JoinHostPort(gateway, "443")
	} else {
		if origErr != nil {
			log.Printf("unmatched SNI %q: original destination unavailable: %v", sni, origErr)
			return
		}
		target = original.String()
	}

	upstream, err := net.DialTimeout("tcp4", target, dialTimeout)
	if err != nil {
		log.Printf("SNI=%q group=%q target=%s dial: %v", sni, routeGroup, target, err)
		return
	}
	defer upstream.Close()
	if _, err = upstream.Write(hello); err != nil {
		return
	}
	if u, ok := upstream.(*net.TCPConn); ok {
		_ = u.SetKeepAlive(true)
	}

	done := make(chan struct{}, 2)
	go func() {
		_, _ = io.Copy(upstream, conn)
		if u, ok := upstream.(*net.TCPConn); ok {
			_ = u.CloseWrite()
		}
		done <- struct{}{}
	}()
	go func() { _, _ = io.Copy(conn, upstream); _ = tc.CloseWrite(); done <- struct{}{} }()
	<-done
	<-done
}

func readGateway(dir, group string) (string, error) {
	if !validToken(group) {
		return "", errors.New("invalid group")
	}
	b, err := os.ReadFile(filepath.Join(dir, group+".current"))
	if err != nil {
		return "", err
	}
	s := strings.TrimSpace(string(b))
	ip := net.ParseIP(s)
	if ip == nil || ip.To4() == nil {
		return "", errors.New("gateway is not IPv4")
	}
	return ip.To4().String(), nil
}

func decodeOriginalDst(raw []byte) (*net.TCPAddr, error) {
	if len(raw) < 16 {
		return nil, errors.New("short SO_ORIGINAL_DST")
	}
	// Android-supported ABIs are little-endian; sockaddr_in stores sin_family
	// in native byte order and sin_port in network byte order.
	family := binary.LittleEndian.Uint16(raw[0:2])
	if family != syscall.AF_INET {
		return nil, fmt.Errorf("unexpected address family %d", family)
	}
	port := int(binary.BigEndian.Uint16(raw[2:4]))
	ip := net.IPv4(raw[4], raw[5], raw[6], raw[7])
	if port <= 0 || ip.IsUnspecified() {
		return nil, errors.New("invalid original destination")
	}
	return &net.TCPAddr{IP: ip, Port: port}, nil
}

func sniffClientHello(r io.Reader) ([]byte, string, error) {
	buf := make([]byte, 0, 8192)
	tmp := make([]byte, 4096)
	for len(buf) < maxHelloBytes {
		n, err := r.Read(tmp)
		if n > 0 {
			if len(buf)+n > maxHelloBytes {
				return nil, "", errors.New("ClientHello exceeds limit")
			}
			buf = append(buf, tmp[:n]...)
			sni, complete, perr := parseTLSClientHello(buf)
			if perr != nil {
				return nil, "", perr
			}
			if complete {
				return buf, sni, nil
			}
		}
		if err != nil {
			if err == io.EOF {
				return nil, "", errors.New("EOF before ClientHello")
			}
			return nil, "", err
		}
	}
	return nil, "", errors.New("ClientHello exceeds limit")
}

func parseTLSClientHello(data []byte) (string, bool, error) {
	// Reassemble one handshake message from one or more TLS handshake records.
	var hs []byte
	off := 0
	for {
		if len(data)-off < 5 {
			return "", false, nil
		}
		typ := data[off]
		recLen := int(binary.BigEndian.Uint16(data[off+3 : off+5]))
		if recLen <= 0 || recLen > 18432 {
			return "", false, errors.New("invalid TLS record length")
		}
		if len(data)-off < 5+recLen {
			return "", false, nil
		}
		if typ != 22 {
			if len(hs) == 0 {
				return "", false, fmt.Errorf("expected TLS handshake record, got %d", typ)
			}
		} else {
			hs = append(hs, data[off+5:off+5+recLen]...)
			if len(hs) >= 4 {
				if hs[0] != 1 {
					return "", false, fmt.Errorf("expected ClientHello, got handshake %d", hs[0])
				}
				want := 4 + int(hs[1])<<16 + int(hs[2])<<8 + int(hs[3])
				if want > maxHelloBytes {
					return "", false, errors.New("ClientHello handshake too large")
				}
				if len(hs) >= want {
					return parseClientHelloBody(hs[4:want])
				}
			}
		}
		off += 5 + recLen
		if off >= len(data) {
			return "", false, nil
		}
	}
}

func parseClientHelloBody(b []byte) (string, bool, error) {
	if len(b) < 34 {
		return "", false, errors.New("short ClientHello")
	}
	p := 34
	if p >= len(b) {
		return "", false, errors.New("short session id")
	}
	sid := int(b[p])
	p++
	if p+sid+2 > len(b) {
		return "", false, errors.New("bad session id")
	}
	p += sid
	cs := int(binary.BigEndian.Uint16(b[p : p+2]))
	p += 2
	if cs == 0 || cs%2 != 0 || p+cs+1 > len(b) {
		return "", false, errors.New("bad cipher suites")
	}
	p += cs
	comp := int(b[p])
	p++
	if p+comp > len(b) {
		return "", false, errors.New("bad compression list")
	}
	p += comp
	if p == len(b) {
		return "", true, nil
	} // valid old ClientHello with no extensions
	if p+2 > len(b) {
		return "", false, errors.New("short extensions length")
	}
	extTotal := int(binary.BigEndian.Uint16(b[p : p+2]))
	p += 2
	if p+extTotal > len(b) {
		return "", false, errors.New("bad extensions length")
	}
	end := p + extTotal
	for p+4 <= end {
		typ := binary.BigEndian.Uint16(b[p : p+2])
		n := int(binary.BigEndian.Uint16(b[p+2 : p+4]))
		p += 4
		if p+n > end {
			return "", false, errors.New("bad extension length")
		}
		if typ == 0 {
			e := b[p : p+n]
			if len(e) < 2 {
				return "", false, errors.New("short SNI extension")
			}
			listLen := int(binary.BigEndian.Uint16(e[:2]))
			q := 2
			if q+listLen > len(e) {
				return "", false, errors.New("bad SNI list")
			}
			limit := q + listLen
			for q+3 <= limit {
				nameType := e[q]
				nameLen := int(binary.BigEndian.Uint16(e[q+1 : q+3]))
				q += 3
				if q+nameLen > limit {
					return "", false, errors.New("bad SNI name")
				}
				if nameType == 0 {
					host := strings.ToLower(string(e[q : q+nameLen]))
					if !validHostname(host) {
						return "", false, errors.New("invalid SNI hostname")
					}
					return host, true, nil
				}
				q += nameLen
			}
			return "", true, nil
		}
		p += n
	}
	return "", true, nil
}

func androidRootPool() (*x509.CertPool, error) {
	pool, sysErr := x509.SystemCertPool()
	haveSystemPool := sysErr == nil && pool != nil
	if pool == nil {
		pool = x509.NewCertPool()
	}
	dirs := []string{
		"/apex/com.android.conscrypt/cacerts",
		"/system/etc/security/cacerts",
		"/data/misc/keychain/cacerts-added",
		"/data/misc/user/0/cacerts-added",
	}
	added := 0
	for _, dir := range dirs {
		entries, err := os.ReadDir(dir)
		if err != nil {
			continue
		}
		for _, e := range entries {
			if e.IsDir() {
				continue
			}
			b, err := os.ReadFile(filepath.Join(dir, e.Name()))
			if err != nil {
				continue
			}
			if pool.AppendCertsFromPEM(b) {
				added++
				continue
			}
			if cert, err := x509.ParseCertificate(b); err == nil {
				pool.AddCert(cert)
				added++
			}
		}
	}
	// Subjects() is documented to return nothing for a system pool, so it cannot
	// prove the pool is empty. Only give up when the system pool itself failed
	// AND no on-disk certificate directory was readable.
	if added == 0 && !haveSystemPool && len(pool.Subjects()) == 0 {
		return nil, errors.New("no trusted CA certificates found")
	}
	return pool, nil
}

func tlsDialIP(ip, domain string, timeout time.Duration) (*tls.Conn, error) {
	parsed := net.ParseIP(ip)
	if parsed == nil || parsed.To4() == nil {
		return nil, errors.New("invalid IPv4")
	}
	if !validHostname(strings.ToLower(domain)) {
		return nil, errors.New("invalid domain")
	}
	roots, err := androidRootPool()
	if err != nil {
		return nil, err
	}
	d := net.Dialer{Timeout: timeout, KeepAlive: 30 * time.Second}
	raw, err := d.Dial("tcp4", net.JoinHostPort(parsed.To4().String(), "443"))
	if err != nil {
		return nil, err
	}
	tc := tls.Client(raw, &tls.Config{ServerName: domain, RootCAs: roots, MinVersion: tls.VersionTLS12})
	_ = tc.SetDeadline(time.Now().Add(timeout))
	if err := tc.Handshake(); err != nil {
		raw.Close()
		return nil, err
	}
	return tc, nil
}

// gatewayLoc РРРРСРСРРС СССРРС РССРРР СРРРРёРРРРёС РР РРРРСР Cloudflare
// (/cdn-cgi/trace). РСССРС СССРРР РРРРСРРС ВРРСРРРРРёСС РР СРРРРССВ в СРР РСРРРС
// С РР-Cloudflare РРРРРРР (googleapis.com), Рё ССР РР РРРРР РСРСРРРРСРРСС gateway.
func gatewayLoc(ip, domain string, timeout time.Duration) string {
	c, err := tlsDialIP(ip, domain, timeout)
	if err != nil {
		return ""
	}
	defer c.Close()
	req := fmt.Sprintf("GET /cdn-cgi/trace HTTP/1.1\r\nHost: %s\r\nUser-Agent: AIUnblock/%s\r\nAccept: */*\r\nConnection: close\r\n\r\n", domain, version)
	if _, err = io.WriteString(c, req); err != nil {
		return ""
	}
	_, body, err := readHTTPResponse(bufio.NewReader(c), 65536)
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(body), "\n") {
		if strings.HasPrefix(line, "loc=") {
			return strings.ToUpper(strings.TrimSpace(strings.TrimPrefix(line, "loc=")))
		}
	}
	return ""
}

// probeGateway is the single definition of "this gateway works for this domain":
// TLS handshake with the real SNI plus an HTTP response with a sane status code.
// Both the single-shot tls-probe and the batched probe must use it, otherwise the
// batched path would silently accept gateways that only complete a handshake.
func probeGateway(ip, domain string, timeout time.Duration) (int, error) {
	c, err := tlsDialIP(ip, domain, timeout)
	if err != nil {
		return 0, err
	}
	defer c.Close()
	req := fmt.Sprintf("GET / HTTP/1.1\r\nHost: %s\r\nUser-Agent: AIUnblock/%s\r\nAccept: */*\r\nConnection: close\r\n\r\n", domain, version)
	if _, err = io.WriteString(c, req); err != nil {
		return 0, err
	}
	br := bufio.NewReader(c)
	line, err := br.ReadString('\n')
	if err != nil {
		return 0, err
	}
	parts := strings.Fields(line)
	if len(parts) < 2 {
		return 0, errors.New("malformed HTTP status line")
	}
	code, err := strconv.Atoi(parts[1])
	if err != nil {
		return 0, errors.New("malformed HTTP status code")
	}
	if code < 200 || code >= 500 {
		return code, fmt.Errorf("unexpected HTTP status %d", code)
	}
	return code, nil
}

// runTrace: РРёРРРРССРёРР ВСРСРР РРРСС СССРРС СРРРСРР РССРРРёС ССРС gatewayВ.
// Cloudflare РСРРСС ССР Р /cdn-cgi/trace РРССРСР СРРССРР, РРР РРСРё-РРСРРРР ССРРС,
// РРССРРС РР РРРС РРёРРР СР, СРРР РР РРёРРР РР РРРС РСРРСР: 403 РРРРС РССС Рё
// РРР-РРРРРР, Рё РСРССР РРСРёСРР РС РРСРР.
func runTrace(args []string) int {
	fs := flag.NewFlagSet("trace", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	ip := fs.String("ip", "", "IPv4 gateway")
	domain := fs.String("domain", "", "TLS SNI/Host")
	path := fs.String("path", "/cdn-cgi/trace", "request path")
	secs := fs.Int("timeout", 8, "timeout seconds")
	if fs.Parse(args) != nil {
		return 2
	}
	if *secs < 1 || *secs > 30 {
		return 2
	}
	c, err := tlsDialIP(*ip, *domain, time.Duration(*secs)*time.Second)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	defer c.Close()
	req := fmt.Sprintf("GET %s HTTP/1.1\r\nHost: %s\r\nUser-Agent: AIUnblock/%s\r\nAccept: */*\r\nConnection: close\r\n\r\n", *path, *domain, version)
	if _, err = io.WriteString(c, req); err != nil {
		return 1
	}
	status, body, err := readHTTPResponse(bufio.NewReader(c), 65536)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	loc := ""
	for _, line := range strings.Split(string(body), "\n") {
		if strings.HasPrefix(line, "loc=") {
			loc = strings.TrimSpace(strings.TrimPrefix(line, "loc="))
		}
	}
	fmt.Printf("status=%d loc=%s\n", status, loc)
	if loc == "" {
		return 1
	}
	return 0
}

func runTLSProbe(args []string) int {
	fs := flag.NewFlagSet("tls-probe", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	ip := fs.String("ip", "", "IPv4 gateway")
	domain := fs.String("domain", "", "TLS SNI/Host")
	secs := fs.Int("timeout", 4, "timeout seconds")
	if fs.Parse(args) != nil {
		return 2
	}
	if *secs < 1 || *secs > 30 {
		return 2
	}
	code, err := probeGateway(*ip, *domain, time.Duration(*secs)*time.Second)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	fmt.Println(code)
	return 0
}

// runProbe checks every candidate gateway against every domain inside a single
// process. The shell used to fork one process per (ip, domain) pair, which meant
// up to ~60 Go runtime startups for one failed gateway refresh.
// Selection order stays identical to the old shell logic: the first candidate in
// input order that passes every domain wins.
func runProbe(args []string) int {
	fs := flag.NewFlagSet("probe", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	candidates := fs.String("candidates", "", "space/comma separated IPv4 gateways, in priority order")
	domains := fs.String("domains", "", "space/comma separated domains that must all pass")
	secs := fs.Int("timeout", 4, "per-probe timeout seconds")
	max := fs.Int("max", 8, "maximum candidates to try")
	rejectLoc := fs.String("reject-loc", "", "reject a gateway whose Cloudflare exit country equals this (e.g. RU)")
	publicDNS := fs.String("public-dns", "", "plain DNS IPv4: candidates equal to its answer are the real server, not a bypass")
	if fs.Parse(args) != nil {
		return 2
	}
	if *secs < 1 || *secs > 30 {
		return 2
	}
	ips := splitList(*candidates)
	hosts := splitList(*domains)
	if len(ips) == 0 || len(hosts) == 0 {
		fmt.Fprintln(os.Stderr, "probe: -candidates and -domains are required")
		return 2
	}
	for _, h := range hosts {
		if !validHostname(strings.ToLower(h)) {
			fmt.Fprintf(os.Stderr, "probe: invalid domain %q\n", h)
			return 2
		}
	}
	if *max < 1 {
		*max = 1
	}

	timeout := time.Duration(*secs) * time.Second

	// РРСРС, РРСРССР РСРРСС РРССРСР СРРРРРРС, в ССР СРР РРРРРРРёСРРРРРСР СРСРРС.
	// РСРРСССРёР РРР, РРРСРС ССРёСРРС ВРРССССС РРРРРРВ, СРСС РРСРРР РРС: РёРРРРР СРР
	// NotebookLM РРРССРР СРРРСРСР IP Google, Р ChatGPT в СРССРёРСРРёР edge Cloudflare.
	// РРС РР-Cloudflare СРСРРёСРР ССР РРРёРССРРРРСР РРСССРРСР РСРёРРРР.
	realServer := map[string]bool{}
	if *publicDNS != "" {
		if answers, err := dnsQueryA(*publicDNS, hosts[0], timeout); err == nil {
			for _, a := range answers {
				realServer[a] = true
			}
		}
	}

	valid := make([]string, 0, len(ips))
	seen := map[string]bool{}
	for _, raw := range ips {
		ip := net.ParseIP(raw)
		if ip == nil || ip.To4() == nil {
			continue
		}
		s := ip.To4().String()
		if seen[s] || realServer[s] {
			continue
		}
		seen[s] = true
		valid = append(valid, s)
		if len(valid) >= *max {
			break
		}
	}
	if len(valid) == 0 {
		return 1
	}

	ok := make([]bool, len(valid))
	done := make(chan int, len(valid))
	for i, ip := range valid {
		go func(idx int, gateway string) {
			defer func() { done <- idx }()
			for _, h := range hosts {
				if _, err := probeGateway(gateway, h, timeout); err != nil {
					return
				}
			}
			// РСРРС 200..499 СРР РР СРРР РР РРРРСРРС, ССР РРРРРёСРРРР РРРРРРРР:
			// РРРРРРРёСРРРРРСР edge РСРРСРРС СРРРР СРР РР. РСРРРССРР СССРРС РССРРР
			// РРРёР СРР РР РРРРРёРРСР, Р РР РР РРРРСР РРРРР.
			if *rejectLoc != "" {
				if loc := gatewayLoc(gateway, hosts[0], timeout); loc != "" && loc == strings.ToUpper(*rejectLoc) {
					return
				}
			}
			ok[idx] = true
		}(i, ip)
	}
	for range valid {
		<-done
	}
	for i, good := range ok {
		if good {
			fmt.Println(valid[i])
			return 0
		}
	}
	return 1
}

// runResolve performs the whole gateway discovery step in one process: every DoH
// resolver is queried concurrently and, only if none answered, the plain DNS
// servers are tried. Output is "IP<TAB>source", newest-first by resolver order.
func runResolve(args []string) int {
	fs := flag.NewFlagSet("resolve", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	domain := fs.String("domain", "", "query name")
	resolvers := fs.String("resolvers", "", "space/comma separated https:// DoH URLs")
	plain := fs.String("dns", "", "space/comma separated plain DNS IPv4 fallback servers")
	bootstrap := fs.String("bootstrap", "", "space/comma separated DNS IPv4 servers used to resolve DoH hosts")
	secs := fs.Int("timeout", 6, "timeout seconds")
	if fs.Parse(args) != nil {
		return 2
	}
	if *secs < 1 || *secs > 30 {
		return 2
	}
	if !validHostname(strings.ToLower(strings.TrimSuffix(*domain, "."))) {
		fmt.Fprintln(os.Stderr, "resolve: invalid domain")
		return 2
	}
	timeout := time.Duration(*secs) * time.Second
	bootstrapServers := splitList(*bootstrap)
	urls := splitList(*resolvers)

	type result struct {
		ips    []string
		source string
	}
	results := make([]result, len(urls))
	done := make(chan struct{}, len(urls))
	for i, raw := range urls {
		go func(idx int, resolver string) {
			defer func() { done <- struct{}{} }()
			ips, err := dohQuery(resolver, *domain, bootstrapServers, timeout)
			if err != nil {
				return
			}
			results[idx] = result{ips: ips, source: resolver}
		}(i, raw)
	}
	for range urls {
		<-done
	}

	printed := map[string]bool{}
	found := false
	for _, r := range results {
		for _, ip := range r.ips {
			if printed[ip] {
				continue
			}
			printed[ip] = true
			found = true
			fmt.Printf("%s\t%s\n", ip, r.source)
		}
	}
	if found {
		return 0
	}

	// DoH is optional: fall back to the configured plain DNS servers.
	for _, server := range splitList(*plain) {
		ips, err := dnsQueryA(server, *domain, timeout/2)
		if err != nil {
			continue
		}
		for _, ip := range ips {
			if printed[ip] {
				continue
			}
			printed[ip] = true
			found = true
			fmt.Printf("%s\tdns:%s\n", ip, server)
		}
	}
	if found {
		return 0
	}
	return 1
}

func splitList(s string) []string {
	return strings.Fields(strings.ReplaceAll(strings.ReplaceAll(s, ",", " "), "\n", " "))
}

func dnsPacket(domain string, id uint16) ([]byte, error) {
	domain = strings.ToLower(strings.TrimSuffix(domain, "."))
	if !validHostname(domain) {
		return nil, errors.New("invalid DNS name")
	}
	b := make([]byte, 12, 512)
	binary.BigEndian.PutUint16(b[0:2], id)
	binary.BigEndian.PutUint16(b[2:4], 0x0100)
	binary.BigEndian.PutUint16(b[4:6], 1)
	for _, label := range strings.Split(domain, ".") {
		b = append(b, byte(len(label)))
		b = append(b, label...)
	}
	b = append(b, 0, 0, 1, 0, 1)
	return b, nil
}

func randomID() uint16 {
	var b [2]byte
	if _, err := rand.Read(b[:]); err == nil {
		return binary.BigEndian.Uint16(b[:])
	}
	return uint16(time.Now().UnixNano())
}

func dnsQueryA(server, domain string, timeout time.Duration) ([]string, error) {
	ip := net.ParseIP(server)
	if ip == nil || ip.To4() == nil {
		return nil, errors.New("DNS server must be IPv4")
	}
	id := randomID()
	q, err := dnsPacket(domain, id)
	if err != nil {
		return nil, err
	}
	c, err := net.DialTimeout("udp4", net.JoinHostPort(ip.To4().String(), "53"), timeout)
	if err != nil {
		return nil, err
	}
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(timeout))
	if _, err = c.Write(q); err != nil {
		return nil, err
	}
	buf := make([]byte, 4096)
	n, err := c.Read(buf)
	if err != nil {
		return nil, err
	}
	return parseDNSA(buf[:n], id)
}

func skipDNSName(b []byte, p int) (int, error) {
	for {
		if p >= len(b) {
			return 0, io.ErrUnexpectedEOF
		}
		n := int(b[p])
		p++
		if n == 0 {
			return p, nil
		}
		if n&0xC0 == 0xC0 {
			if p >= len(b) {
				return 0, io.ErrUnexpectedEOF
			}
			return p + 1, nil
		}
		if n > 63 || p+n > len(b) {
			return 0, errors.New("bad DNS name")
		}
		p += n
	}
}

func parseDNSA(b []byte, id uint16) ([]string, error) {
	if len(b) < 12 || binary.BigEndian.Uint16(b[:2]) != id {
		return nil, errors.New("invalid DNS response ID")
	}
	flags := binary.BigEndian.Uint16(b[2:4])
	if flags&0x8000 == 0 || flags&0x000F != 0 {
		return nil, errors.New("DNS response error")
	}
	qd := int(binary.BigEndian.Uint16(b[4:6]))
	an := int(binary.BigEndian.Uint16(b[6:8]))
	p := 12
	var err error
	for i := 0; i < qd; i++ {
		p, err = skipDNSName(b, p)
		if err != nil || p+4 > len(b) {
			return nil, errors.New("bad DNS question")
		}
		p += 4
	}
	out := []string{}
	for i := 0; i < an; i++ {
		p, err = skipDNSName(b, p)
		if err != nil || p+10 > len(b) {
			return nil, errors.New("bad DNS answer")
		}
		typ := binary.BigEndian.Uint16(b[p : p+2])
		class := binary.BigEndian.Uint16(b[p+2 : p+4])
		rdlen := int(binary.BigEndian.Uint16(b[p+8 : p+10]))
		p += 10
		if p+rdlen > len(b) {
			return nil, errors.New("bad DNS rdata")
		}
		if typ == 1 && class == 1 && rdlen == 4 {
			out = append(out, net.IPv4(b[p], b[p+1], b[p+2], b[p+3]).String())
		}
		p += rdlen
	}
	if len(out) == 0 {
		return nil, errors.New("DNS response has no A records")
	}
	return out, nil
}

func runDNS(args []string) int {
	fs := flag.NewFlagSet("dns", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	server := fs.String("server", "", "DNS IPv4")
	domain := fs.String("domain", "", "query name")
	secs := fs.Int("timeout", 3, "timeout seconds")
	if fs.Parse(args) != nil {
		return 2
	}
	if *secs < 1 || *secs > 30 {
		return 2
	}
	ips, err := dnsQueryA(*server, *domain, time.Duration(*secs)*time.Second)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	for _, ip := range ips {
		fmt.Println(ip)
	}
	return 0
}

func resolveViaBootstrap(host string, servers []string, timeout time.Duration) ([]string, error) {
	if ip := net.ParseIP(host); ip != nil && ip.To4() != nil {
		return []string{ip.To4().String()}, nil
	}
	var last error
	seen := map[string]bool{}
	out := []string{}
	for _, s := range servers {
		ips, err := dnsQueryA(s, host, timeout)
		if err != nil {
			last = err
			continue
		}
		for _, ip := range ips {
			if !seen[ip] {
				seen[ip] = true
				out = append(out, ip)
			}
		}
	}
	if len(out) == 0 {
		if last == nil {
			last = errors.New("bootstrap DNS failed")
		}
		return nil, last
	}
	return out, nil
}

// readHTTPResponse в РРёРРёРРРСРСР СРРРРС РСРРСР HTTP/1.x РРРССР net/http.
// РСРРР СРРРР РРРёР POST РР DoH-СРРРРРРС, Р РРСС РРРРС net/http ССРРС Р РРёРРСРРёР
// РРРРР РРРРРРРСР РР РРРРСС ABI. РРРРРСРРёРРСССС Content-Length, chunked Рё
// ВСРёСРСС РР РРРСССРёСВ (РС РСРРРР СРСР Connection: close).
func readHTTPResponse(r *bufio.Reader, limit int64) (int, []byte, error) {
	line, err := r.ReadString('\n')
	if err != nil {
		return 0, nil, err
	}
	parts := strings.Fields(line)
	if len(parts) < 2 || !strings.HasPrefix(parts[0], "HTTP/") {
		return 0, nil, errors.New("malformed HTTP status line")
	}
	status, err := strconv.Atoi(parts[1])
	if err != nil {
		return 0, nil, errors.New("malformed HTTP status code")
	}

	contentLength := int64(-1)
	chunked := false
	for headers := 0; ; headers++ {
		if headers > 100 {
			return 0, nil, errors.New("too many HTTP headers")
		}
		h, err := r.ReadString('\n')
		if err != nil {
			return 0, nil, err
		}
		h = strings.TrimRight(h, "\r\n")
		if h == "" {
			break
		}
		idx := strings.IndexByte(h, ':')
		if idx < 0 {
			continue
		}
		name := strings.ToLower(strings.TrimSpace(h[:idx]))
		value := strings.TrimSpace(h[idx+1:])
		switch name {
		case "content-length":
			n, e := strconv.ParseInt(value, 10, 64)
			if e != nil || n < 0 {
				return 0, nil, errors.New("bad Content-Length")
			}
			contentLength = n
		case "transfer-encoding":
			if strings.Contains(strings.ToLower(value), "chunked") {
				chunked = true
			}
		}
	}

	switch {
	case chunked:
		var body []byte
		for {
			sizeLine, err := r.ReadString('\n')
			if err != nil {
				return 0, nil, err
			}
			sizeLine = strings.TrimRight(sizeLine, "\r\n")
			if i := strings.IndexByte(sizeLine, ';'); i >= 0 {
				sizeLine = sizeLine[:i]
			}
			size, err := strconv.ParseInt(strings.TrimSpace(sizeLine), 16, 64)
			if err != nil || size < 0 {
				return 0, nil, errors.New("bad chunk size")
			}
			if size == 0 {
				return status, body, nil
			}
			if int64(len(body))+size > limit {
				return 0, nil, errors.New("HTTP body exceeds limit")
			}
			chunk := make([]byte, size)
			if _, err = io.ReadFull(r, chunk); err != nil {
				return 0, nil, err
			}
			body = append(body, chunk...)
			// CRLF РРСРР СРРРР
			if _, err = r.Discard(2); err != nil {
				return 0, nil, err
			}
		}
	case contentLength >= 0:
		if contentLength > limit {
			return 0, nil, errors.New("HTTP body exceeds limit")
		}
		body := make([]byte, contentLength)
		if _, err = io.ReadFull(r, body); err != nil {
			return 0, nil, err
		}
		return status, body, nil
	default:
		body, err := io.ReadAll(io.LimitReader(r, limit))
		if err != nil {
			return 0, nil, err
		}
		return status, body, nil
	}
}

func dohQuery(resolver, domain string, bootstrapServers []string, timeout time.Duration) ([]string, error) {
	u, err := url.Parse(resolver)
	if err != nil || u.Scheme != "https" || u.Hostname() == "" {
		return nil, errors.New("invalid DoH URL")
	}
	if len(bootstrapServers) == 0 {
		return nil, errors.New("no bootstrap DNS servers")
	}
	resolverIPs, err := resolveViaBootstrap(u.Hostname(), bootstrapServers, timeout/2)
	if err != nil {
		return nil, err
	}
	qid := randomID()
	q, err := dnsPacket(domain, qid)
	if err != nil {
		return nil, err
	}
	port := u.Port()
	if port == "" {
		port = "443"
	}
	roots, err := androidRootPool()
	if err != nil {
		return nil, err
	}
	var last error = errors.New("no DoH resolver answered")
	for _, rip := range resolverIPs {
		d := net.Dialer{Timeout: timeout}
		raw, e := d.Dial("tcp4", net.JoinHostPort(rip, port))
		if e != nil {
			last = e
			continue
		}
		// РРР ALPN СРСРРС, РСРРРРСРёСРССРёР HTTP/2, РСРРСРРС РР РРС HTTP/1.1-РРРСРС
		// РРРРР 505. РРРР РРРРРРСРёРРРРСС РР http/1.1 в РёРРСР СРССС ССРСРСС
		// DoH-СРРРРРРСРР (РРРСРёРРС dns.malw.link) РР СРРРСРРС РРРРСР.
		tc := tls.Client(raw, &tls.Config{
			ServerName: u.Hostname(),
			RootCAs:    roots,
			MinVersion: tls.VersionTLS12,
			NextProtos: []string{"http/1.1"},
		})
		_ = tc.SetDeadline(time.Now().Add(timeout))
		if e = tc.Handshake(); e != nil {
			raw.Close()
			last = e
			continue
		}
		path := u.RequestURI()
		if path == "" {
			path = "/dns-query"
		}
		req := fmt.Sprintf("POST %s HTTP/1.1\r\nHost: %s\r\nUser-Agent: AIUnblock/%s\r\nAccept: application/dns-message\r\nContent-Type: application/dns-message\r\nContent-Length: %d\r\nConnection: close\r\n\r\n", path, u.Host, version, len(q))
		if _, e = io.WriteString(tc, req); e == nil {
			_, e = tc.Write(q)
		}
		if e != nil {
			tc.Close()
			last = e
			continue
		}
		status, body, e := readHTTPResponse(bufio.NewReader(tc), 65536)
		tc.Close()
		if e != nil {
			last = e
			continue
		}
		if status < 200 || status >= 300 {
			last = fmt.Errorf("DoH HTTP %d", status)
			continue
		}
		ips, e := parseDNSA(body, qid)
		if e != nil {
			last = e
			continue
		}
		return ips, nil
	}
	return nil, last
}

func runDoH(args []string) int {
	fs := flag.NewFlagSet("doh", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	resolver := fs.String("resolver", "", "https:// resolver URL")
	domain := fs.String("domain", "", "query name")
	bootstrap := fs.String("bootstrap", "", "space/comma separated DNS IPv4 servers")
	secs := fs.Int("timeout", 6, "timeout seconds")
	if fs.Parse(args) != nil {
		return 2
	}
	if *secs < 1 || *secs > 30 {
		return 2
	}
	ips, err := dohQuery(*resolver, *domain, splitList(*bootstrap), time.Duration(*secs)*time.Second)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	for _, ip := range ips {
		fmt.Println(ip)
	}
	return 0
}

func buildFakeClientHello(host string) []byte {
	// Minimal parser self-test only; not intended for network use.
	sniName := []byte(host)
	sni := make([]byte, 0, 5+len(sniName))
	listLen := 3 + len(sniName)
	sni = append(sni, byte(listLen>>8), byte(listLen), 0, byte(len(sniName)>>8), byte(len(sniName)))
	sni = append(sni, sniName...)
	ext := append([]byte{0, 0, byte(len(sni) >> 8), byte(len(sni))}, sni...)
	body := make([]byte, 0, 64+len(ext))
	body = append(body, 3, 3)
	body = append(body, make([]byte, 32)...)
	body = append(body, 0)
	body = append(body, 0, 2, 0x13, 0x01)
	body = append(body, 1, 0)
	body = append(body, byte(len(ext)>>8), byte(len(ext)))
	body = append(body, ext...)
	hs := []byte{1, byte(len(body) >> 16), byte(len(body) >> 8), byte(len(body))}
	hs = append(hs, body...)
	rec := []byte{22, 3, 1, byte(len(hs) >> 8), byte(len(hs))}
	return append(rec, hs...)
}

func runSelfTest() int {
	hello := buildFakeClientHello("gemini.google.com")
	sni, complete, err := parseTLSClientHello(hello)
	if err != nil || !complete || sni != "gemini.google.com" {
		fmt.Fprintf(os.Stderr, "ClientHello parser self-test failed: sni=%q complete=%v err=%v\n", sni, complete, err)
		return 1
	}
	// sockaddr_in decoder self-test used by transparent pass-through.
	rawDst := []byte{2, 0, 1, 187, 203, 0, 113, 7, 0, 0, 0, 0, 0, 0, 0, 0}
	dst, derr := decodeOriginalDst(rawDst)
	if derr != nil || dst.IP.String() != "203.0.113.7" || dst.Port != 443 {
		fmt.Fprintf(os.Stderr, "SO_ORIGINAL_DST decoder self-test failed: dst=%v err=%v\n", dst, derr)
		return 1
	}
	// DNS parser self-test.
	id := uint16(0x1234)
	q, _ := dnsPacket("example.com", id)
	if len(q) < 20 {
		fmt.Fprintln(os.Stderr, "DNS builder self-test failed")
		return 1
	}
	// DNS answer decoder: header + question + one A record for 203.0.113.7.
	answer := []byte{
		0x12, 0x34, 0x81, 0x80, 0, 1, 0, 1, 0, 0, 0, 0,
		7, 'e', 'x', 'a', 'm', 'p', 'l', 'e', 3, 'c', 'o', 'm', 0, 0, 1, 0, 1,
		0xC0, 0x0C, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 203, 0, 113, 7,
	}
	ips, aerr := parseDNSA(answer, id)
	if aerr != nil || len(ips) != 1 || ips[0] != "203.0.113.7" {
		fmt.Fprintf(os.Stderr, "DNS answer parser self-test failed: ips=%v err=%v\n", ips, aerr)
		return 1
	}
	// Argument list splitting shared by probe/resolve.
	if l := splitList(" 1.2.3.4, 5.6.7.8\n9.9.9.9 "); len(l) != 3 || l[2] != "9.9.9.9" {
		fmt.Fprintf(os.Stderr, "list parser self-test failed: %v\n", l)
		return 1
	}
	// HTTP reader used by DoH: Content-Length, chunked and read-until-close.
	for name, raw := range map[string]string{
		"content-length": "HTTP/1.1 200 OK\r\nContent-Type: application/dns-message\r\nContent-Length: 5\r\n\r\nhello",
		"chunked":        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nhel\r\n2\r\nlo\r\n0\r\n\r\n",
		"until-close":    "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\nhello",
	} {
		code, body, herr := readHTTPResponse(bufio.NewReader(strings.NewReader(raw)), 65536)
		if herr != nil || code != 200 || string(body) != "hello" {
			fmt.Fprintf(os.Stderr, "HTTP reader self-test failed (%s): code=%d body=%q err=%v\n", name, code, body, herr)
			return 1
		}
	}
	if _, _, herr := readHTTPResponse(bufio.NewReader(strings.NewReader("HTTP/1.1 200 OK\r\nContent-Length: 999999\r\n\r\nx")), 1024); herr == nil {
		fmt.Fprintln(os.Stderr, "HTTP reader self-test failed: oversized body accepted")
		return 1
	}
	fmt.Printf("OK AIUnblock native=%s GOOS=%s GOARCH=%s ptr=%d\n", version, runtime.GOOS, runtime.GOARCH, unsafe.Sizeof(uintptr(0))*8)
	return 0
}

// Keep bytes imported in the build as a cheap guard against accidental removal of
// useful binary helpers during source minimization; also provides an allocation-free
// equality primitive to the compiler in some architectures.
var _ = bytes.Equal
