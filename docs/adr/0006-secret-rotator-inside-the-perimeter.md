# ADR-0006: Secret rotator inside the perimeter, single-user rotation

- **Status:** accepted
- **Date:** 2026-11-18

## Context

Secret Manager publishes `SECRET_ROTATE` on a schedule but rotates nothing.
Until now the notification fired and `set-db-password.sh` did the work by
hand. The rotator has to read from the rotation topic in the prod app project,
which is inside the VPC-SC perimeter, and call two restricted APIs, Secret
Manager and the Cloud SQL Admin API.

Two documented VPC-SC limits decide where it can run. A Pub/Sub subscription
has to be in the same perimeter as its topic, and a new push subscription
inside a perimeter can only push to a Cloud Run endpoint
([supported products](https://cloud.google.com/vpc-service-controls/docs/supported-products)).

## Decision

Run the rotator on Cloud Run in the app project, next to the topic, with a
same-project push subscription. All egress goes through the restricted Shared
VPC (Direct VPC egress, `ALL_TRAFFIC`), where `*.googleapis.com` resolves to
the PSC endpoint, so its API calls stay inside the perimeter and no ingress
rule is needed. Rotate one Cloud SQL user. Set the password in Cloud SQL
first, then add the version, then disable the older versions.

## Alternatives rejected

| Option | Why not |
| ------ | ------- |
| Run it in the logging project like the incident handler, with an ingress rule | The subscription would sit outside the topic's perimeter, which VPC-SC refuses without an egress rule for Pub/Sub too. Two perimeter exceptions instead of zero |
| Default Cloud Run egress, no VPC | The Cloud Run VPC-SC guide requires services in a perimeter to route all egress through a VPC. Default egress is the path it says not to rely on |
| Two alternating users, as in the AWS zone | Closes the gap where a connection opens between the password change and the new version, at the cost of a second user, a grant script and app logic that picks the current user. Cloud SQL keeps open sessions across a password change, so the gap only affects new connections in a window of a few seconds |
| Add the version first, then set the password | A reader in that window gets a password the database does not accept yet. Setting Cloud SQL first means the newest version always works |

## Consequences

- If adding the version fails after the password changed, the handler returns
  500 and Pub/Sub redelivers. The redelivery finds no version newer than the
  message and rotates again, so the two converge.
- The rotator never holds `secretAccessor`. It can write and retire versions,
  never read one.
- Revisit if a workload holds long-lived connection pools that reconnect in
  bulk, which makes the single-user window matter. Then alternate users.
