# ADR-0009: SLO in the app project; billing export in the seed project

- **Status:** accepted
- **Date:** 2026-11-18

## Context

The Azure zone pages on burn rate with managed Prometheus. This zone had
threshold alerts and budgets but no SLO and no cost analytics. Cost analytics
on GCP means the Cloud Billing export to BigQuery, which can only be turned on
in the console, with no API, gcloud or Terraform path
([setup](https://cloud.google.com/billing/docs/how-to/export-data-bigquery-setup)).

## Decision

Put the orders-api Cloud Run service, its custom service, its request-based
SLO (2xx over all, 99% over 28 days) and its burn-rate policies in the app
project with the metric, with an email channel of their own, since an alert
policy can only notify channels in its own project. Page on burn above 14.4x
over 1 hour and 5 minutes, and ticket on 6x over 6 hours and 30 minutes.

Put the billing export dataset and the cost views in the seed project, the
only project that is never destroyed, and gate the views until the export
table exists.

## Alternatives rejected

| Option | Why not |
| ------ | ------- |
| The SLO in the logging (scoping) project | The service and SLO would be one project away from the data they measure, which is exactly where a filter quietly matches nothing |
| A single-window burn alert | Pages late on a fast burn or stays open long after the fault is gone. The paired windows do neither |
| The billing dataset in the logging project | That project is destroyed every session, and an export pointed at a deleted dataset stops without telling anyone |
| A Cloud Billing API pull into a custom store | Reimplements the export, less completely |

## Consequences

- One manual console step, recorded in `bootstrap/finops.tf` and checked by
  `scripts/finops-report.sh`, which names the step when the table is missing.
- Billing data lands with a lag of hours, so a session cannot prove its own
  cost the same day. The report proves the views on the history already there.
- orders-api accepts only an identity token for `sa-terraform`. Nothing binds
  `allUsers`, so the SLO load comes from an authenticated client.
