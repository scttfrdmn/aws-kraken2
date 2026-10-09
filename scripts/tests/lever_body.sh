# shellcheck shell=bash disable=SC2015,SC2319  # checks read the $? of a test; A && B || C is meant
# The spec body of make lever-test (scripts/tests/lever_test.sh appends it to scripts/preamble.sh
# and runs the payload in AL2023 under `bash -e -c`, as spawn starts a body). LVT_CASE picks the
# case: main (everything must work), refuse (lv_s5 must refuse undeclared buckets and `run`),
# fail (failures must be surfaced: return codes and the run's exit status). Each check is a line
# "ok|FAIL<TAB>name<TAB>detail" in /work/out/$LVT_CASE.checks; the driver reads them, the pushed
# run.log, lever.jsonl, requests.tsv and helper-errors.tsv.
W=/tmp/ak2; mkdir -p "$W"
O=/work/out/$LVT_CASE.checks; : > "$O"
chk() {
  local n=$1 c=$2; shift 2
  if [ "$c" = 0 ]; then printf 'ok\t%s\t%s\n' "$n" "$*" >> "$O"; else printf 'FAIL\t%s\t%s\n' "$n" "$*" >> "$O"; fi
}
# want_rc NAME WANT GOT DETAIL
want_rc() { [ "$3" = "$2" ]; chk "$1" $? "rc $3 (want $2) $4"; }
now() { date +%s.%3N; }
# le A B: A <= B as numbers.
le() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a <= b)}'; }
lt() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a < b)}'; }
# reqs PHASE OP: the sum of OP's counts in PHASE (requests.tsv).
reqs() { awk -F'\t' -v p="$1" -v o="$2" '$1 == p && $2 == o {s += $3} END {print s + 0}' /tmp/ak2-requests.tsv; }
# row SEQ COL: a column of this session's row SEQ in uploads.tsv (the last such row).
# row SEQ COL MODE
row() { awk -F'\t' -v s="$1" -v c="$2" -v m="$3" 'NR > 1 && $1 == s && $2 == m {v = $c} END {print v}' "$LV_DIR/uploads.tsv"; }
sha() { sha256sum "$1" | cut -d' ' -f1; }
BK=/work/bucket
cd /repo || exit 1
. scripts/g3/lever.sh
chk lever-loaded $? "LV_DIR=$LV_DIR; \$-=$-"

case $LVT_CASE in
main)
  ak2_phase nvme
  lv_nvme raid /mnt/nvme; want_rc nvme 0 $? "LV_NVME=$LV_NVME"
  [ "$LV_NVME" = "$AK2_REHEARSE_NVME" ]; chk nvme-seam $? "LV_NVME=$LV_NVME"

  # ---- the database: the stock aws CLI as shipped, the classic client, s5cmd; ETag each as its own phase ----
  ak2_phase stage-default
  # A config the body happens to have exported must not reach the stock rung's CLI.
  printf '[default]\ns3 =\n  preferred_transfer_client = crt\n' > /tmp/body.config; export AWS_CONFIG_FILE=/tmp/body.config
  lv_stage_db awscp-default s3://ak2-roda-test/db/ "$LV_NVME/db-default"; want_rc stage-default 0 $?
  unset AWS_CONFIG_FILE
  n=$(awk -F'\t' '$2 == "get" && $3 ~ /db\/hash.k2d$/ && $4 ~ /db-default/ && $5 == ""' "$BK/.aws-calls.$LVT_CASE" | wc -l)
  [ "$n" = 1 ]; chk stage-default-no-override $? "$n hash.k2d get(s) by aws s3 cp with no AWS_CONFIG_FILE (the body's crt config removed for the call)"
  grep -q '"kind":"aws-client","t":[0-9.]*,"client":"default","cli_version":"aws-cli/stub","config":"none","content":"","caller_config":"/tmp/body.config","configure_get":"","instance_type":"t.test","resolved":"unknown","how":"could not determine: ' "$LV_DIR/lever.jsonl"
  chk stage-default-client-recorded $? "$(grep '"client":"default"' "$LV_DIR/lever.jsonl" | head -1)"
  g=$(reqs stage-default GetObject); h=$(reqs stage-default HeadObject)
  [ "$g" = 5 ] && [ "$h" = 9 ]; chk stage-default-requests $? "GetObject $g (want 5), HeadObject $h (want 9)"
  lv_etag "$LV_NVME/db-default/hash.k2d" "$(lv_db_etag "$LV_NVME/db-default" hash.k2d)"; want_rc etag-default 0 $?
  # The auto rule against AL2023's real aws CLI rpm (in the image; the stub stands in for it above).
  how=$(lv__auto_rule /usr/bin/aws); r=${how%%$'\t'*}; how=${how#*$'\t'}
  [ "$r" = classic ] && [[ $how == auto:\ awscrt.s3.is_optimized_for_system* ]]
  chk auto-rule-real-cli $? "$(/usr/bin/aws --version 2>&1 | cut -d' ' -f1): $r ($how; a container is not a CRT-optimised type)"
  ak2_phase stage-classic
  lv_stage_db awscp-classic s3://ak2-roda-test/db/ "$LV_NVME/db-classic"; want_rc stage-classic 0 $?
  ET=$(lv_db_etag "$LV_NVME/db-classic" hash.k2d)
  [[ $ET == *-3 ]]; chk stage-classic-etag-recorded $? "hash.k2d etag $ET (multipart, 3 parts)"
  n=$(awk -F'\t' '$2 == "get" && $3 ~ /db\/hash.k2d$/ && $5 == "preferred_transfer_client=classic"' "$BK/.aws-calls.$LVT_CASE" | wc -l)
  [ "$n" = 1 ]; chk stage-classic-config $? "$n hash.k2d get(s) by aws s3 cp under a config with preferred_transfer_client=classic"
  grep -q '"kind":"aws-client","t":[0-9.]*,"client":"classic",.*"content":"\[default\]\\ns3 =\\n  preferred_transfer_client = classic".*"configure_get":"classic",.*"resolved":"classic","how":"configured"' "$LV_DIR/lever.jsonl"
  chk stage-classic-client-recorded $? "$(grep '"client":"classic"' "$LV_DIR/lever.jsonl" | head -1)"
  lv_etag "$LV_NVME/db-classic/hash.k2d" "$ET"; want_rc etag-classic 0 $?
  [ "$(cat /tmp/ak2-state/phase)" = etag-hash.k2d ]; chk etag-own-phase $? "phase $(cat /tmp/ak2-state/phase)"
  ak2_phase stage-s5cmd
  mkdir -p /tmp/tmpfs
  lv_stage_db s5cmd s3://ak2-roda-test/db/ /tmp/tmpfs/db-s5; want_rc stage-s5cmd 0 $?
  grep -q $'\t--no-sign-request --numworkers 256 cp --concurrency 128 --part-size 64 s3://ak2-roda-test/db/hash.k2d /tmp/tmpfs/db-s5/hash.k2d$' "$BK/.s5-calls.$LVT_CASE"
  chk stage-s5cmd-flags $? "s5cmd called with probe (a)'s flags, anonymous after the signed head-object was refused"
  lv_etag /tmp/tmpfs/db-s5/hash.k2d "$(lv_db_etag /tmp/tmpfs/db-s5 hash.k2d)"; want_rc etag-s5cmd 0 $?
  for f in opts.k2d taxo.k2d hash.k2d; do
    cmp -s "$BK/ak2-roda-test/db/$f" "$LV_NVME/db-default/$f" && cmp -s "$BK/ak2-roda-test/db/$f" "$LV_NVME/db-classic/$f" && cmp -s "$BK/ak2-roda-test/db/$f" "/tmp/tmpfs/db-s5/$f"
    chk "stage-identical-$f" $?
  done
  HS=$(stat -c%s /tmp/tmpfs/db-s5/hash.k2d)
  g=$(reqs stage-classic GetObject); h=$(reqs stage-classic HeadObject)
  # hash.k2d 3 x 8 MiB GETs, opts and taxo 1 each; per file 2 head-objects (signed refused, then
  # anonymous) and the cp's own.
  [ "$g" = 5 ] && [ "$h" = 9 ]; chk stage-classic-requests $? "GetObject $g (want 5), HeadObject $h (want 9); hash.k2d $HS bytes"
  g=$(reqs stage-s5cmd GetObject); h=$(reqs stage-s5cmd HeadObject)
  [ "$g" = 3 ] && [ "$h" = 9 ]; chk stage-s5cmd-requests $? "GetObject $g (want 3: one 64 MiB part per file), HeadObject $h (want 9)"

  # ---- inputs: serial and lanes with the stock client (S6 varies the lanes only), and crt; all sha256-checked ----
  ak2_phase fetch-serial
  lv_fetch_inputs serial default /tmp/in-serial /work/manifest.txt; want_rc fetch-serial 0 $?
  ak2_phase fetch-lanes
  lv_fetch_inputs lanes3 default "$LV_NVME/in-lanes" /work/manifest.txt; want_rc fetch-lanes3 0 $?
  ak2_phase fetch-crt
  lv_fetch_inputs lanes2 crt /tmp/in-crt /work/manifest.txt; want_rc fetch-lanes2-crt 0 $?
  n0=$(awk -F'\t' '$2 == "get" && $4 ~ /in-(serial|lanes)\// && $5 == ""' "$BK/.aws-calls.$LVT_CASE" | wc -l)
  n1=$(awk -F'\t' '$2 == "get" && $4 ~ /in-crt\// && $5 == "preferred_transfer_client=crt"' "$BK/.aws-calls.$LVT_CASE" | wc -l)
  [ "$n0" = 12 ] && [ "$n1" = 6 ]; chk fetch-client $? "$n0 of 12 serial/lanes gets with no config (default), $n1 of 6 under the crt config"
  grep -q '"kind":"aws-client","t":[0-9.]*,"client":"crt",.*"configure_get":"crt",.*"resolved":"crt","how":"configured"' "$LV_DIR/lever.jsonl"; chk fetch-crt-recorded $?
  bad=0
  while read -r u; do
    case $u in '#'*|'') continue ;; esac
    f=${u##*/}
    [ "$(sha "/tmp/in-serial/$f")" = "$(cat "$BK/.meta/ak2-data-test/cohort/$f.sha256")" ] &&
      cmp -s "/tmp/in-serial/$f" "$LV_NVME/in-lanes/$f" && cmp -s "/tmp/in-serial/$f" "/tmp/in-crt/$f" || bad=$((bad + 1))
  done < /work/manifest.txt
  chk fetch-identical "$bad" "$bad files differ from their sha256 or between serial and lanes"
  # Lane concurrency, from the stub's get intervals: serial never overlaps, lanes3 does.
  ov() { python3 -c '
import sys
iv = [tuple(map(float, l.split("\t")[5:7])) for l in open(sys.argv[1]) if l.split("\t")[1] == "get" and sys.argv[2] in l.split("\t")[3]]
ev = sorted([(a, 1) for a, b in iv] + [(b, -1) for a, b in iv])
c = m = 0
for _, d in ev:
    c += d; m = max(m, c)
print(m)' "$BK/.aws-calls.$LVT_CASE" "$1"; }
s=$(ov /tmp/in-serial/); l=$(ov "$LV_NVME/in-lanes/")
  [ "$s" = 1 ] && [ "$l" -ge 2 ]; chk fetch-lane-concurrency $? "max concurrent gets: serial $s (want 1), lanes3 $l (want >= 2)"
  g=$(reqs fetch-serial GetObject); h=$(reqs fetch-serial HeadObject)
  [ "$g" = 6 ] && [ "$h" = 12 ]; chk fetch-requests $? "serial GetObject $g (want 6), HeadObject $h (want 12)"
  grep -q '"kind":"fetch-inputs","t":[0-9.]*,"mode":"lanes3","lanes":3,"dest":"/tmp/nvme/in-lanes",.*"client":"default","client_env":"env -u AWS_CONFIG_FILE"' "$LV_DIR/lever.jsonl"
  chk fetch-recorded $?

  # ---- the gunzip shim ----
  ak2_phase gunzip
  mkdir -p /tmp/gz
  python3 - << 'PY'
import random
r = random.Random(50)
for m, n in ((1, 120000), (2, 90000)):
    with open(f"/tmp/gz/r_{m}.fq", "w") as f:
        for i in range(n):
            s = "".join(r.choices("ACGTN", k=150))
            q = "".join(r.choices("!\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHI", k=150))
            f.write(f"@SRR0000000.{i} {i}/{m}\n{s}\n+\n{q}\n")
PY
  gzip -6 -n -c /tmp/gz/r_1.fq > /tmp/gz/r_1.fq.gz
  # Mate 2 as a multi-member gz (two members concatenated), as some archives are.
  head -n 200000 /tmp/gz/r_2.fq | gzip -6 -n -c > /tmp/gz/r_2.fq.gz
  tail -n +200001 /tmp/gz/r_2.fq | gzip -1 -n -c >> /tmp/gz/r_2.fq.gz
  REALGZ=$(command -v gzip)
  declare -A REF
  for m in 1 2; do REF[$m]=$("$REALGZ" -dc "/tmp/gz/r_$m.fq.gz" | sha256sum | cut -d' ' -f1); done
  [ "${REF[1]}" = "$(sha /tmp/gz/r_1.fq)" ] && [ "${REF[2]}" = "$(sha /tmp/gz/r_2.fq)" ]; chk gunzip-reference $? "gzip -dc reproduces the fq"
  lv_gunzip_shim rapidgzip-P4; want_rc gunzip-shim 0 $?
  [ "$(command -v gzip)" = "$LV_DIR/gzbin/gzip" ]; chk gunzip-shim-on-path $? "$(command -v gzip)"
  for m in 1 2; do
    h=$(gzip -dc "/tmp/gz/r_$m.fq.gz" | sha256sum | cut -d' ' -f1)
    [ "$h" = "${REF[$m]}" ]; chk "gunzip-identical-mate$m" $? "shim $h vs gzip -dc ${REF[$m]} ($(stat -c%s "/tmp/gz/r_$m.fq.gz") gz bytes)"
    # As upstream's kraken2 wrapper opens it: perl open "gzip -dc FILE |" (PATH lookup through sh).
    h=$(perl -e 'open(my $f, "gzip -dc $ARGV[0] |") or die; binmode $f; binmode STDOUT; print while <$f>; close $f or die "rc $?"' "/tmp/gz/r_$m.fq.gz" | sha256sum | cut -d' ' -f1)
    [ "$h" = "${REF[$m]}" ]; chk "gunzip-identical-mate$m-via-perl-open" $? "$h"
  done
  n=$(awk -F'\t' '$2 == "rapidgzip"' "$LV_DIR/gzip-shim.calls" | wc -l)
  [ "$n" = 4 ]; chk gunzip-shim-used-rapidgzip $? "$n rapidgzip calls (want 4)"
  gzip --version > /dev/null; n=$(awk -F'\t' '$2 == "gzip"' "$LV_DIR/gzip-shim.calls" | wc -l)
  [ "$n" = 1 ]; chk gunzip-shim-passthrough $? "gzip --version went to the real gzip ($n call)"
  grep -q '"kind":"gunzip-shim".*"threads":4.*"rapidgzip_version":"rapidgzip, [^"]*version 0.14.5' "$LV_DIR/lever.jsonl"; chk gunzip-shim-recorded $?
  lv_gunzip_shim gzip; want_rc gunzip-off 0 $?
  [ "$(command -v gzip)" = "$REALGZ" ]; chk gunzip-off-path $? "$(command -v gzip)"

  # ---- uploads: serial, then overlapped ----
  head -c 3145728 /dev/urandom > /tmp/up1; head -c 10485760 /dev/urandom > /tmp/up2
  ak2_phase upload-default
  lv_upload_start awscp-default; want_rc upload-start-default 0 $?
  lv_upload_enqueue /tmp/up1 s3://ak2-results-test/lvt/$LVT_CASE/up/default-1; want_rc upload-enqueue-default 0 $?
  lv_upload_drain; want_rc upload-drain-default 0 $?
  n=$(awk -F'\t' '$2 == "put" && $4 ~ /up\/default-1$/ && $5 == ""' "$BK/.aws-calls.$LVT_CASE" | wc -l)
  [ "$n" = 1 ] && [ -n "$(row 1 9 awscp-default)" ]; chk upload-default-no-override $? "$n put(s) with no AWS_CONFIG_FILE"
  ak2_phase upload-serial
  lv_upload_start awscp-serial; want_rc upload-start-serial 0 $? "(the first contract's name for awscp-classic)"
  ta=$(now); lv_upload_enqueue /tmp/up1 s3://ak2-results-test/lvt/$LVT_CASE/up/serial-1; r=$?; tb=$(now)
  want_rc upload-enqueue-serial 0 "$r"
  lv_upload_enqueue /tmp/up2 s3://ak2-results-test/lvt/$LVT_CASE/up/serial-2; want_rc upload-enqueue-serial-2 0 $?
  lv_upload_drain; want_rc upload-drain-serial 0 $?
  n=$(awk -F'\t' '$2 == "put" && $4 ~ /up\/serial-[12]$/ && $5 == "preferred_transfer_client=classic"' "$BK/.aws-calls.$LVT_CASE" | wc -l)
  [ "$n" = 2 ]; chk upload-classic-config $? "$n of 2 puts under the classic config, recorded as awscp-classic"
  e1=$(row 1 9 awscp-classic)
  le "$e1" "$tb"; chk upload-serial-blocks $? "serial enqueue returned at $tb, after its upload ended at $e1 (the contrast: the probe resolves blocking)"
  [ "$(reqs upload-serial PutObject)" = 1 ] && [ "$(reqs upload-serial UploadPart)" = 2 ] && [ "$(reqs upload-serial CreateMultipartUpload)" = 1 ]
  chk upload-serial-requests $? "PutObject $(reqs upload-serial PutObject) UploadPart $(reqs upload-serial UploadPart) (want 1 and 2: 3 MiB single, 10 MiB in 8 MiB parts)"

  ak2_phase upload-overlap
  lv_upload_start s5cmd-overlap; want_rc upload-start-overlap 0 $?
  ta=$(now); lv_upload_enqueue /tmp/up1 s3://ak2-results-test/lvt/$LVT_CASE/up/overlap-1; r=$?; tb=$(now)
  want_rc upload-enqueue-overlap 0 "$r"
  w0=$(now); sleep 3; w1=$(now)       # the body's next work, while upload 1 runs
  lv_upload_enqueue /tmp/up2 s3://ak2-results-test/lvt/$LVT_CASE/up/overlap-2; want_rc upload-enqueue-overlap-2 0 $?
  td=$(now); lv_upload_drain; r=$?; tdd=$(now)
  want_rc upload-drain-overlap 0 "$r"
  s1=$(row 1 8 s5cmd-overlap); e1=$(row 1 9 s5cmd-overlap); s2=$(row 2 8 s5cmd-overlap); e2=$(row 2 9 s5cmd-overlap)
  lt "$tb" "$e1" && lt "$(awk -v a="$ta" -v b="$tb" 'BEGIN{print b - a}')" 1
  chk upload-overlap-enqueue-returns $? "enqueue $ta -> $tb returned before upload 1 ended ($e1)"
  lt "$s1" "$w1" && le "$e1" "$w1"
  chk upload-overlap-by-timestamps $? "upload 1 ran $s1 -> $e1, inside the body's work $w0 -> $w1"
  le "$e1" "$s2"; chk upload-overlap-order $? "upload 2 ($s2) started after upload 1 ended ($e1): one lane, enqueue order"
  le "$e2" "$tdd"; chk upload-overlap-drain-waits $? "drain returned at $tdd after upload 2 ended at $e2"
  grep -q '"kind":"upload-drain".*"mode":"s5cmd-overlap".*"overlap_s":[2-9]' "$LV_DIR/lever.jsonl"; chk upload-overlap-recorded $?
  [ "$(reqs upload-overlap PutObject)" = 2 ]; chk upload-overlap-requests $? "PutObject $(reqs upload-overlap PutObject) (want 2: both below s5cmd's 64 MiB part)"
  # The sha256: recorded at enqueue (before the upload started), equal to the file's and the object's.
  bad=0
  for m in awscp-classic s5cmd-overlap; do
    for q in 1 2; do
      l=$(row "$q" 3 "$m"); u=$(row "$q" 4 "$m"); h=$(row "$q" 6 "$m"); st=$(row "$q" 8 "$m")
      te=$(grep '"kind":"upload-enqueue"' "$LV_DIR/lever.jsonl" | grep "\"mode\":\"$m\"" | grep "\"url\":\"$u\"" | sed -E 's/.*"sha256":"([0-9a-f]+)".*/\1/' | tail -1)
      tt=$(grep '"kind":"upload-enqueue"' "$LV_DIR/lever.jsonl" | grep "\"url\":\"$u\"" | sed -E 's/^\{"kind":"upload-enqueue","t":([0-9.]+).*/\1/' | tail -1)
      { [ "$h" = "$(sha "$l")" ] && [ "$te" = "$h" ] && [ "$h" = "$(sha "$BK/${u#s3://}")" ] && le "$tt" "$st"; } || { bad=$((bad + 1)); echo "sha256 check: $m $q $l $u row=$h enq=$te at $tt start $st"; }
    done
  done
  chk upload-sha256-recorded "$bad" "$bad of 4 uploads lack a matching sha256 recorded before the upload"

  # ---- lv_s5 lets a declared bucket through ----
  ak2_phase s5-guard
  lv_s5 ls s3://ak2-results-test/lvt/$LVT_CASE/up/ > /tmp/ls.out; want_rc s5-allowed 0 $? "$(wc -l < /tmp/ls.out) objects listed"
  [ "$(reqs s5-guard s5cmd-ls)" = 1 ]; chk s5-counted $? "s5cmd-ls $(reqs s5-guard s5cmd-ls)"
  ;;

refuse)
  ak2_phase refuse
  lv_s5 ls s3://ak2-undeclared-test/x/; want_rc refuse-ls 126 $?
  lv_s5 cp /etc/hostname s3://ak2-undeclared-test/k; want_rc refuse-upload 126 $?
  lv_s5 --numworkers 8 cp s3://ak2-results-test/a s3://ak2-undeclared-test/b; want_rc refuse-mixed 126 $?
  lv_s5 cp --metadata x=s3://ak2-undeclared-test/z /etc/hostname s3://ak2-results-test/k; want_rc refuse-embedded 126 $?
  printf 'ls s3://ak2-results-test/\n' > /tmp/cmds; lv_s5 run /tmp/cmds; want_rc refuse-run 126 $?
  [ ! -s "$BK/.s5-calls.$LVT_CASE" ]; chk refuse-never-reached-s5cmd $? "$(head -3 "$BK/.s5-calls.$LVT_CASE" 2>&1 | tr '\n\t' '; ')"
  n=$(grep -c '"kind":"s5","t":[0-9.]*,"args":.*"refused":true' "$LV_DIR/lever.jsonl"); [ "$n" = 5 ]; chk refuse-recorded $? "$n refusals recorded"
  # The guard cannot be redefined by the body.
  ( eval 'lv_s5() { :; }' ) 2> /dev/null; [ $? != 0 ]; chk refuse-guard-readonly $?
  lv_upload_start s5cmd-overlap; lv_upload_enqueue /etc/hostname s3://ak2-undeclared-test/k; want_rc refuse-enqueue 1 $?
  lv_upload_drain; want_rc refuse-drain-empty 0 $?
  ;;

fail)
  ak2_phase fail
  head -c 1000 /dev/urandom > /tmp/x.bin
  lv_etag /tmp/x.bin 0123456789abcdef0123456789abcdef; want_rc fail-etag 1 $?
  lv_fetch_inputs lanes2 default /tmp/in-bad /work/manifest-bad.txt; want_rc fail-fetch 1 $?
  lv_fetch_inputs lanes2 bogus /tmp/in-bad2 /work/manifest.txt; want_rc fail-fetch-client 1 $?
  grep -q '"kind":"fetch-inputs".*"files":3,"verified":2' "$LV_DIR/lever.jsonl"; chk fail-fetch-recorded $?
  lv_upload_start s5cmd-overlap
  lv_upload_enqueue /tmp/x.bin s3://ak2-results-test/lvt/$LVT_CASE/up/ok-1; want_rc fail-enqueue-ok 0 $?
  lv_upload_enqueue /tmp/x.bin s3://ak2-results-test/lvt/$LVT_CASE/up/FAILME-2; want_rc fail-enqueue-bad 0 $? "(the failure is the lane's)"
  lv_upload_enqueue /tmp/x.bin s3://ak2-results-test/lvt/$LVT_CASE/up/ok-3; want_rc fail-enqueue-ok-3 0 $?
  lv_upload_drain; want_rc fail-drain 1 $?
  [ -f "$BK/ak2-results-test/lvt/$LVT_CASE/up/ok-3" ]; chk fail-lane-continues $? "the lane went on past the failed upload"
  lv_stage_db awscp-crt s3://ak2-roda-test/db/ /tmp/db; want_rc fail-bad-mode 1 $?
  lv_gunzip_shim rapidgzip-P0; want_rc fail-bad-shim 1 $?
  lv_upload_enqueue /tmp/x.bin s3://ak2-results-test/lvt/$LVT_CASE/up/late; want_rc fail-no-session 1 $?
  ;;
esac
ak2_phase finished
exit 0
