"""Architecture diagram for gcp-landing-zone.

Renders docs/architecture.png using the official GCP icon set.

    pip install diagrams   # requires graphviz: brew install graphviz
    python diagram.py

Organized around inheritance rather than around data flow. On GCP the hierarchy
is the policy surface, so the diagram's job is to show what governs what, and
which single node relaxes an inherited rule.
"""

from diagrams import Cluster, Diagram, Edge
from diagrams.gcp.analytics import BigQuery, PubSub
from diagrams.gcp.management import Billing, Project
from diagrams.gcp.network import FirewallRules, VirtualPrivateCloud
from diagrams.gcp.operations import Logging
from diagrams.gcp.security import KMS, ResourceManager, SCC

GRAPH_ATTR = {
    "fontsize": "16",
    "labelloc": "t",
    "pad": "0.6",
    "splines": "spline",
    "nodesep": "0.6",
    "ranksep": "1.0",
    "bgcolor": "transparent",
}

INHERIT = {"color": "darkgreen", "style": "bold", "label": "inherits"}
OVERRIDE = {"color": "darkorange", "style": "dashed"}
FLOW = {"color": "dimgray"}

with Diagram(
    "GCP Landing Zone",
    filename="docs/architecture",
    show=False,
    direction="LR",
    graph_attr=GRAPH_ATTR,
):
    with Cluster("Organization"):
        org = ResourceManager("Org policy\n9 constraints enforced")

        with Cluster("core"):
            net_proj = Project("network\nShared VPC host")
            log_proj = Project("logging")

        with Cluster("workloads"):
            with Cluster("nonprod"):
                nonprod = Project("app-nonprod")
                override = ResourceManager("resourceLocations\nwidened to EU")

            with Cluster("prod"):
                prod = Project("app-prod")

    with Cluster("Shared VPC"):
        vpc = VirtualPrivateCloud("shared-vpc\nno auto subnets")
        fw = FirewallRules("deny all ingress\nIAP SSH only")

    with Cluster("Telemetry"):
        sink = Logging("Org sink\ninclude_children")
        dataset = BigQuery("org_audit_logs\n30d partitions")
        scc = SCC("Security Command\nCenter Standard")
        topic = PubSub("findings\n+ budget alerts")
        key = KMS("One key\nrevokes both")

    budget = Billing("Budget\nactual + forecast")

    # Policy inheritance is the spine of the design.
    org >> Edge(**INHERIT) >> net_proj
    org >> Edge(**INHERIT) >> log_proj
    org >> Edge(**INHERIT) >> prod
    org >> Edge(**INHERIT) >> nonprod
    override >> Edge(label="overrides", **OVERRIDE) >> nonprod

    # Network ownership is split from workload ownership.
    net_proj >> Edge(**FLOW) >> vpc
    vpc >> Edge(**FLOW) >> fw
    nonprod >> Edge(label="service project", style="dotted") >> vpc
    prod >> Edge(label="service project", style="dotted") >> vpc

    # Everything logs to one place, including projects created later.
    sink >> Edge(label="every project", **FLOW) >> dataset
    log_proj >> Edge(style="dotted") >> dataset
    scc >> Edge(label="active findings", **FLOW) >> topic
    budget >> Edge(label="50 / 90 / 100%", **FLOW) >> topic

    # One key over both telemetry stores.
    key >> Edge(label="CMEK", style="dashed") >> dataset
    key >> Edge(style="dashed") >> topic
