"""Architecture diagram for gcp-landing-zone.

Renders docs/architecture.png with the official GCP icon set.

    pip install diagrams   # requires graphviz: brew install graphviz
    python3 docs/diagram.py   (from the repo root, or: make diagram)

Organized around inheritance, then the network, then the paved road. On GCP
the hierarchy is the policy surface, so the diagram's first job is to show what
governs what, and which single node relaxes an inherited rule.
"""

from diagrams import Cluster, Diagram, Edge
from diagrams.gcp.analytics import BigQuery, PubSub
from diagrams.gcp.compute import GKE, BinaryAuthorization, ComputeEngine
from diagrams.gcp.database import SQL
from diagrams.gcp.devtools import GCR
from diagrams.gcp.management import Billing, Project
from diagrams.gcp.network import DNS, NAT, VPN, FirewallRules, PrivateServiceConnect, VirtualPrivateCloud
from diagrams.gcp.operations import Logging, Monitoring
from diagrams.gcp.security import IAP, KMS, AccessContextManager, Iam, ResourceManager, SCC, SecretManager

GRAPH_ATTR = {
    "fontsize": "18",
    "labelloc": "t",
    "pad": "0.6",
    "splines": "spline",
    "nodesep": "0.5",
    "ranksep": "0.9",
    "bgcolor": "white",
}

INHERIT = {"color": "darkgreen", "style": "bold"}
OVERRIDE = {"color": "darkorange", "style": "dashed"}
FLOW = {"color": "dimgray"}
DENY = {"color": "firebrick", "style": "dashed"}

with Diagram(
    "GCP Landing Zone: hierarchy, network, paved road",
    filename="docs/architecture",
    show=False,
    direction="LR",
    graph_attr=GRAPH_ATTR,
):
    seed = Project("seed\nstate + sa-terraform\n+ GitHub WIF")

    with Cluster("Organization  (org policy + custom constraints + hierarchical firewall)"):
        org = ResourceManager("Org policy\ndeny at the root")
        workforce = Iam("Workforce pool\npersonas + PAM JIT")

        with Cluster("core"):
            logging_p = Project("logging")
            hub = VPN("net-hub 10.0/16\nDNS inbound\nHA VPN placeholder")

        with Cluster("workloads"):
            with Cluster("dev 10.1 / test 10.2"):
                devtest = Project("net-* base host\napp-* service")
            with Cluster("prod 10.3  (requires CMEK)"):
                prod_base = Project("net-prod\nbase host")
                prod_r = Project("net-prod-r\nrestricted host")
                app = Project("app-prod")

        with Cluster("sandbox 10.4  (EU widened)"):
            sandbox = Project("sandbox\nown budget")

    with Cluster("Restricted Shared VPC (inside VPC-SC perimeter)"):
        perimeter = AccessContextManager("VPC-SC\nperimeter")
        vpc = VirtualPrivateCloud("vpc-prod-restricted")
        fwp = FirewallRules("NGFW policy\ndefault-deny egress\nFQDN allowlist")
        nat = NAT("Cloud NAT")
        psc = PrivateServiceConnect("PSC vpc-sc\n10.3.255.254")
        dns = DNS("private zones\ngoogleapis / pkg.dev")
        probe = ComputeEngine("probe VM\nno external IP")
        iap = IAP("IAP SSH only")

    with Cluster("Paved road (workload root)"):
        gke = GKE("private GKE\nDPv2, WI, KMS etcd")
        binauthz = BinaryAuthorization("Binary Authorization\nKMS attestor")
        registry = GCR("Artifact Registry\nremote cache of Docker Hub")
        sql = SQL("Cloud SQL PG HA\nprivate IP, CMEK\n+ us-east1 replica")
        secret = SecretManager("DB secret\nCMEK + rotation")
        wkms = KMS("workload keys")

    with Cluster("Telemetry"):
        sink = Logging("2 org sinks\ninclude_children")
        bq = BigQuery("audit dataset\nCMEK")
        alerts = Monitoring("org-admin + CIS\nlog-metric alerts")
        scc = SCC("SCC Standard")
        topic = PubSub("findings + budget")
        tkms = KMS("telemetry key")
        budget = Billing("budgets\norg + sandbox")

    # Inheritance is the spine.
    org >> Edge(label="inherits", **INHERIT) >> devtest
    org >> Edge(**INHERIT) >> prod_r
    org >> Edge(**INHERIT) >> app
    org >> Edge(**INHERIT) >> sandbox
    org >> Edge(**INHERIT) >> logging_p
    org >> Edge(label="widens locations", **OVERRIDE) >> sandbox
    workforce >> Edge(label="folder-scope roles", style="dotted") >> app
    seed >> Edge(label="impersonation", style="dotted") >> org

    # Network ownership split from workload ownership.
    prod_r >> Edge(**FLOW) >> vpc
    app >> Edge(label="service project", style="dotted") >> vpc
    vpc >> Edge(**FLOW) >> fwp
    fwp >> Edge(label="allowlisted FQDNs", **FLOW) >> nat
    vpc >> Edge(**FLOW) >> psc
    dns >> Edge(style="dotted") >> psc
    iap >> Edge(label="tcp:22", **FLOW) >> probe
    perimeter >> Edge(**FLOW) >> vpc

    # The paved road on top.
    vpc >> Edge(**FLOW) >> gke
    registry >> Edge(label="only image source", **FLOW) >> gke
    binauthz >> Edge(label="admission", **DENY) >> gke
    gke >> Edge(label="app tier :5432 only", **FLOW) >> sql
    gke >> Edge(label="Workload Identity", **FLOW) >> secret
    wkms >> Edge(label="CMEK", style="dashed") >> sql
    wkms >> Edge(style="dashed") >> gke

    # One place for everything the org logs.
    sink >> Edge(**FLOW) >> bq
    sink >> Edge(**FLOW) >> alerts
    scc >> Edge(**FLOW) >> topic
    budget >> Edge(**FLOW) >> topic
    tkms >> Edge(label="CMEK", style="dashed") >> bq
    hub >> Edge(label="lz.internal", style="dotted") >> dns
