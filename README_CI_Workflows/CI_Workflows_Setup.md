# CI Workflows — Setup

Three workflows live in `.github/workflows/`:

| Workflow | Trigger | What it does |
|---|---|---|
| `apply.yml` | Manual (`workflow_dispatch`) | Builds or rebuilds all three stacks in dependency order |
| `destroy.yml` | Manual, with typed confirmation | Tears down CockroachDB and Kafka; optionally the feeder |
| `terraform-checks.yml` | Pull requests and pushes to `main` touching `.tf` files | `terraform fmt` and `terraform validate` per stack; needs no GCP credentials |

`apply.yml` and `destroy.yml` share a concurrency group, so they can never
run at the same time. All GCP access is keyless through Workload Identity
Federation.

## How `apply.yml` maps to the manual sequence

The workflow automates the steps in `Python_Feeder_Sequence.md` and
`feeder-kafka-crdb-destroy-sequence.md`, which remain the reference for
running things by hand:

1. **Feeder bootstrap.** If `python-feeder-network` doesn't exist, apply the
   feeder stack with `crdb_network_name` and `kafka_network_name` overridden
   to empty strings, so both peering resources are `count`-gated off.
   Otherwise skip.
2. **Kafka and CockroachDB, in parallel.** Both peer to the feeder VPC, which
   now exists. Kafka's `bootstrap_servers` output and CockroachDB node 0's
   internal IP are passed forward as job outputs.
3. **CockroachDB manifests.** The workflow copies `crdb_manifests/` and
   `scripts/ci-apply-manifests.sh` to node 0 over IAP, retrying while the VM
   boots. The script waits for all RKE2 nodes to be `Ready`, applies the
   manifests in order (namespace, storage, StatefulSet, Service, init job),
   then waits for `cluster-init` and the StatefulSet.
4. **Feeder, final apply.** Peering is enabled, and the fresh Kafka bootstrap
   servers and CockroachDB connection string are passed as `-var` overrides,
   replacing the manual tfvars edits from Steps 5 and 6 of the sequence.
5. **Verify.** Lists the peerings on all three VPCs.

## Design decision: `python-feeder` isn't destroyed by default

`crdb-cluster` and `kafka-kraft-cluster` hold the only disposable state
(CockroachDB data, Kafka topic data). `python-feeder` holds none — just a
VPC, a subnet, and two Cloud Run worker pools whose env vars point at
whatever Kafka and CockroachDB endpoints currently exist.

Keeping the feeder standing across cycles avoids two problems:

- Cloud Run's Direct VPC egress releases reserved subnet IPs asynchronously,
  so deleting the feeder subnet can fail for 1-2 hours after the worker pools
  are gone. If the subnet is never deleted, that delay never applies.
- Re-applying the feeder updates its peering resources and pushes new
  Cloud Run revisions in place, with no destroy involved.

For a full teardown, run `destroy.yml` with `destroy_feeder` checked.

## Destroy order

`destroy.yml` destroys CockroachDB and Kafka first, in parallel, then the
feeder last if requested. While the feeder VPC still exists, CockroachDB's
and Kafka's `data "google_compute_network"` lookups for it succeed. The
feeder destroy then overrides its own lookups with empty network names,
since its peer VPCs are already gone.

If the feeder subnet hits the release delay, the workflow flags it with a
warning. Re-run with `destroy_feeder` in 1-2 hours; the addresses cannot be
deleted manually.

## Repository secrets

| Secret | Value |
|---|---|
| `GCP_WORKLOAD_IDENTITY_PROVIDER` | Full provider resource name: `projects/<PROJECT_NUMBER>/locations/global/workloadIdentityPools/github-pool/providers/github-provider` |
| `GCP_SERVICE_ACCOUNT` | `github-actions-sa@<PROJECT_ID>.iam.gserviceaccount.com` |
| `CRDB_CONN_STRING_TEMPLATE` | Connection string with `__NODE_IP__` as a placeholder, e.g. `postgresql://user@__NODE_IP__:30257/defaultdb?sslmode=require`; `apply.yml` substitutes the real IP and masks the result in logs |
| `TFVARS_CRDB` | Full contents of `crdb-cluster/terraform_infra/terraform.tfvars` |
| `TFVARS_KAFKA` | Full contents of `kafka-kraft-cluster/terraform_infra/terraform.tfvars` |
| `TFVARS_FEEDER` | Full contents of `python-feeder/terraform_infra/terraform.tfvars` |

The tfvars files are git-ignored, so the workflows write them from these
secrets at runtime. The feeder's `kafka_bootstrap_servers` and
`crdb_conn_string` values in `TFVARS_FEEDER` don't need to be current:
`apply.yml` overrides both on every run.

## Repository variables

| Variable | Value |
|---|---|
| `GCP_PROJECT_ID` | Your GCP project ID (required) |
| `GCP_REGION` | Defaults to `us-west1` |
| `GCP_ZONE` | Defaults to `us-west1-a` |
| `TF_STATE_BUCKET_CRDB` | GCS bucket for CockroachDB state |
| `TF_STATE_BUCKET_KAFKA` | GCS bucket for Kafka state |
| `TF_STATE_BUCKET_FEEDER` | GCS bucket for feeder state |
| `TF_VERSION` | Optional; defaults to `1.9.8`. Match your local `terraform version` |

Setting them with the GitHub CLI, from the repo root:

```bash
gh secret set TFVARS_CRDB   < crdb-cluster/terraform_infra/terraform.tfvars
gh secret set TFVARS_KAFKA  < kafka-kraft-cluster/terraform_infra/terraform.tfvars
gh secret set TFVARS_FEEDER < python-feeder/terraform_infra/terraform.tfvars
gh secret set CRDB_CONN_STRING_TEMPLATE --body 'postgresql://user@__NODE_IP__:30257/defaultdb?sslmode=require'

gh variable set GCP_PROJECT_ID         --body "<PROJECT_ID>"
gh variable set TF_STATE_BUCKET_CRDB   --body "<crdb-state-bucket>"
gh variable set TF_STATE_BUCKET_KAFKA  --body "<kafka-state-bucket>"
gh variable set TF_STATE_BUCKET_FEEDER --body "<feeder-state-bucket>"
```

## One-time GCP setup: Workload Identity Federation

GitHub's OIDC token is exchanged for short-lived GCP credentials at runtime;
there are no service account keys.

```bash
PROJECT_ID="<PROJECT_ID>"
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
REPO="birmingham/gcp-streaming-data-platform"

# 1. Workload Identity Pool
gcloud iam workload-identity-pools create "github-pool" \
  --project="$PROJECT_ID" --location="global" \
  --display-name="GitHub Actions Pool"

# 2. OIDC provider, restricted to tokens from this repo
gcloud iam workload-identity-pools providers create-oidc "github-provider" \
  --project="$PROJECT_ID" --location="global" \
  --workload-identity-pool="github-pool" \
  --display-name="GitHub Actions Provider" \
  --issuer-uri="https://token.actions.githubusercontent.com" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository" \
  --attribute-condition="assertion.repository=='${REPO}'"

# 3. Dedicated service account for the pipeline
gcloud iam service-accounts create "github-actions-sa" \
  --project="$PROJECT_ID" --display-name="GitHub Actions CI"

# 4. Allow only this repo to impersonate it
gcloud iam service-accounts add-iam-policy-binding \
  "github-actions-sa@${PROJECT_ID}.iam.gserviceaccount.com" \
  --project="$PROJECT_ID" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github-pool/attribute.repository/${REPO}"

# Value for the GCP_WORKLOAD_IDENTITY_PROVIDER secret
gcloud iam workload-identity-pools providers describe "github-provider" \
  --project="$PROJECT_ID" --location="global" \
  --workload-identity-pool="github-pool" --format="value(name)"
```

## IAM roles for `github-actions-sa`

```bash
for ROLE in \
  roles/compute.admin \
  roles/compute.networkAdmin \
  roles/iam.serviceAccountUser \
  roles/run.admin \
  roles/artifactregistry.writer \
  roles/storage.admin \
  roles/iap.tunnelResourceAccessor
do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:github-actions-sa@${PROJECT_ID}.iam.gserviceaccount.com" \
    --role="$ROLE"
done
```

- `roles/storage.admin` is project-wide for simplicity; scope it to the
  three state buckets for tighter permissions.
- If OS Login is enabled on the project, also grant
  `roles/compute.osAdminLogin` so the workflow can SSH to node 0 over IAP.

## What isn't automated yet

- **Building and pushing the feeder image.** `apply.yml` assumes
  `feeder_image` in `TFVARS_FEEDER` points at an already-built image. A
  separate workflow triggered on changes to `python-feeder/app/**` or
  `python-feeder/Dockerfile` could build and push it.
- **Notifications.** Failures only show in the Actions tab. A Slack or
  email step would page on a failed apply.
