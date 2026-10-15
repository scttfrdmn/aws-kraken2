#!/usr/bin/env bash
# make test (when podman is up; skipped otherwise): scripts/stub.sh's payload GET (AK2_PAYLOAD_GET,
# docs/run.md, "The payload"), on the real stub from scripts/lib/mkstub.sh in an Amazon Linux 2023
# container under `bash -e -c`, as spawn starts it. The stand-in is only curl: it answers IMDS (the
# role's credentials included), the bucket-region HEAD and the payload GET, and logs its arguments.
#   url      the presigned URL is fetched as is, unsigned;
#   role     the GET is signed with the IMDS role credentials (--aws-sigv4 aws:amz:<region>:s3, the
#            session token header) at the in-region endpoint of AK2_PAYLOAD_URI; the payload sees
#            neither the URL nor the credentials;
#   nocreds  role with no IMDS credentials: exit 97 before any payload;
#   bogus    an unknown mode: exit 97.
# The real signing is checked against S3 by the conductor's runs (results/conductor/…); this checks
# the wiring.
set +e
set -uo pipefail
HERE=$(cd "$(dirname "$0")/../.." && pwd)
IMG=public.ecr.aws/amazonlinux/amazonlinux:2023
command -v podman > /dev/null && podman info > /dev/null 2>&1 || { echo "stub_get_test: SKIP (podman not up)"; exit 0; }
T=$(mktemp -d "${TMPDIR:-/tmp}/stub-get-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
PASS=0; FAILN=0
ok() { echo "stub_get_test: ok   $*"; PASS=$((PASS + 1)); }
bad() { echo "stub_get_test: FAIL $*"; FAILN=$((FAILN + 1)); }

(cd "$HERE" && scripts/lib/mkstub.sh) > "$T/stub.sh" || { echo "stub_get_test: mkstub failed"; exit 1; }
printf 'echo "payload ran: url=[${AK2_PAYLOAD_URL:-}] creds=[${AK2_C:-}]"\n' > "$T/payload.sh"
PSHA=$(shasum -a 256 "$T/payload.sh" | cut -d' ' -f1)
mkdir -p "$T/bin"
cat > "$T/bin/curl" <<'EOF'
#!/bin/bash
echo "curl $*" >> /out/curl.log
case " $* " in *" -K - "*) sed 's/^/stdin: /' >> /out/curl.log ;; esac
out=""; url=""; prev=""
for a in "$@"; do [ "$prev" = -o ] && out=$a; case $a in http*) url=$a ;; esac; prev=$a; done
case $url in
  *169.254.169.254*/api/token) echo tok ;;
  *meta-data/placement/region) echo us-west-2 ;;
  *meta-data/iam/security-credentials/) [ "$AK2T_CASE" = nocreds ] && exit 22; echo spawn-instance-test ;;
  *meta-data/iam/security-credentials/spawn-instance-test)
    printf '{\n  "Code" : "Success",\n  "Type" : "AWS-HMAC",\n  "AccessKeyId" : "ASIATEST",\n  "SecretAccessKey" : "SECRET/TEST+x",\n  "Token" : "TOKEN/test+==",\n  "Expiration" : "2026-10-15T09:00:00Z"\n}\n' ;;
  https://*.s3.*amazonaws.com/) printf 'HTTP/1.1 200 OK\r\nx-amz-bucket-region: us-west-2\r\n\r\n' ;;
  https://*.s3.us-west-2.amazonaws.com/*) cp /work/payload.sh "$out" ;;
  *) exit 22 ;;
esac
EOF
chmod +x "$T/bin/curl"

P=s3://ak2-results-test/aws-kraken2/g9/run-x
URL="https://ak2-results-test.s3.us-west-2.amazonaws.com/aws-kraken2/g9/run-x/payload.sh?X-Amz-Signature=abc"
case_run() {  # case_run NAME MODE: the stub in a container; OUT, RC, LOG
  mkdir -p "$T/$1"; : > "$T/$1/curl.log"
  OUT=$(podman run --rm -v "$T:/work:ro" -v "$T/$1:/out" -e PATH=/work/bin:/usr/bin:/bin -e AK2T_CASE="$1" \
    -e AK2_EXPECT_REGION=us-west-2 -e AK2_PAYLOAD_URI="$P/payload.sh" -e AK2_PAYLOAD_SHA256="$PSHA" \
    -e AK2_PAYLOAD_GET="$2" -e AK2_PAYLOAD_URL="$([ "$2" = url ] && echo "$URL")" \
    "$IMG" bash -e -c "$(cat "$T/stub.sh")" 2>&1); RC=$?
  LOG=$(cat "$T/$1/curl.log")
}
GET() { echo "$LOG" | grep 'amazonaws.com/aws-kraken2/g9/run-x/payload.sh'; }

case_run url url
[ "$RC" = 0 ] && [[ "$OUT" == *"payload ran: url=[] creds=[]"* ]] && [ "$(GET | wc -l | tr -d ' ')" = 1 ] &&
  GET | grep -qF -- "-o /tmp/ak2-payload.sh $URL" && ! GET | grep -q -- --aws-sigv4 &&
  ok "url: the presigned URL fetched unsigned; the payload ran without it" || bad "url: rc $RC: $(echo "$OUT" | tail -3) | $(GET)"
case_run role role
[ "$RC" = 0 ] && [[ "$OUT" == *"payload GET signed with role spawn-instance-test"* ]] && [[ "$OUT" == *"payload ran: url=[] creds=[]"* ]] &&
  GET | grep -qF -- '-K - --aws-sigv4 aws:amz:us-west-2:s3 -H x-amz-content-sha256: UNSIGNED-PAYLOAD -o /tmp/ak2-payload.sh https://ak2-results-test.s3.us-west-2.amazonaws.com/aws-kraken2/g9/run-x/payload.sh' &&
  ! GET | grep -qE 'ASIATEST|SECRET|TOKEN' &&
  echo "$LOG" | grep -qxF 'stdin: user = "ASIATEST:SECRET/TEST+x"' && echo "$LOG" | grep -qxF 'stdin: header = "x-amz-security-token: TOKEN/test+=="' &&
  ok "role: the GET signed with the IMDS role credentials (on stdin, not argv) at the in-region endpoint; the payload ran without them" ||
  bad "role: rc $RC: $(echo "$OUT" | tail -3) | $(GET)"
case_run nocreds role
[ "$RC" = 97 ] && [[ "$OUT" == *"no role credentials in IMDS"* ]] && [[ "$OUT" != *"payload ran"* ]] && [ -z "$(GET)" ] &&
  ok "nocreds: role with no IMDS credentials exits 97 with no GET" || bad "nocreds: rc $RC: $(echo "$OUT" | tail -3)"
case_run bogus bogus
[ "$RC" = 97 ] && [[ "$OUT" == *"AK2_PAYLOAD_GET=bogus"* ]] && [ -z "$(GET)" ] &&
  ok "bogus: an unknown mode exits 97 with no GET" || bad "bogus: rc $RC: $(echo "$OUT" | tail -3)"

echo "stub_get_test: $PASS passed, $FAILN failed"
[ "$FAILN" = 0 ]
