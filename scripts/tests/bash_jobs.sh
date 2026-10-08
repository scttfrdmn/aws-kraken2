#!/bin/bash
# The bash job-control check (run inside AL2023 by scripts/bash-jobs-test.sh; make bash-jobs-test).
# It rebuilds the shape a spec body runs in: started as `bash -c`, with the preamble's EXIT, TERM,
# HUP, INT and PIPE traps, a FIFO tee and a push loop in the background (scripts/preamble.sh) and
# finished process substitutions. Then, under a watchdog of LIMIT seconds each:
#   1. the body's fetch loop at 8a6dbe6 (bare wait -n): it must FAIL here (hang or error), which
#      shows the check can resolve the defect class;
#   2. the body's fetch at 1a4dbfe (wait -n -p over a PID list): reported;
#   3. the real scripts/g3/fetch.sh (the current fetch: a child process, lanes waited for by PID)
#      on N stub files through a stub aws: it must PASS (every file fetched and verified, exit 0).
#   4. lanes in the body's own shell waited for by PID (U1's u1_pass): it must PASS.
# Prints one "bash-jobs: ..." line per pattern; exits 0 only if 1 failed and 3 and 4 passed.
set +e
trap 'true' EXIT; trap 'true' TERM; trap 'true' HUP; trap 'true' INT; trap 'true' PIPE
N=${N:-600}; LIMIT=${LIMIT:-60}; REPO=${REPO:-/repo}; OUTF=${OUTF:-/o/bash-jobs.txt}
D=$(mktemp -d); mkfifo "$D/fifo"
( trap '' TERM HUP; exec tee -a "$D/log" ) < "$D/fifo" > /dev/null &
exec > "$D/fifo" 2>&1
( while sleep 1; do cp "$D/log" "$D/log.pushed" 2>/dev/null; done ) > /dev/null 2>&1 &
mapfile -t A < <(seq 1 3)
mapfile -t B < <(seq 1 5)
say() { echo "bash-jobs: $*" >> "$D/r"; }
say "bash $BASH_VERSION; started as bash -c: ${BASH_EXECUTION_STRING:+yes}; N=$N; limit ${LIMIT}s per pattern"
# Watchdog: after LIMIT seconds, USR1 every second (a trapped signal ends a blocked wait).
HUNG=0
trap 'HUNG=1' USR1
watch() { ( sleep "$LIMIT"; while kill -USR1 $$ 2>/dev/null; do sleep 1; done ) > /dev/null 2>&1 & WD=$!; }
unwatch() { kill "$WD" 2>/dev/null; }
work() { sleep "0.0$((RANDOM % 9 + 1))"; x=$(echo x); echo "item $1 $x"; }
items=(); for i in $(seq 1 "$N"); do items+=("$i"); done

# 1. bare wait -n
HUNG=0; watch
RUNNING=0; FERR=0
for it in "${items[@]}"; do work "$it" >> "$D/f1" 2>&1 & RUNNING=$((RUNNING + 1)); if [ "$RUNNING" -ge 8 ]; then wait -n || FERR=1; RUNNING=$((RUNNING - 1)); fi; done
while [ "$RUNNING" -gt 0 ] && [ "$HUNG" = 0 ]; do wait -n || FERR=1; RUNNING=$((RUNNING - 1)); done
unwatch
P1=pass; { [ "$FERR" != 0 ] || [ "$HUNG" = 1 ]; } && P1=fail
say "1 bare wait -n (8a6dbe6): $P1 (error=$FERR hung=$HUNG left=$RUNNING items=$(grep -c item "$D/f1"))"

# 2. wait -n -p over a PID list
HUNG=0; watch
POOL=(); FERR=0
pool_wait1() { local d="" rc p keep=(); wait -n -p d "${POOL[@]}" 2>>"$D/e2"; rc=$?; for p in "${POOL[@]}"; do [ "$p" = "$d" ] || keep+=("$p"); done; POOL=("${keep[@]}"); return "$rc"; }
for it in "${items[@]}"; do work "$it" >> "$D/f2" 2>&1 & POOL+=($!); if [ "${#POOL[@]}" -ge 8 ]; then pool_wait1 || FERR=1; fi; [ "$HUNG" = 1 ] && break; done
while [ "${#POOL[@]}" -gt 0 ] && [ "$HUNG" = 0 ]; do pool_wait1 || FERR=1; done
unwatch
P2=pass; { [ "$FERR" != 0 ] || [ "$HUNG" = 1 ]; } && P2=fail
say "2 wait -n -p pool (1a4dbfe): $P2 (error=$FERR hung=$HUNG left=${#POOL[@]} items=$(grep -c item "$D/f2") no-such-job=$(grep -c 'no such job' "$D/e2" 2>/dev/null))"

# 3. the real scripts/g3/fetch.sh through a stub aws
mkdir -p "$D/bin" "$D/src/b/k" "$D/dst"
for i in "${items[@]}"; do head -c $((1000 + i)) /dev/urandom > "$D/src/b/k/f$i"; done
cat > "$D/bin/aws" <<EOF
#!/bin/bash
# s3 cp s3://b/k/F DST | s3api head-object --bucket b --key k/F --query Metadata.sha256 --output text
case "\$1 \$2" in
  "s3 cp") for a in "\$@"; do case "\$a" in s3://*) s=\${a#s3://} ;; esac; done; d=\${@: -1}; sleep "0.0\$((RANDOM % 9 + 1))"; cp "$D/src/\$s" "\$d" ;;
  "s3api head-object") k=; while [ \$# -gt 0 ]; do [ "\$1" = --key ] && k=\$2; shift; done; sha256sum "$D/src/b/\$k" | cut -d' ' -f1 ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$D/bin/aws"
files=(); for i in "${items[@]}"; do files+=("f$i"); done
HUNG=0; watch
PATH="$D/bin:$PATH" "$REPO/scripts/g3/fetch.sh" b k "$D/dst" 8 "${files[@]}" > "$D/f3" 2>&1 & FP=$!
wait "$FP"; rc=$?
unwatch
ok=$(grep -vc ERROR "$D/f3")
P3=pass; { [ "$rc" != 0 ] || [ "$HUNG" = 1 ] || [ "$ok" != "$N" ]; } && P3=fail
say "3 scripts/g3/fetch.sh (current): $P3 (rc=$rc hung=$HUNG verified=$ok of $N)"
# 4. U1's P x T passes (scripts/g3/u1.body.sh u1_pass): lanes in the body's own shell, each waited
# for by PID.
HUNG=0; watch
pids=(); : > "$D/f4"
for ((l = 0; l < 12; l++)); do
  ( r=0; for ((i = l; i < N; i += 12)); do work "${items[$i]}" >> "$D/f4" || r=1; done; exit "$r" ) &
  pids+=($!)
done
FERR=0; for p in "${pids[@]}"; do wait "$p" || FERR=1; done
unwatch
P4=pass; { [ "$FERR" != 0 ] || [ "$HUNG" = 1 ] || [ "$(grep -c item "$D/f4")" != "$N" ]; } && P4=fail
say "4 in-shell lanes waited by PID (U1's u1_pass): $P4 (error=$FERR hung=$HUNG items=$(grep -c item "$D/f4"))"
V=fail; [ "$P1" = fail ] && [ "$P3" = pass ] && [ "$P4" = pass ] && V=pass
say "verdict: $V (the check resolves the defect: pattern 1 must fail; the current fetch must pass)"
cp "$D/r" "$OUTF"
[ "$V" = pass ]
