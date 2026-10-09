package seqio

// Decompression oracle: the bytes Open hands the parser must equal what the wrapper's
// `gzip -dc` / `bzip2 -dc` hand classify, including after errors (trailing padding or garbage,
// truncation, input that is not compressed). scripts/equiv-seqout.sh writes the tool outputs
// and runs this; without it the test skips.

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/scttfrdmn/aws-kraken2/internal/oracletest"
)

func TestOracleDecompress(t *testing.T) {
	list := os.Getenv("K2_DECOMP_ORACLE")
	if list == "" {
		// The latest make equiv-seqout work directory, if there is one.
		list = filepath.Join(oracletest.Root(), ".cache", "equiv-seqout", "latest", "decomp.tsv")
	}
	if _, err := os.Stat(list); err != nil {
		oracletest.Skip(t, "no decompression oracle at %s (make equiv-seqout)", list)
	}
	data, err := os.ReadFile(list)
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(string(data)), "\n")
	if len(lines) == 0 || lines[0] == "" {
		t.Fatal("no decompression cases")
	}
	DecompressLog = io.Discard
	defer func() { DecompressLog = os.Stderr }()
	// AK2_DECOMPRESS=pipe: the bytes OpenPipe hands on (make equiv-seqout under pipe mode).
	d, err := ParseDecompressor(os.Getenv("AK2_DECOMPRESS"))
	if err != nil {
		t.Fatal(err)
	}
	var summary bytes.Buffer
	summary.WriteString("tool\tinput\tbytes_tool\tbytes_go\tsha256_tool\tsha256_go\tidentical\tdecompressor\n")
	for _, line := range lines {
		f := strings.Split(line, "\t")
		if len(f) != 3 {
			t.Fatalf("bad line %q", line)
		}
		c := CompressionGzip
		if f[0] == "bzip2" {
			c = CompressionBzip2
		}
		want, err := os.ReadFile(f[2])
		if err != nil {
			t.Fatal(err)
		}
		r, err := OpenWith(f[1], c, d)
		if err != nil {
			t.Fatal(err)
		}
		got, err := io.ReadAll(r.src)
		r.Close()
		if err != nil {
			t.Errorf("%s: %v", f[1], err)
		}
		same := bytes.Equal(got, want)
		if !same {
			n := 0
			for n < len(got) && n < len(want) && got[n] == want[n] {
				n++
			}
			t.Errorf("%s %s: %d bytes, tool gave %d; first difference at %d", f[0], filepath.Base(f[1]), len(got), len(want), n)
		}
		hw, hg := sha256.Sum256(want), sha256.Sum256(got)
		fmt.Fprintf(&summary, "%s\t%s\t%d\t%d\t%s\t%s\t%v\t%s\n", f[0], filepath.Base(f[1]), len(want), len(got),
			hex.EncodeToString(hw[:]), hex.EncodeToString(hg[:]), same, d)
	}
	if out := os.Getenv("K2_DECOMP_SUMMARY"); out != "" {
		if err := os.WriteFile(out, summary.Bytes(), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}
