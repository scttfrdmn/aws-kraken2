#!/usr/bin/env python3
"""The S3 ETag the engine would give a local file, so upstream's local outputs can be compared
with the engine's s3:// outputs without downloading them (Law 1 on a real cohort).

  ak2etag.py output FILE...   the engine's --output writer (internal/objstore/writer.go): empty ->
                              one PutObject (plain md5); else a multipart upload whose part n is
                              min(8 MiB << ((n - 1) // 1000), 5 GiB) bytes (the last part the rest);
                              ETag = md5(concat(md5(part))) + "-" + parts
  ak2etag.py report FILE...   one PutObject: the plain md5

Prints "<etag>\t<size>\t<file>" per file, the ETag in quotes as S3 lists it.
"""
import hashlib, os, sys

MIB = 1 << 20


def part_size(n):
    return min((8 * MIB) << ((n - 1) // 1000), 5 << 30)


def etag(path, kind):
    size = os.path.getsize(path)
    with open(path, "rb") as f:
        if kind == "report" or size == 0:
            h = hashlib.md5()
            for b in iter(lambda: f.read(8 * MIB), b""):
                h.update(b)
            return f'"{h.hexdigest()}"', size
        digests, n = [], 1
        while True:
            want = part_size(n)
            h, got = hashlib.md5(), 0
            while got < want:
                b = f.read(min(8 * MIB, want - got))
                if not b:
                    break
                h.update(b)
                got += len(b)
            if got == 0:
                break
            digests.append(h.digest())
            n += 1
            if got < want:
                break
        return f'"{hashlib.md5(b"".join(digests)).hexdigest()}-{len(digests)}"', size


if __name__ == "__main__":
    kind = sys.argv[1]
    if kind not in ("output", "report"):
        sys.exit(__doc__)
    for p in sys.argv[2:]:
        e, s = etag(p, kind)
        print(f"{e}\t{s}\t{p}")
