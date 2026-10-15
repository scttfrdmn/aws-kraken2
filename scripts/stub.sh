# aws-kraken2 user-data stub (scripts/run.sh puts this, not the preamble, in command[2]).
# EC2 caps user data at 16384 bytes after base64 decoding, and spawn's own bootstrap uses about
# 10.4 KB of that, already gzipped, so precompressing the payload gains nothing. The full payload
# (scripts/preamble.sh + the spec body) therefore travels via the run's in-region results
# prefix, uploaded by run.sh before launch and fetched here with a presigned URL for that one
# object (no IAM grant needed), or under the conductor with this instance's role (below). This stub keeps Law 4's order: $- first, set +e, the region
# assert before any I/O, then one GET, a sha256 check, and exec. The sampler reads only /proc and
# /sys (and runs ethtool -S once), so it starts ahead of the assert.
AK2_STUB_FLAGS="$-"
set +e
# The utilisation sampler first, before any I/O (docs/run.md, "Utilisation"): run.sh splices
# scripts/util-sampler.sh in at the marker (scripts/lib/mkstub.sh); double-forked, so no shell's
# bare `wait` waits for it, with no inherited stdio.
cat > /tmp/ak2-util.sh <<'AK2UTIL'
#@AK2_UTIL_SAMPLER@
AK2UTIL
( bash /tmp/ak2-util.sh loop "$$" < /dev/null > /dev/null 2>&1 & )
echo "ak2-stub: inherited \$-=$AK2_STUB_FLAGS"
AK2_T=$(curl -sf -X PUT -m 5 http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 300')
AK2_R=$(curl -sf -m 5 -H "X-aws-ec2-metadata-token: $AK2_T" http://169.254.169.254/latest/meta-data/placement/region)
AK2_PB=${AK2_PAYLOAD_URI#s3://}; AK2_PB=${AK2_PB%%/*}
AK2_PBR=$(curl -sI -m 10 "https://$AK2_PB.s3.$AK2_R.amazonaws.com/" | tr -d '\r' | awk -F': ' 'tolower($1)=="x-amz-bucket-region"{print $2}')
echo "ak2-stub: imds region=$AK2_R expected=$AK2_EXPECT_REGION payload bucket $AK2_PB region=$AK2_PBR"
if [ -z "$AK2_R" ] || [ "$AK2_R" != "$AK2_EXPECT_REGION" ] || [ "$AK2_PBR" != "$AK2_R" ]; then
  echo "ak2-stub: FATAL: region assert failed before any I/O"; exit 97
fi
# AK2_PAYLOAD_GET (scripts/run.sh): url, the presigned GET; role, signed here with this instance's
# role credentials from IMDS (the conductor's presigned URLs carry a session token too long for user data).
AK2_EP="https://$AK2_PB.s3.$AK2_R.amazonaws.com/"
case "${AK2_PAYLOAD_GET:-url}" in
  url)
    case "$AK2_PAYLOAD_URL" in "$AK2_EP"*) ;; *) echo "ak2-stub: FATAL: payload URL is not the in-region endpoint of $AK2_PB"; exit 97 ;; esac
    curl -sf -m 60 --retry 3 -o /tmp/ak2-payload.sh "$AK2_PAYLOAD_URL" ;;
  role)
    AK2_I=http://169.254.169.254/latest/meta-data/iam/security-credentials/
    for AK2_N in 1 2 3 4 5 6 7 8 9 10; do
      AK2_RN=$(curl -sf -m 5 -H "X-aws-ec2-metadata-token: $AK2_T" "$AK2_I") &&
        AK2_C=$(curl -sf -m 5 -H "X-aws-ec2-metadata-token: $AK2_T" "$AK2_I$AK2_RN") && break
      sleep 3
    done
    ak2_c() { printf '%s\n' "$AK2_C" | sed -n "s/.*\"$1\" *: *\"\([^\"]*\)\".*/\1/p"; }
    [ -n "$(ak2_c AccessKeyId)" ] || { echo "ak2-stub: FATAL: no role credentials in IMDS for the payload GET"; exit 97; }
    echo "ak2-stub: payload GET signed with role $AK2_RN"
    # The credentials go in on stdin (-K -), not in argv, which /proc shows to every process.
    printf 'user = "%s:%s"\nheader = "x-amz-security-token: %s"\n' "$(ak2_c AccessKeyId)" "$(ak2_c SecretAccessKey)" "$(ak2_c Token)" |
      curl -sf -m 60 --retry 3 -K - --aws-sigv4 "aws:amz:$AK2_R:s3" -H "x-amz-content-sha256: UNSIGNED-PAYLOAD" \
        -o /tmp/ak2-payload.sh "$AK2_EP${AK2_PAYLOAD_URI#s3://$AK2_PB/}"
    ;;
  *) echo "ak2-stub: FATAL: AK2_PAYLOAD_GET=$AK2_PAYLOAD_GET"; exit 97 ;;
esac || { echo "ak2-stub: FATAL: could not fetch $AK2_PAYLOAD_URI"; exit 97; }
AK2_SUM=$(sha256sum /tmp/ak2-payload.sh | cut -d' ' -f1)
[ "$AK2_SUM" = "$AK2_PAYLOAD_SHA256" ] ||
  { echo "ak2-stub: FATAL: payload sha256 $AK2_SUM != $AK2_PAYLOAD_SHA256"; exit 97; }
echo "ak2-stub: payload verified (sha256 $AK2_SUM); exec"
export AK2_STUB_FLAGS
unset AK2_PAYLOAD_URL AK2_C   # credentials; the payload has no use for them
# bash -c, exactly as spawn ran the inlined script before (same parsing, same $- semantics).
exec bash -c "$(cat /tmp/ak2-payload.sh)"
