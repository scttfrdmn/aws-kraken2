# The manifest update of scripts/refinalise.sh: fill only unset (null or "") fields, then write
# one repair record. Arguments: see the jq call in refinalise.sh.
def unset: . == null or . == "";
def iso: sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601;

([paths(. == null or . == "")] | map(map(tostring) | join("."))) as $nulls_before
| (.stop | unset) as $stop_was_unset
| (.cost_usd == null) as $cost_was_unset
| .instance.final_state |= (if unset then null else . end)
| if $d != null then
    .instance.ami //= $d.ImageId | .instance.az //= $d.Placement.AvailabilityZone
    | .instance.launch_time //= $d.LaunchTime | .instance.architecture //= $d.Architecture
    | (if .instance.final_state == null and $state != "" then
         .instance.final_state = $state | .instance.final_state_basis = "observed" else . end)
    | .instance.terminated_at //= (if $end == "" then null else $end end)
  elif $aged and .instance.final_state == null then
    .instance.final_state = "terminated" | .instance.final_state_basis = "aged_out"
  else . end
| .task //= $rec | .preflight //= $pre | .phases //= $ph | .requests //= $rq
| .object_tags //= {ok: $tagok, line: $tagline}
| .start //= .instance.launch_time
| (if $stop_was_unset then
     (if .instance.terminated_at then "terminated_at"
      elif ($rec != null and $rec.ended_at) then "completion ended_at"
      elif $last != "" then "last phase start"
      else "unknown" end)
   else "kept" end) as $sb
| (if $stop_was_unset then
     .stop = (.instance.terminated_at // (if $rec != null then $rec.ended_at else null end)
              // (if $last == "" then null else $last end))
     | .stop_basis = $sb
   else . end)
| .billed_seconds //= (if .stop and .start then ((.stop | iso) - (.start | iso)) else null end)
| .cost_usd //= (if .billed_seconds and .truffle_price_usd_per_hour then
     ((([.billed_seconds, 60] | max) * .truffle_price_usd_per_hour / 3600) * 1e6 | round / 1e6) else null end)
| (if $cost_was_unset and .cost_usd != null then
     .cost_basis = (if $sb == "terminated_at" or $sb == "kept"
       then "on-demand truffle price x (terminated_at - launch_time), 60 s minimum; compute only, excludes EBS and S3 requests"
       else "on-demand truffle price x (\($sb) - launch_time), 60 s minimum; the instance was no longer describable, so this undercounts the shutdown (about 10-15 s); compute only, excludes EBS and S3 requests" end)
   else . end)
| .manifest_finalised_at //= $fin
| {by: "scripts/refinalise.sh", at: $fin, forced: $force, fields_unset_before: $nulls_before,
   gaps: $gaps, stop_basis: $sb, final_state_basis: .instance.final_state_basis,
   object_tags: {ok: $tagok, line: $tagline}} as $rep
| if has("manifest_repair") then .manifest_repairs = ((.manifest_repairs // []) + [$rep])
  else .manifest_repair = $rep end
