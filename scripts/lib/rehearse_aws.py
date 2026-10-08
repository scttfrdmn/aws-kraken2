#!/usr/bin/env python3
"""Stub `aws` for make rehearse (scripts/lib/e1_rehearse.sh): the s3api subset the E1 spec
body and the engine's CLI store use, on the same directory layout as objstore.Dir (and so as
the FakeS3 the SDK path talks to): <AK2T_FAKE>/<bucket>/<key>, multipart uploads under
<AK2T_FAKE>/.uploads/<id>/{target,part-NNNNN}. Not for AWS.

Environment: AK2T_FAKE (the bucket root), AK2T_HASH_BUCKET/AK2T_HASH_KEY/AK2T_HASH_FILE/
AK2T_HASH_ETAG (the object head-object answers for, standing in for RODA's hash.k2d),
AK2T_LOG (every call is appended).
"""
import hashlib, json, os, sys, time

root = os.environ["AK2T_FAKE"]
args = sys.argv[1:]
with open(os.environ.get("AK2T_LOG", "/dev/null"), "a") as lg:
    lg.write(" ".join(args) + "\n")


def opt(name, default=None):
    if name in args:
        return args[args.index(name) + 1]
    return default


flags = {"--no-sign-request", "--only-show-errors"}
pos = []
i = 0
while i < len(args):
    a = args[i]
    if a in flags:
        i += 1
    elif a.startswith("--"):
        i += 2
    else:
        pos.append(a)
        i += 1
if args[:1] == ["--version"]:
    print("aws-cli/rehearse-stub")
    sys.exit(0)
if len(pos) >= 3 and pos[0] == "s3" and pos[1] == "cp":
    # s3 cp s3://bucket/key LOCAL (the hash object from AK2T_HASH_FILE), or LOCAL s3://bucket/key.
    import shutil
    src, dst = pos[2], pos[3]
    def split(u):
        b, _, k = u[len("s3://"):].partition("/")
        return b, k
    if src.startswith("s3://"):
        b, k = split(src)
        f = os.environ["AK2T_HASH_FILE"] if (b == os.environ.get("AK2T_HASH_BUCKET") and k == os.environ.get("AK2T_HASH_KEY")) \
            else os.path.join(root, b, k)
        if not os.path.exists(f):
            print(f"fatal error: An error occurred (404) when calling the HeadObject operation: Key \"{k}\" does not exist", file=sys.stderr)
            sys.exit(1)
        shutil.copyfile(f, dst)
    else:
        b, k = split(dst)
        os.makedirs(os.path.dirname(os.path.join(root, b, k)), exist_ok=True)
        shutil.copyfile(src, os.path.join(root, b, k))
    sys.exit(0)
if len(pos) < 2 or pos[0] != "s3api":
    sys.exit(f"rehearse aws stub: unsupported: {' '.join(args)}")
op = pos[1]
bucket, key = opt("--bucket"), opt("--key")
# The instance role (AK2T_ROLE=instance): spawn's grant with s3_read_write is GetObject,
# GetObjectVersion, PutObject (multipart included), DeleteObject, ListBucket and
# GetBucketLocation; not ListBucketVersions, not AbortMultipartUpload (docs/run.md).
if os.environ.get("AK2T_ROLE") == "instance" and op in ("list-object-versions", "abort-multipart-upload"):
    perm = {"list-object-versions": "s3:ListBucketVersions", "abort-multipart-upload": "s3:AbortMultipartUpload"}[op]
    print(f"An error occurred (AccessDenied) when calling the {op} operation: not authorized to perform: {perm}", file=sys.stderr)
    sys.exit(254)
path = lambda b, k: os.path.join(root, b, k)
up = lambda uid: os.path.join(root, ".uploads", uid)


def die(code, msg):
    print(f"An error occurred ({code}) when calling the {op} operation: {msg}", file=sys.stderr)
    sys.exit(254)


if op == "head-object":
    if bucket == os.environ.get("AK2T_HASH_BUCKET") and key == os.environ.get("AK2T_HASH_KEY"):
        size = os.path.getsize(os.environ["AK2T_HASH_FILE"])
        h = {"ETag": '"' + os.environ["AK2T_HASH_ETAG"] + '"', "ContentLength": size}
    else:
        p = path(bucket, key)
        if not os.path.exists(p):
            die("404", "Not Found")
        data = open(p, "rb").read()
        h = {"ETag": '"' + hashlib.md5(data).hexdigest() + '"', "ContentLength": len(data),
             "Metadata": {"sha256": hashlib.sha256(data).hexdigest(), "md5": hashlib.md5(data).hexdigest()}}
    if opt("--query") == "Metadata.sha256":
        print(h.get("Metadata", {}).get("sha256", "None"))
    elif opt("--query") == "ETag":
        print(h["ETag"])
    else:
        print(json.dumps(h))
elif op == "put-object":
    data = open(opt("--body"), "rb").read() if opt("--body") else b""
    os.makedirs(os.path.dirname(path(bucket, key)), exist_ok=True)
    open(path(bucket, key), "wb").write(data)
    print(json.dumps({"ETag": '"' + hashlib.md5(data).hexdigest() + '"'}))
elif op == "get-object":
    p = path(bucket, key)
    if not os.path.exists(p):
        die("NoSuchKey", "The specified key does not exist.")
    data = open(p, "rb").read()
    open(pos[2], "wb").write(data)
    print(json.dumps({"ContentLength": len(data)}))
elif op == "create-multipart-upload":
    uid = f"c{os.getpid()}-{time.time_ns()}"
    os.makedirs(up(uid))
    open(os.path.join(up(uid), "target"), "w").write(f"{bucket}/{key}")
    print(json.dumps({"UploadId": uid}))
elif op == "upload-part":
    uid, n = opt("--upload-id"), int(opt("--part-number"))
    if open(os.path.join(up(uid), "target")).read() != f"{bucket}/{key}":
        die("NoSuchUpload", uid)
    data = open(opt("--body"), "rb").read()
    open(os.path.join(up(uid), f"part-{n:05d}"), "wb").write(data)
    print(json.dumps({"ETag": f'"etag-{n}-{len(data)}"'}))
elif op == "complete-multipart-upload":
    uid = opt("--upload-id")
    spec = json.load(open(opt("--multipart-upload")[len("file://"):]))
    out, last = b"", 0
    parts = spec["Parts"]
    for j, p in enumerate(parts):
        n = p["PartNumber"]
        if n <= last:
            die("InvalidPartOrder", "parts not ascending")
        last = n
        data = open(os.path.join(up(uid), f"part-{n:05d}"), "rb").read()
        if p["ETag"].strip('"') != f"etag-{n}-{len(data)}":
            die("InvalidPart", f"part {n} ETag")
        if j < len(parts) - 1 and len(data) < 5 << 20:
            die("EntityTooSmall", f"part {n}")
        out += data
    os.makedirs(os.path.dirname(path(bucket, key)), exist_ok=True)
    open(path(bucket, key), "wb").write(out)
    for f in os.listdir(up(uid)):
        os.remove(os.path.join(up(uid), f))
    os.rmdir(up(uid))
    print(json.dumps({"Bucket": bucket, "Key": key}))
elif op == "abort-multipart-upload":
    uid = opt("--upload-id")
    if os.path.isdir(up(uid)):
        for f in os.listdir(up(uid)):
            os.remove(os.path.join(up(uid), f))
        os.rmdir(up(uid))
elif op in ("list-object-versions", "list-objects-v2"):
    prefix = opt("--prefix", "")
    base = os.path.join(root, bucket)
    rows = []
    for d, _, fs in os.walk(base):
        for f in fs:
            k = os.path.relpath(os.path.join(d, f), base)
            if k.startswith(prefix):
                data = open(os.path.join(d, f), "rb").read()
                rows.append((k, '"' + hashlib.md5(data).hexdigest() + '"', len(data)))
    for k, e, n in sorted(rows):
        print(f"{k}\t{e}\t{n}")
else:
    sys.exit(f"rehearse aws stub: unsupported s3api {op}")
