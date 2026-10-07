package objstore

// FakeS3 is a minimal S3-compatible HTTP server over a Dir, for local tests of the SDK path
// (internal tests, k2probe fakes3, make oracle-cohort). It implements path-style PutObject,
// GetObject, HeadObject, CreateMultipartUpload, UploadPart, CompleteMultipartUpload and
// AbortMultipartUpload, with Dir's S3 part rules. It does not check signatures.

import (
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"sync/atomic"
)

// FakeS3 serves a Dir.
type FakeS3 struct {
	Dir      *Dir
	Requests atomic.Int64
	Parts    atomic.Int64
}

type xmlCreate struct {
	XMLName  xml.Name `xml:"InitiateMultipartUploadResult"`
	Bucket   string
	Key      string
	UploadId string
}

type xmlComplete struct {
	Parts []struct {
		ETag       string
		PartNumber int
	} `xml:"Part"`
}

type xmlError struct {
	XMLName xml.Name `xml:"Error"`
	Code    string
	Message string
}

func s3err(w http.ResponseWriter, status int, code, msg string) {
	w.Header().Set("Content-Type", "application/xml")
	w.WriteHeader(status)
	_ = xml.NewEncoder(w).Encode(xmlError{Code: code, Message: msg})
}

// ServeHTTP implements http.Handler.
func (f *FakeS3) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	f.Requests.Add(1)
	ctx := r.Context()
	path := strings.TrimPrefix(r.URL.Path, "/")
	bucket, key, _ := strings.Cut(path, "/")
	if bucket == "" || key == "" {
		s3err(w, 400, "InvalidRequest", "path-style /bucket/key only")
		return
	}
	q := r.URL.Query()
	switch {
	case r.Method == http.MethodPost && q.Has("uploads"):
		id, err := f.Dir.CreateMultipart(ctx, bucket, key)
		if err != nil {
			s3err(w, 500, "InternalError", err.Error())
			return
		}
		w.Header().Set("Content-Type", "application/xml")
		_ = xml.NewEncoder(w).Encode(xmlCreate{Bucket: bucket, Key: key, UploadId: id})
	case r.Method == http.MethodPut && q.Get("uploadId") != "":
		n, err := strconv.Atoi(q.Get("partNumber"))
		if err != nil {
			s3err(w, 400, "InvalidArgument", "partNumber")
			return
		}
		body, err := io.ReadAll(r.Body)
		if err != nil {
			s3err(w, 400, "IncompleteBody", err.Error())
			return
		}
		etag, err := f.Dir.UploadPart(ctx, bucket, key, q.Get("uploadId"), n, body)
		if err != nil {
			s3err(w, 400, "InvalidPart", err.Error())
			return
		}
		f.Parts.Add(1)
		w.Header().Set("ETag", `"`+etag+`"`)
	case r.Method == http.MethodPost && q.Get("uploadId") != "":
		var c xmlComplete
		if err := xml.NewDecoder(r.Body).Decode(&c); err != nil {
			s3err(w, 400, "MalformedXML", err.Error())
			return
		}
		parts := make([]Part, len(c.Parts))
		for i, p := range c.Parts {
			parts[i] = Part{Number: p.PartNumber, ETag: strings.Trim(p.ETag, `"`)}
		}
		if err := f.Dir.Complete(ctx, bucket, key, q.Get("uploadId"), parts); err != nil {
			code := "InvalidPart"
			if strings.Contains(err.Error(), "EntityTooSmall") {
				code = "EntityTooSmall"
			}
			s3err(w, 400, code, err.Error())
			return
		}
		w.Header().Set("Content-Type", "application/xml")
		fmt.Fprintf(w, `<CompleteMultipartUploadResult><Bucket>%s</Bucket><Key>%s</Key><ETag>"done"</ETag></CompleteMultipartUploadResult>`, bucket, key)
	case r.Method == http.MethodDelete && q.Get("uploadId") != "":
		if err := f.Dir.Abort(ctx, bucket, key, q.Get("uploadId")); err != nil {
			s3err(w, 404, "NoSuchUpload", err.Error())
			return
		}
		w.WriteHeader(http.StatusNoContent)
	case r.Method == http.MethodPut:
		body, err := io.ReadAll(r.Body)
		if err != nil {
			s3err(w, 400, "IncompleteBody", err.Error())
			return
		}
		if err := f.Dir.Put(ctx, bucket, key, body); err != nil {
			s3err(w, 500, "InternalError", err.Error())
			return
		}
		w.Header().Set("ETag", `"put"`)
	case r.Method == http.MethodGet || r.Method == http.MethodHead:
		b, err := f.Dir.Get(ctx, bucket, key)
		if errors.Is(err, ErrNotFound) {
			s3err(w, 404, "NoSuchKey", key)
			return
		}
		if err != nil {
			s3err(w, 500, "InternalError", err.Error())
			return
		}
		w.Header().Set("Content-Length", strconv.Itoa(len(b)))
		if r.Method == http.MethodGet {
			_, _ = w.Write(b)
		}
	default:
		s3err(w, 405, "MethodNotAllowed", r.Method)
	}
}
