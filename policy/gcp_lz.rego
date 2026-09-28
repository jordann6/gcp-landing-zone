# Repo-local conftest rules, layered on the shared platform-guardrails suite.
#
# The shared suite covers what every GCP repo should hold (no internet-open
# firewall rules, no SA keys, no external IPs, labels). These are the landing
# zone's own invariants: the things the org policies and custom constraints
# enforce at the API, caught one step earlier at the pull request, so a
# violation fails review instead of failing an apply halfway through.

package main

import rego.v1

# Duplicated from the shared helpers so this directory also runs on its own
# (make policy-fixture). Identical definitions merge cleanly in OPA.
blocks_of(v) := v if {
	is_array(v)
}

blocks_of(v) := [v] if {
	is_object(v)
}

resources contains r if {
	some file in input
	some type, named in file.contents.resource
	some name, block in named
	some body in blocks_of(block)
	r := {"type": type, "name": name, "body": body, "path": file.path}
}

deny contains msg if {
	some r in resources
	r.type == "google_project"
	r.body.auto_create_network == true
	msg := sprintf("%s: google_project.%s sets auto_create_network = true. The default VPC ships permissive rules nobody chose.", [r.path, r.name])
}

deny contains msg if {
	some r in resources
	r.type == "google_compute_network"
	r.body.auto_create_subnetworks == true
	msg := sprintf("%s: google_compute_network.%s is auto mode, which creates a subnet in every region with fixed ranges.", [r.path, r.name])
}

deny contains msg if {
	some r in resources
	r.type == "google_compute_subnetwork"
	not r.body.private_ip_google_access
	msg := sprintf("%s: google_compute_subnetwork.%s does not enable private_ip_google_access.", [r.path, r.name])
}

deny contains msg if {
	some r in resources
	r.type == "google_compute_subnetwork"
	not r.body.log_config
	msg := sprintf("%s: google_compute_subnetwork.%s has no flow logs (CIS 3.8).", [r.path, r.name])
}

# ---- GKE paved road -----------------------------------------------------------

deny contains msg if {
	some r in resources
	r.type == "google_container_cluster"
	not r.body.workload_identity_config
	msg := sprintf("%s: google_container_cluster.%s has no workload_identity_config.", [r.path, r.name])
}

deny contains msg if {
	some r in resources
	r.type == "google_container_cluster"
	not r.body.database_encryption
	msg := sprintf("%s: google_container_cluster.%s does not envelope-encrypt secrets with Cloud KMS.", [r.path, r.name])
}

deny contains msg if {
	some r in resources
	r.type == "google_container_cluster"
	not r.body.binary_authorization
	msg := sprintf("%s: google_container_cluster.%s has no binary_authorization block.", [r.path, r.name])
}

deny contains msg if {
	some r in resources
	r.type == "google_container_cluster"
	some pcc in blocks_of(r.body.private_cluster_config)
	pcc.enable_private_nodes != true
	msg := sprintf("%s: google_container_cluster.%s does not use private nodes.", [r.path, r.name])
}

deny contains msg if {
	some r in resources
	r.type == "google_container_node_pool"
	some nc in blocks_of(r.body.node_config)
	not nc.service_account
	msg := sprintf("%s: google_container_node_pool.%s runs as the default Compute SA (roles/editor).", [r.path, r.name])
}

deny contains msg if {
	some r in resources
	r.type == "google_container_node_pool"
	some nc in blocks_of(r.body.node_config)
	some wmc in blocks_of(nc.workload_metadata_config)
	wmc.mode != "GKE_METADATA"
	msg := sprintf("%s: google_container_node_pool.%s exposes node metadata to pods.", [r.path, r.name])
}

# ---- data tier -------------------------------------------------------------------

deny contains msg if {
	some r in resources
	r.type == "google_sql_database_instance"
	not r.body.encryption_key_name
	msg := sprintf("%s: google_sql_database_instance.%s has no CMEK. The prod folder rejects it at the API.", [r.path, r.name])
}

deny contains msg if {
	some r in resources
	r.type == "google_sql_database_instance"
	not r.body.master_instance_name
	some st in blocks_of(r.body.settings)
	some bc in blocks_of(st.backup_configuration)
	bc.enabled != true
	msg := sprintf("%s: google_sql_database_instance.%s disables backups.", [r.path, r.name])
}

deny contains msg if {
	some r in resources
	r.type == "google_sql_database_instance"
	some st in blocks_of(r.body.settings)
	some ipc in blocks_of(st.ip_configuration)
	ipc.ssl_mode != "ENCRYPTED_ONLY"
	ipc.ssl_mode != "TRUSTED_CLIENT_CERTIFICATE_REQUIRED"
	msg := sprintf("%s: google_sql_database_instance.%s allows unencrypted connections.", [r.path, r.name])
}

deny contains msg if {
	some r in resources
	r.type == "google_secret_manager_secret"
	some rep in blocks_of(r.body.replication)
	rep.auto
	msg := sprintf("%s: google_secret_manager_secret.%s uses automatic replication, which cannot carry a regional CMEK.", [r.path, r.name])
}
