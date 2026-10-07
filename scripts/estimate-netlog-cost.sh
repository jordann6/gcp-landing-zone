#!/usr/bin/env bash
# Estimate the monthly ingestion cost of routing VPC flow logs and firewall logs
# to the central log bucket, from the bytes those logs wrote in the last 24h.
# Run this BEFORE setting enable_network_log_sink = true in terraform/.
#
# Cloud Logging ingestion is $0.50/GiB after the first 50 GiB per project per
# month. The central bucket is one project, so the estimate is the summed
# volume of every host project, less one 50 GiB allotment.

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

PRICE_PER_GIB="0.50"
FREE_GIB=50

TOKEN="$(gcloud auth print-access-token "$IMP" 2>/dev/null)"
SEED="$(tfout bootstrap seed_project_id)"
HOSTS="$(terraform -chdir="$ROOT/terraform" output -json host_projects | jq -r '.[].project_id')"

END="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
START="$(date -u -v-24H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ)"

total=0
for p in $HOSTS; do
	echo "== $p (last 24h)"
	resp="$(curl -s -G -H "Authorization: Bearer $TOKEN" -H "x-goog-user-project: $SEED" \
		"https://monitoring.googleapis.com/v3/projects/${p}/timeSeries" \
		--data-urlencode 'filter=metric.type="logging.googleapis.com/byte_count"' \
		--data-urlencode "interval.startTime=$START" --data-urlencode "interval.endTime=$END" \
		--data-urlencode 'aggregation.alignmentPeriod=86400s' \
		--data-urlencode 'aggregation.perSeriesAligner=ALIGN_SUM' \
		--data-urlencode 'aggregation.crossSeriesReducer=REDUCE_SUM' \
		--data-urlencode 'aggregation.groupByFields=metric.label.log')"
	if ! jq -e . >/dev/null 2>&1 <<<"$resp" || jq -e .error >/dev/null 2>&1 <<<"$resp"; then
		echo "  query failed: ${resp:0:300}"
		continue
	fi
	while IFS=$'\t' read -r log bytes; do
		case "$log" in
		*vpc_flows* | *firewall*)
			printf '  %-45s %12.1f MiB\n' "$log" "$(awk -v b="$bytes" 'BEGIN{print b/1048576}')"
			total="$(awk -v t="$total" -v b="$bytes" 'BEGIN{print t+b}')"
			;;
		esac
	done < <(jq -r '.timeSeries[]? | [.metric.labels.log, (.points[0].value.int64Value // "0")] | @tsv' <<<"$resp")
done

awk -v b="$total" -v price="$PRICE_PER_GIB" -v free="$FREE_GIB" 'BEGIN {
	day = b / 1073741824; month = day * 30; paid = month - free; if (paid < 0) paid = 0
	printf "\nFlow + firewall logs: %.3f GiB/day, about %.1f GiB/month\n", day, month
	printf "Estimated ingestion cost at $%.2f/GiB after %d GiB free: $%.2f/month\n", price, free, paid * price
}'
