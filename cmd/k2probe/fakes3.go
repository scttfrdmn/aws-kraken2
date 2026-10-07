package main

import (
	"flag"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"

	"github.com/scttfrdmn/aws-kraken2/internal/objstore"
)

func init() {
	commands["fakes3"] = command{
		summary: "serve a fake S3 (path-style) over a directory, for local tests of the SDK path",
		run:     fakeS3,
	}
}

// fakeS3 serves objstore.FakeS3 over a directory, for local tests of the engine's SDK path
// (make oracle-cohort): aws-kraken2 with AK2_S3_ENDPOINT=<the printed URL>. Not for AWS.
func fakeS3(args []string) error {
	fs := flag.NewFlagSet("fakes3", flag.ContinueOnError)
	dir := fs.String("dir", "", "directory holding the buckets")
	addr := fs.String("addr", "127.0.0.1:0", "listen address")
	urlFile := fs.String("url-file", "", "write the server URL here once listening")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *dir == "" {
		return fmt.Errorf("-dir is required")
	}
	ln, err := net.Listen("tcp", *addr)
	if err != nil {
		return err
	}
	url := "http://" + ln.Addr().String()
	if *urlFile != "" {
		if err := os.WriteFile(*urlFile, []byte(url+"\n"), 0o644); err != nil {
			return err
		}
	}
	fmt.Fprintln(os.Stderr, "fakes3: serving", *dir, "at", url)
	srv := &http.Server{Handler: &objstore.FakeS3{Dir: &objstore.Dir{Root: *dir}}}
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
