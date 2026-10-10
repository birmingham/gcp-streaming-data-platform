# Kafka KRaft Cluster

A three-node Apache Kafka cluster running in **KRaft mode** (no Zookeeper) on GCP Compute Engine, built for client presentation as part of the CockroachDB/Kafka/Python-feeder architecture. Deliberately kept as its own standalone Terraform module — its own VPC, its own state — separate from the CockroachDB cluster.

## Architecture

- **3 brokers**, each running combined `broker,controller` KRaft roles (no dedicated controller-only nodes)
- **Private IPs only** — no external IPs on any node. Outbound internet access goes through Cloud NAT; Google API access (metadata server, package sources) goes through Private Google Access on the subnet
- **Admin access via IAP tunneling** — SSH (port 22) is reachable only from Google's IAP forwarding range, not the public internet
- **Static internal IPs**, reserved before any node boots, since they're baked directly into each broker's `advertised.listeners` and into the shared `controller.quorum.voters` list
- **XFS-formatted data disk** per broker, mounted at `/kafka`, separate from the boot disk, for Kafka log segments
- **KRaft cluster ID** generated once via Terraform (`random_uuid`) and passed identically to all three nodes, so they format their storage as one cluster instead of three independent ones

This cluster does **not** talk directly to CockroachDB. A separate Python feeder service (its own VPC, not yet built) is the layer that reads/writes both — Kafka and CockroachDB stay logically independent, connected only via that feeder.

## Directory layout

```
kafka-kraft-cluster/
├── README.md
├── terraform_infra/
│   ├── main.tf          # brokers, disks, static IPs, KRaft cluster ID, network module call
│   ├── variables.tf
│   ├── outputs.tf
│   └── provider.tf
└── templates/
    └── kafka-startup.sh.tpl   # per-broker startup script (disk mount, Kafka install, KRaft config, systemd unit)

modules/network/            # shared network module (repo root, sibling of kafka-kraft-cluster/)
├── network.tf              # VPC, subnet, Cloud Router/NAT, VPC peering, outputs
└── firewall.tf             # tag-scoped firewall rules
```

> Terraform is always run from inside `terraform_infra/` in this project — all relative paths (`../templates/...`, `../../modules/network`) assume that working directory.

## Prerequisites

- Terraform `~> 1.x` with the `hashicorp/google ~> 5.0` and `hashicorp/random ~> 3.6` providers
- `gcloud` CLI authenticated against the target GCP project
- IAP-based SSH access enabled on the project (`roles/iap.tunnelResourceAccessor` on your account)

## Setup

```bash
cd kafka-kraft-cluster/terraform_infra
terraform init
terraform plan
terraform apply
```

Required variables (set via `terraform.tfvars` or `-var`):

| Variable     | Description                          |
|--------------|---------------------------------------|
| `project_id` | GCP project to deploy into            |
| `region`     | Region for subnet, router, Cloud NAT  |
| `zone`       | Zone for broker VMs and data disks    |

Everything else has a sensible default — see `variables.tf` for the full list (machine type, disk size, Kafka/Scala versions, ports, etc.).

## Connecting to a broker

No external IPs exist, so all access goes through an IAP tunnel:

```bash
# SSH
gcloud compute ssh kafka-kraft-broker-0 --zone <zone> --tunnel-through-iap

# Or a raw TCP tunnel to the broker port for a local Kafka client
gcloud compute start-iap-tunnel kafka-kraft-broker-0 9092 \
  --local-host-port=localhost:9092 --zone <zone>
```

## Outputs

- `broker_internal_ips` — the three brokers' static internal IPs, in node-ID order
- `bootstrap_servers` — ready-to-use `ip:port` comma-separated list for Kafka clients
- `kraft_cluster_id` — the shared KRaft cluster ID
- `nat_ip_addresses` — Cloud NAT's external IP(s), useful for allow-listing on external systems the brokers need to reach

## Networking & security notes

- Firewall rules are scoped by instance **tag** (`kafka-broker`), not subnet CIDR — see `modules/network/firewall.tf`
- `client_source_ranges` (for external Kafka client access, e.g. the future Python feeder) defaults to empty — no external client traffic is allowed in until this is populated
- `crdb_network_name` / `feeder_network_name` default to empty — VPC peering is opt-in and resolved via a `data "google_compute_network"` lookup by name, so nothing needs a hand-copied self-link. Peering also requires a matching `google_compute_network_peering` resource on the other side (CockroachDB module / feeder module)

## Known gaps / next steps

- Python feeder VPC and its peering aren't built yet — `feeder_network_name` and `client_source_ranges` stay empty until it exists
- `backend.tf` (remote state) and a checked-in `terraform.tfvars` weren't generated — add these once the state backend and real project/region/zone values are finalized
- No monitoring/alerting on broker health, disk usage, or under-replicated partitions yet
