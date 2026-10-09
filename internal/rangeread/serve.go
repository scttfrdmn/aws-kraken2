package rangeread

import (
	"io"
	"net/http"
	"time"
)

// FileHandler serves the size bytes of r the way S3 serves an object to HTTPSource: ranged GETs
// (206 with Content-Range), the given ETag, and If-Match (412 when it does not match), through
// http.ServeContent. k2probe serve-file and the engine's tests use it; it is for local
// rehearsals only. Each request reads through its own io.SectionReader, so concurrent ranged
// GETs do not share a file offset.
func FileHandler(r io.ReaderAt, size int64, mod time.Time, etag string) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		w.Header().Set("ETag", `"`+etag+`"`)
		http.ServeContent(w, req, "", mod, io.NewSectionReader(r, 0, size))
	})
}
