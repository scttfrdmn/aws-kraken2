#!/usr/bin/env bash
# make ladder-campaign-drain [REASON=...] [CAMPAIGN=<conductor run id>] / make ladder-campaign-undrain
# [CAMPAIGN=...] / scripts/g3/ladder-campaign-drain.sh status [CAMPAIGN] (docs/ladder.md, "Draining";
# docs/conductor.md, "Drain").
#
#   drain     write the drain flag. A running make ladder-campaign checks it before every launch:
#             it launches nothing more, lets the runs in flight finish and be finalised and
#             orphan-checked as normal, writes its summary and exits 4 (drained). A new campaign
#             refuses to start while it exists.
#   undrain   remove it.
#   status    say whether it is set, and what it says.
#
# Without CAMPAIGN the flag is the local file AK2_CAMPAIGN_DRAIN (default
# results/g3/ladder-campaign/DRAIN; gitignored, so it never dirties the tree run.sh checks). With
# CAMPAIGN=<conductor run id> it is the S3 object
# s3://<results bucket>/aws-kraken2/results-staging/<id>/DRAIN, which the conductor polls and copies to
# its own local flag. The flag holds one line: when, who, and the reason.
#
# Deliberately not `set -e`: every status is checked by hand.
set +e
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2
echo "ladder-campaign-drain: shell flags $-" >&2
MODE=${1:-}; CAMPAIGN=${2:-}; REASON=${3:-}
die() { echo "ladder-campaign-drain: $*" >&2; exit 2; }
case "$MODE" in drain|undrain|status) ;; *) die "usage: ladder-campaign-drain.sh drain|undrain|status [CAMPAIGN] [REASON]" ;; esac
LINE="drained_at=$(date -u +%Y-%m-%dT%H:%M:%SZ) by=$(id -un 2>/dev/null)@$(hostname 2>/dev/null) reason=${REASON:-none given}"

if [ -z "$CAMPAIGN" ]; then
  F=${AK2_CAMPAIGN_DRAIN:-results/g3/ladder-campaign/DRAIN}
  case "$MODE" in
    drain)
      mkdir -p "$(dirname "$F")" || die "cannot create $(dirname "$F")"
      if [ -e "$F" ]; then echo "ladder-campaign-drain: already set: $F: $(head -1 "$F")"; exit 0; fi
      printf '%s\n' "$LINE" > "$F" || die "cannot write $F"
      echo "ladder-campaign-drain: set $F ($LINE). A running campaign launches nothing more and exits 4 once its runs in flight are recorded." ;;
    undrain)
      [ -e "$F" ] || { echo "ladder-campaign-drain: not set ($F)"; exit 0; }
      rm -f "$F" || die "cannot remove $F"
      echo "ladder-campaign-drain: cleared $F" ;;
    status)
      if [ -e "$F" ]; then echo "ladder-campaign-drain: SET: $F: $(head -1 "$F")"; else echo "ladder-campaign-drain: not set ($F)"; fi ;;
  esac
  exit 0
fi

# The conductor's flag, in S3.
[[ "$CAMPAIGN" =~ ^[0-9]{8}-[0-9]{6}-[0-9a-f]{7}$ ]] || die "CAMPAIGN=$CAMPAIGN is not a conductor run id (<yyyymmdd-hhmmss>-<sha7>)"
# shellcheck source=/dev/null
. scripts/ak2.env
export AWS_PROFILE
command -v aws >/dev/null || die "aws not on PATH"
URI="s3://$AK2_RESULTS_BUCKET_us_west_2/$AK2_RESULTS_ROOT/results-staging/$CAMPAIGN/DRAIN"
case "$MODE" in
  drain)
    printf '%s\n' "$LINE" | aws s3 cp --only-show-errors --region us-west-2 - "$URI" || die "could not write $URI"
    echo "ladder-campaign-drain: set $URI ($LINE). The conductor copies it to its local flag within ${AK2_CONDUCTOR_DRAIN_POLL_S:-30} s." ;;
  undrain)
    aws s3 rm --only-show-errors --region us-west-2 "$URI" || die "could not remove $URI"
    echo "ladder-campaign-drain: cleared $URI (a conductor that already drained has exited; this only lets a new campaign under that id start)" ;;
  status)
    if L=$(aws s3 cp --only-show-errors --region us-west-2 "$URI" - 2>/dev/null); then echo "ladder-campaign-drain: SET: $URI: $L"
    else echo "ladder-campaign-drain: not set ($URI)"; fi ;;
esac
exit 0
