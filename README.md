# GCP Streaming Data Platform

Three Terraform stacks on GCP that form a small streaming pipeline: a Python feeder on Cloud Run produces synthetic events to a Kafka KRaft cluster and consumes them into CockroachDB running on self-managed RKE2. Each stack has its own VPC and Terraform state. The feeder VPC is a hub peered to both Kafka and CockroachDB; peering is non-transitive, so those two stay isolated from each other. Nothing has an external IP: IAP for admin access, Cloud NAT for egress.

| Stack | What it builds |
|---|---|
| [`kafka-kraft-cluster/`](kafka-kraft-cluster/) | Three-node Kafka cluster in KRaft mode on Compute Engine; Terraform, plus a Pulumi/TypeScript port |
| [`crdb-cluster/`](crdb-cluster/) | Five-node CockroachDB on a five-node self-managed RKE2 cluster |
| [`python-feeder/`](python-feeder/) | Producer and consumer running as Cloud Run worker pools with Direct VPC egress |
| [`modules/`](modules/) | VPC, subnet, and firewall module per stack |

## CI/CD

GitHub Actions with keyless GCP authentication through Workload Identity Federation:

- **`apply.yml`** builds all three stacks in dependency order, automatically handling the circular VPC-peering bootstrap and applying the CockroachDB manifests over IAP.
- **`destroy.yml`** tears down CockroachDB and Kafka behind a typed confirmation; the feeder is kept by default.
- **`terraform-checks.yml`** runs `fmt` and `validate` on every pull request.

See [`README_CI_Workflows/`](README_CI_Workflows/) for setup and the manual run sequences.

A standalone version of the CockroachDB stack lives at [rke2-rancher-cockroachdb-gcp](https://github.com/birmingham/rke2-rancher-cockroachdb-gcp).
