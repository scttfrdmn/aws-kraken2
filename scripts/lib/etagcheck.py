#!/usr/bin/env python3
"""Check a local copy against an S3 object's ETag (docs/g2.md). Usage:

    etagcheck.py FILE ETAG [--part-bytes N] [--workers N]

A multipart ETag is md5(concat(md5(part_i))) + "-" + part count. The part size is not stored, so
it is inferred: the smallest power-of-two MiB size (or the --part-bytes given) whose part count
for this file size equals the ETag's count. A single-part ETag is the plain md5. Parts are hashed
in parallel with os.pread (hashlib releases the GIL), which also measures the device's sequential
read rate. Prints one JSON object; exits 1 on a mismatch, 2 on a usage or inference error.
"""
import argparse
import binascii
import hashlib
import json
import os
import sys
import time
from concurrent.futures import ThreadPoolExecutor

CHUNK = 8 << 20


def md5_range(fd, off, n):
    h = hashlib.md5()
    while n > 0:
        b = os.pread(fd, min(CHUNK, n), off)
        if not b:
            raise IOError("short read at %d" % off)
        h.update(b)
        off += len(b)
        n -= len(b)
    return h.digest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("file")
    ap.add_argument("etag")
    ap.add_argument("--part-bytes", type=int, default=0)
    ap.add_argument("--workers", type=int, default=min(64, (os.cpu_count() or 4) * 2))
    a = ap.parse_args()
    etag = a.etag.strip('"')
    size = os.path.getsize(a.file)
    if "-" in etag:
        want_hex, cnt = etag.split("-")
        cnt = int(cnt)
        part = a.part_bytes
        if not part:
            for mib in [1 << i for i in range(0, 13)]:
                p = mib << 20
                if (size + p - 1) // p == cnt:
                    part = p
                    break
        if not part or (size + part - 1) // part != cnt:
            print(json.dumps({"ok": False, "error": "cannot infer part size", "size": size, "etag": etag}))
            sys.exit(2)
    else:
        want_hex, cnt, part = etag, 1, size
    fd = os.open(a.file, os.O_RDONLY)
    t0 = time.monotonic()
    offs = [(i * part, min(part, size - i * part)) for i in range(cnt)]
    with ThreadPoolExecutor(max_workers=a.workers) as ex:
        digests = list(ex.map(lambda x: md5_range(fd, x[0], x[1]), offs))
    dt = time.monotonic() - t0
    os.close(fd)
    got = hashlib.md5(b"".join(digests)).hexdigest() if cnt > 1 or "-" in etag else binascii.hexlify(digests[0]).decode()
    got_tag = got + ("-%d" % cnt if "-" in etag else "")
    ok = got_tag == etag
    print(json.dumps({"ok": ok, "file": a.file, "size": size, "etag": etag, "computed": got_tag,
                      "part_bytes": part, "parts": cnt, "workers": a.workers, "seconds": round(dt, 3),
                      "read_gb_s": round(size / dt / 1e9, 3) if dt > 0 else None}))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
