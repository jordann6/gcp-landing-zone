#!/usr/bin/env bash
# FinOps report from the billing export views (bootstrap/finops.tf), plus
# Recommender's idle-resource findings for every active landing-zone project.
#
#   Spend         net cost this month and last, by project and by service
#   Chargeback    net cost by cost_center; "untagged" is spend nobody owns
#   Coverage      share of net cost carrying a cost_center label
#   Anomalies     project x service days over 2x their trailing 7-day average
#   Idle          Recommender: idle VMs, disks and external IPs
#
# Runs as you (the seed project's owner). Never prints the billing account ID.

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

F="$(tfjson bootstrap finops)"
P="$(jq -r .project <<<"$F")"
EXPORT="$(jq -r .export_dataset <<<"$F")"
TABLE="$(jq -r .export_table <<<"$F")"
VIEWS="$(jq -r .views_dataset <<<"$F")"
q() { bq query --project_id="$P" --use_legacy_sql=false --format=pretty --quiet "$1" 2>&1; }

section "Billing export"
if ! bq show --format=none "$P:$EXPORT.$TABLE" >/dev/null 2>&1; then
	echo "  the export table does not exist yet. One-time console step (no API exists):"
	echo "  Billing > Billing export > BigQuery export > Standard usage cost > Edit settings,"
	echo "  project $P, dataset $EXPORT. Then: terraform -chdir=bootstrap apply -var enable_billing_views=true"
	exit 1
fi
ROWS="$(bq query --project_id="$P" --use_legacy_sql=false --format=csv --quiet "SELECT COUNT(*) FROM \`$P.$EXPORT.$TABLE\`" | tail -1)"
echo "  export table present, $ROWS rows"
bq show --format=none "$P:$VIEWS.cost_daily" >/dev/null 2>&1 || { echo "  views missing: terraform -chdir=bootstrap apply -var enable_billing_views=true"; exit 1; }

section "Spend by project, this month and last"
q "SELECT invoice_month, project_id, ROUND(SUM(net_cost), 2) AS net_cost FROM \`$P.$VIEWS.cost_daily\`
   WHERE invoice_month >= FORMAT_DATE('%Y%m', DATE_SUB(CURRENT_DATE(), INTERVAL 1 MONTH))
   GROUP BY 1, 2 HAVING net_cost != 0 ORDER BY 1 DESC, 3 DESC LIMIT 30"

section "Top services, last 30 days"
q "SELECT service, ROUND(SUM(net_cost), 2) AS net_cost FROM \`$P.$VIEWS.cost_daily\`
   WHERE day >= DATE_SUB(CURRENT_DATE(), INTERVAL 30 DAY) GROUP BY 1 HAVING net_cost != 0 ORDER BY 2 DESC LIMIT 10"

section "Chargeback by cost_center"
q "SELECT * FROM \`$P.$VIEWS.cost_by_label\` WHERE net_cost != 0 ORDER BY invoice_month DESC, net_cost DESC LIMIT 20"

section "Label coverage"
q "SELECT * FROM \`$P.$VIEWS.label_coverage\` ORDER BY invoice_month DESC LIMIT 3"

section "Anomalies, last 30 days"
q "SELECT * FROM \`$P.$VIEWS.cost_anomalies\` WHERE day >= DATE_SUB(CURRENT_DATE(), INTERVAL 30 DAY) ORDER BY day DESC, net_cost DESC LIMIT 20"

section "Idle resources (Recommender)"
REGION="${REGION:-us-central1}"
N=0
for proj in $(gcloud projects list --filter='labels.project=gcp-landing-zone AND lifecycleState=ACTIVE' --format='value(projectId)' 2>/dev/null); do
	for spec in "google.compute.instance.IdleResourceRecommender|$REGION-a $REGION-b $REGION-c $REGION-f" \
		"google.compute.disk.IdleResourceRecommender|$REGION-a $REGION-b $REGION-c $REGION-f" \
		"google.compute.address.IdleResourceRecommender|$REGION global"; do
		rec="${spec%%|*}"
		for loc in ${spec#*|}; do
			out="$(gcloud recommender recommendations list --project="$proj" --location="$loc" --recommender="$rec" \
				--format='value(description,primaryImpact.costProjection.cost.units)' 2>/dev/null)"
			[ -n "$out" ] && { printf '  %s %s: %s\n' "$proj" "$loc" "$out"; N=$((N + 1)); }
		done
	done
done
[ "$N" = 0 ] && echo "  no idle-resource recommendations in active landing-zone projects"
