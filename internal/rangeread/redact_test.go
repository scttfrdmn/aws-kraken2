package rangeread

import (
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

const secretQuery = "X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=ASIAEXAMPLE&X-Amz-Security-Token=SESSIONTOKENSECRET&X-Amz-Signature=deadbeefsignature"

// TestRedactPresigned: no error from an HTTPSource carries a presigned URL's query string, or an
// S3 error body that echoes it (SignatureDoesNotMatch returns the canonical request).
func TestRedactPresigned(t *testing.T) {
	leak := func(t *testing.T, err error) {
		t.Helper()
		if err == nil {
			t.Fatal("no error")
		}
		for _, s := range []string{"SESSIONTOKENSECRET", "deadbeefsignature", "ASIAEXAMPLE", "X-Amz-"} {
			if strings.Contains(err.Error(), s) {
				t.Fatalf("error leaks %q: %v", s, err)
			}
		}
	}
	for _, tc := range []struct {
		name   string
		status int
		body   string
	}{
		{"403", 403, "<Error><Code>SignatureDoesNotMatch</Code><CanonicalRequest>GET /k " + secretQuery + "</CanonicalRequest></Error>"},
		{"412", 412, ""},
		{"500", 500, "<Error><Code>InternalError</Code><Message>" + secretQuery + "</Message></Error>"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(tc.status)
				_, _ = w.Write([]byte(tc.body))
			}))
			defer srv.Close()
			s := &HTTPSource{URL: srv.URL + "/bucket/hash.k2d?" + secretQuery, ETag: "e", Client: srv.Client(), MaxRetries: 1}
			err := s.ReadRange(context.Background(), 0, make([]byte, 8))
			leak(t, err)
			if tc.status == 403 && !strings.Contains(err.Error(), "SignatureDoesNotMatch") {
				t.Fatalf("the S3 error code is lost: %v", err)
			}
		})
	}
	// A transport error (*url.Error names the URL).
	ln, _ := net.Listen("tcp", "127.0.0.1:0")
	addr := ln.Addr().String()
	ln.Close()
	s := &HTTPSource{URL: "http://" + addr + "/b/k?" + secretQuery, Client: http.DefaultClient, MaxRetries: 1}
	leak(t, s.ReadRange(context.Background(), 0, make([]byte, 8)))
	// A malformed URL.
	s = &HTTPSource{URL: "http://bad host/k?" + secretQuery, Client: http.DefaultClient}
	leak(t, s.ReadRange(context.Background(), 0, make([]byte, 8)))
	if got := Redact("https://b.s3.amazonaws.com/k?" + secretQuery); got != "https://b.s3.amazonaws.com/k?<redacted>" {
		t.Fatalf("Redact: %s", got)
	}
}
