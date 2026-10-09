package main

import (
	"flag"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"

	"github.com/scttfrdmn/aws-kraken2/internal/rangeread"
)

func init() {
	commands["serve-file"] = command{
		summary: "serve one file over HTTP with Range, ETag and If-Match, standing in for an S3 object (make rehearse)",
		run:     serveFile,
	}
}

// serveFile serves FILE at PATH the way the engine reads RODA's hash.k2d: ranged GETs with
// If-Match: ETag (http.ServeContent answers 206 with Content-Range, and 412 when If-Match does
// not match). For local rehearsals only.
func serveFile(args []string) error {
	fs := flag.NewFlagSet("serve-file", flag.ContinueOnError)
	file := fs.String("file", "", "the file to serve")
	path := fs.String("path", "/", "the URL path it is served at")
	etag := fs.String("etag", "", "its ETag (without quotes)")
	addr := fs.String("addr", "127.0.0.1:0", "listen address")
	urlFile := fs.String("url-file", "", "write the file's URL here once listening")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *file == "" || *etag == "" {
		return fmt.Errorf("-file and -etag are required")
	}
	f, err := os.Open(*file)
	if err != nil {
		return err
	}
	st, err := f.Stat()
	if err != nil {
		return err
	}
	ln, err := net.Listen("tcp", *addr)
	if err != nil {
		return err
	}
	url := "http://" + ln.Addr().String() + *path
	if *urlFile != "" {
		if err := os.WriteFile(*urlFile, []byte(url+"\n"), 0o644); err != nil {
			return err
		}
	}
	fmt.Fprintln(os.Stderr, "serve-file:", *file, "at", url)
	mux := http.NewServeMux()
	mux.Handle(*path, rangeread.FileHandler(f, st.Size(), st.ModTime(), *etag))
	srv := &http.Server{Handler: mux}
	go func() {
		ch := make(chan os.Signal, 1)
		signal.Notify(ch, syscall.SIGTERM, syscall.SIGINT)
		<-ch
		srv.Close()
	}()
	if err := srv.Serve(ln); err != http.ErrServerClosed {
		return err
	}
	return nil
}
