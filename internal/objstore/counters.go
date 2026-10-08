package objstore

import (
	"fmt"
	"sync/atomic"
)

// OpCounts are the S3 requests a client made, by operation (one per attempt the client
// reports; the SDK's own retries are not visible here).
type OpCounts struct {
	Put, Get, Create, Part, Complete, Abort atomic.Int64
	PartBytes                               atomic.Int64
}

// Counts per client, for the run's request accounting (ak2_req; the engine's ak2-engine s3
// lines). Rendezvous Gets and Puts are included: they go through the same stores.
var (
	SDKCounts OpCounts
	CLICounts OpCounts
)

// Line is the counters as tab-separated key/value pairs.
func (c *OpCounts) Line() string {
	return fmt.Sprintf("put\t%d\tget\t%d\tcreate_multipart\t%d\tupload_part\t%d\tcomplete_multipart\t%d\tabort_multipart\t%d\tpart_bytes\t%d",
		c.Put.Load(), c.Get.Load(), c.Create.Load(), c.Part.Load(), c.Complete.Load(), c.Abort.Load(), c.PartBytes.Load())
}
