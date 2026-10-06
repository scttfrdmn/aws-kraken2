#!/usr/bin/env bash
# make report GATE=<gate> RUN=<run-id> -- render a markdown issue comment from
# results/<gate>/<run-id>/ only. It takes no other input, so a number that is not in those
# files cannot appear in the report. See docs/report.md.
set -uo pipefail
ROOT=$(git rev-parse --show-toplevel) || exit 2
cd "$ROOT" || exit 2
GATE=${1:-}; RUN=${2:-}
die() { echo "make report: $*" >&2; exit 2; }
[ -n "$GATE" ] && [ -n "$RUN" ] || die "usage: make report GATE=<gate> RUN=<run-id>"
D="results/$GATE/$RUN"
M="$D/manifest.json"
[ -s "$M" ] || die "$M not found"
jq -e . "$M" >/dev/null || die "$M is not valid JSON"
[ -n "$(jq -r '.manifest_finalised_at // empty' "$M")" ] || die "$M was never finalised (run still in progress or aborted)"

m() { jq -r "($1) | if . == null then \"—\" else tostring end" "$M"; }
tsv_md() { # tsv file -> markdown table, at most 60 rows
  awk -F'\t' 'NR==1{h="|"; s="|"; for(i=1;i<=NF;i++){h=h" "$i" |"; s=s"---|"}; print h; print s; next}
    NR<=61{r="|"; for(i=1;i<=NF;i++){r=r" "$i" |"}; print r}
    END{if(NR>61) printf "\n_%d of %d rows shown; full table in the file._\n", 60, NR-1}' "$1"
}
json_md() { # flat JSON object -> two-column table
  echo "| field | value |"; echo "|---|---|"
  jq -r 'to_entries[] | "| \(.key) | \(.value | if type=="array" then (if length==0 then "[]" else join(", ") end) else tostring end) |"' "$1"
}

cat <<EOF
### ${GATE} — run \`${RUN}\`

| | |
|---|---|
| commit | \`$(m .commit)\` (tree dirty: $(m .tree_dirty)) |
| upstream pin | \`$(m .upstream.pin)\` |
| spec | \`$(m .spec)\` (sha256 \`$(m .spec_sha256 | cut -c1-12)\`) |
| instance | $(m .instance.count) × \`$(m .instance.type)\` ($(m .instance.lifecycle)), AMI \`$(m .instance.ami)\` |
| region / AZ | $(m .region) / $(m .instance.az) |
| truffle price at launch | \$$(m .truffle_price_usd_per_hour)/h |
| start → stop | $(m .start) → $(m .stop) ($(m .billed_seconds) s) |
| cost | \$$(m .cost_usd) — $(m .cost_basis) |
| TTL / cost_limit | $(m .ttl) / \$$(m .cost_limit_usd) |
| task | state $(m .task.state), exit $(m .task.exit_code), retry_class "$(m .task.retry_class)" |
| shell flags | inherited \`$(m .preflight.inherited_flags)\`, after \`set +e\` \`$(m .preflight.flags_after_set)\` |
| preflight region | $(m .preflight.region) (asserted == every bucket's region before I/O) |
| sample accessions | $(jq -r 'if (.sample_accessions|length)==0 then "none" else .sample_accessions|join(", ") end' "$M") |
| tools | spawn $(m .tools.spawn), truffle $(m .tools.truffle) |

**Bucket Payer**

| bucket | payer (launch host) | payer (instance) |
|---|---|---|
$(jq -r '.bucket_payer[] as $b | "| \($b.bucket) | \($b.payer) | \(([(.preflight.buckets // [])[] | select(.bucket==$b.bucket) | .payer] | first) // "—") |"' "$M")

**Datasets (head-object at launch)**

| object | size (bytes) | ETag | VersionId | LastModified |
|---|---|---|---|---|
$(jq -r '.datasets[] | "| \(.uri) | \(.size) | `\(.etag)` | \(.version_id // "null") | \(.last_modified) |"' "$M")
EOF

for f in "$D"/decoded/*.json; do
  [ -f "$f" ] || continue
  printf '\n**%s**\n\n' "${f#"$D"/}"
  json_md "$f"
done
for f in "$D"/tables/*.tsv; do
  [ -f "$f" ] || continue
  printf '\n**%s**\n\n' "${f#"$D"/}"
  tsv_md "$f"
done

printf '\n<details><summary>Files in %s</summary>\n\n| file | bytes | sha256 |\n|---|---|---|\n' "$D"
(cd "$D" && find . -type f ! -name '.*' | sed 's|^\./||' | sort | while read -r f; do
  printf '| %s | %s | `%s` |\n' "$f" "$(wc -c < "$f" | tr -d ' ')" "$(shasum -a 256 "$f" | cut -c1-16)"
done)
printf '\n</details>\n\n_Rendered by `make report GATE=%s RUN=%s` from `%s/` only._\n' "$GATE" "$RUN" "$D"
