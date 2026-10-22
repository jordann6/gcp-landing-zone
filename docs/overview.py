"""Overview diagram for gcp-landing-zone, the one-screen view at the top of the README.

Renders docs/overview.png with the official GCP icon set:

    python3 docs/overview.py   (from the repo root)

docs/diagram.py renders the full diagram (architecture.png).
"""

from diagrams import Cluster, Diagram, Edge
from diagrams.gcp.analytics import BigQuery
from diagrams.gcp.compute import GKE
from diagrams.gcp.database import SQL
from diagrams.gcp.network import NAT, FirewallRules, PrivateServiceConnect
from diagrams.gcp.operations import Logging
from diagrams.gcp.security import Iam, ResourceManager
from diagrams.onprem.network import Internet

ORG = {"bgcolor": "#eef6ff", "color": "#7299bd", "fontsize": "15"}
NET = {"bgcolor": "#fff4e7", "color": "#d49447", "fontsize": "15"}
PERIM = {"bgcolor": "#fdecea", "color": "#c0504d", "fontsize": "15", "style": "dashed"}
EGRESS = "#ac6413"

with Diagram(
    "GCP Landing Zone | overview",
    filename="docs/overview",
    outformat="png",
    show=False,
    direction="LR",
    graph_attr={"fontsize": "20", "pad": "0.4", "nodesep": "0.6", "ranksep": "1.0"},
    node_attr={"fontsize": "12"},
):
    with Cluster("Organization | nearly free, inherited", graph_attr=ORG):
        policy = ResourceManager("Org policy +\ncustom constraints\nat the root")
        idp = Iam("Workforce federation\nPAM: 1-hour prod write")
        sinks = Logging("Org sinks\nevery project")
        audit = BigQuery("CMEK audit\ndataset")
        sinks >> audit

    with Cluster("app-prod on the restricted Shared VPC | hourly", graph_attr=NET):
        with Cluster("VPC Service Controls perimeter", graph_attr=PERIM):
            gke = GKE("Private GKE\nBinary Authorization")
            sql = SQL("Cloud SQL HA\nprivate IP, CMEK")
            gke >> Edge(label="5432, app pods only") >> sql
        psc = PrivateServiceConnect("PSC endpoint\nGoogle APIs")
        ngfw = FirewallRules("Cloud NGFW\ndefault-deny egress\nFQDN allowlist")
        nat = NAT("Cloud NAT")

    inet = Internet("Allowlisted\ndomains")

    policy >> Edge(label="inherited", style="dashed") >> gke
    idp >> Edge(style="dashed") >> gke
    gke >> Edge(style="dotted") >> psc
    gke >> Edge(color=EGRESS) >> ngfw >> Edge(color=EGRESS) >> nat >> Edge(color=EGRESS) >> inet
