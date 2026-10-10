# Feeder / Kafka / CockroachDB — Full Destroy & Reapply Sequence

## Before you destroy

Destroying `crdb-cluster` and `kafka-kraft-cluster` deletes their data
disks — this is a full wipe of CockroachDB's data and Kafka's topic
data/offsets, not a stop/start. Confirm that's actually intended before
running `terraform destroy` in either directory.

## Destroy order

The circular peering dependency bites in reverse on teardown: Terraform
evaluates data sources during `destroy` too, so if `crdb-cluster` and/or
`kafka-kraft-cluster` are destroyed first, `python-feeder`'s
`data "google_compute_network"` lookups for those now-gone VPCs will
fail and block its destroy entirely.

First login to GCP console before executing any of the gcloud commands below.

```bash
gcloud auth login  # Enables access to the Google SDK
gcloud auth application-default login  # Enables access to the Google Libraries
``` 

Fix — override the two variables on the command line so the lookups are
skipped (no need to edit `terraform.tfvars`):

```bash
cd python-feeder/terraform_infra
terraform destroy -var="crdb_network_name=" -var="kafka_network_name="
```

This still removes everything tracked in state (VPC, subnet, both
worker pools, both peering resources) — the override just prevents
Terraform from trying to read a VPC that's already gone.

To avoid this entirely next time, destroy `python-feeder` **first**,
before `crdb-cluster` or `kafka-kraft-cluster` — the reverse of the
apply order above.

### Expect a 1-2 hour delay destroying the feeder subnet

Even destroying `python-feeder` first, the subnet delete can fail with:

```
Error: Error when reading or editing Subnetwork: googleapi: Error 400:
The subnetwork resource '.../subnetworks/python-feeder-subnet' is
already being used by '.../addresses/serverless-ipv4-<id>',
resourceInUseByAnotherResource
```

This is documented, expected behavior, not a bug: Cloud Run's Direct VPC
egress reserves internal IP addresses in the subnet, and releases them
asynchronously after the worker pools/services are deleted. Google's own
docs state you must wait 1-2 hours after deleting the Cloud Run
resources before the subnet can be deleted. These addresses **cannot be
manually deleted** to force it — there's no workaround, only waiting.

If `terraform destroy` on `python-feeder` fails with this error:
1. Just retry it in an hour or two — no other action needed.
2. `crdb-cluster` and `kafka-kraft-cluster` don't depend on this, so
   proceed with tearing those down (or starting the next day's rebuild
   per the Apply sequence above) without waiting on the feeder subnet.
3. If the address is still stuck well past 1-2 hours, that may indicate
   an orphaned reservation (a known, rarer issue reported even after the
   owning Cloud Run resource is fully deleted) rather than normal
   cleanup lag — worth investigating further only at that point.

## Why the apply order matters

`python-feeder`, `kafka-kraft-cluster`, and `crdb-cluster` peer their VPCs
to each other. Each side's peering is a `data "google_compute_network"`
lookup against a VPC that has to already exist, so applying any of them
too early fails with a "network not found" error. This is a three-way
circular dependency on a from-scratch apply — nothing is broken, it just
has to be unwound one step at a time.

As of the last working apply: `crdb-cluster/terraform.tfvars` already has
`feeder_network_name` and `additional_admin_source_ranges` permanently
set (no longer a separate late step), and
`kafka-kraft-cluster/terraform.tfvars` has `feeder_network_name`
permanently uncommented. Only `python-feeder/terraform.tfvars` needs a
temporary edit during this sequence.

## Step 1 — Apply the feeder stack with its own peering temporarily disabled

In `python-feeder/terraform_infra/terraform.tfvars`, temporarily set:

```hcl
crdb_network_name  = ""
kafka_network_name = ""
```

Then apply. This creates only the feeder VPC, subnet, and the two worker
pools — both peering resources are `count`-gated to 0 since their target
variables are empty. (The worker pools will fail to actually run
anything meaningful yet — `kafka_bootstrap_servers` and `crdb_conn_string`
in this same tfvars file are stale from the last apply. That's expected
at this point; they get fixed in Step 6.)

```bash
cd python-feeder/terraform_infra
terraform apply
```

## Step 2 — Apply the CockroachDB stack

`crdb-cluster/terraform.tfvars` already references
`feeder_network_name = "python-feeder-network"`. That VPC now exists
(from Step 1), so this succeeds and creates `crdb-to-feeder-peering`
immediately — no separate step needed for this side.

```bash
cd ../../crdb-cluster/terraform_infra
terraform apply
```

Wait for the new VMs to finish booting and RKE2 to initialize before
moving on — check with:

```bash
terraform output node_internal_ips
```

then confirm the cluster is actually up before applying manifests in
Step 4.

## Step 3 — Apply the Kafka stack

`kafka-kraft-cluster/terraform.tfvars` already has `feeder_network_name`
set. That VPC exists (from Step 1), so this succeeds and creates
`kafka-to-feeder-peering` immediately.

```bash
cd ../../kafka-kraft-cluster/terraform_infra
terraform apply
terraform output bootstrap_servers
```

Save that `bootstrap_servers` value — you'll need it in Step 6.

## Step 4 — Reapply the CockroachDB Kubernetes manifests

Destroying `crdb-cluster` wipes the whole RKE2/Kubernetes cluster, not
just the Terraform-managed infra underneath it. The namespace,
StatefulSet, Service (including the NodePort fix), cluster-init job, and
storage config all need to be reapplied against the fresh cluster.

```bash
cd ../../crdb-cluster
./scripts/kubeconfig-node-0.sh   # refetch kubeconfig — node IPs changed
./scripts/mount-crdb-disk.sh     # if this needs to run per-node before storage comes up

kubectl apply -f crdb_manifests/01-namespace.yaml
kubectl apply -f crdb_manifests/05-storage.yaml
kubectl apply -f crdb_manifests/03-statefulset.yaml
kubectl apply -f crdb_manifests/02-service.yaml
kubectl apply -f crdb_manifests/04-cluster-init.yaml

kubectl get pods -n cockroachdb
kubectl get svc cockroachdb-public -n cockroachdb   # confirm NodePort 30257/30080
```

## Step 5 — Re-enable the feeder's own peering and re-apply

Back in `python-feeder/terraform_infra/terraform.tfvars`, restore:

```hcl
crdb_network_name  = "crdb-lab-network"
kafka_network_name = "kafka-kraft-network"
```

Both target VPCs exist now, so this adds `feeder-to-crdb-peering` and
`feeder-to-kafka-peering`.

```bash
cd ../../python-feeder/terraform_infra
terraform apply
```

## Step 6 — Refresh the stale env vars and re-apply once more

The worker pools are still running with last time's broker IPs and
CockroachDB node IP. In `python-feeder/terraform_infra/terraform.tfvars`,
update:

```hcl
kafka_bootstrap_servers = "<paste the value saved from Step 3>"
crdb_conn_string        = "postgresql://user@<new-crdb-node-ip>:30257/defaultdb?sslmode=require"
```

Get the new CockroachDB node IP from:

```bash
cd ../../crdb-cluster/terraform_infra
terraform output node_internal_ips
```

Then re-apply the feeder stack one final time:

```bash
cd ../../python-feeder/terraform_infra
terraform apply
```

## Step 7 — Verify end to end

```bash
gcloud compute networks peerings list --network=kafka-kraft-network --project=<PROJECT_ID>
gcloud compute networks peerings list --network=crdb-lab-network --project=<PROJECT_ID>
gcloud compute networks peerings list --network=python-feeder-network --project=<PROJECT_ID>
```

All three should show `ACTIVE` on both sides of each pairing (Kafka and
CockroachDB stay unpeered to each other — VPC peering is non-transitive,
so the hub-and-spoke shape holds with no extra config).

```bash
gcloud beta run worker-pools logs read python-feeder-producer --region=us-west1 --project=<PROJECT_ID>
gcloud beta run worker-pools logs read python-feeder-consumer --region=us-west1 --project=<PROJECT_ID>
```

Producer logs should show `Produced: {...}`; consumer logs should show
`Wrote: {...}`.

## Plan-output quirks that are expected, not bugs

- **`Plan: 4 to add`** for the feeder stack (Step 1) is correct: network,
  subnet, producer worker pool, consumer worker pool. No NAT, no
  unexpected resources.
- **All `env` blocks under the consumer worker pool show as redacted**
  in the plan diff, not just `CRDB_CONN_STRING`. This is a Terraform CLI
  display quirk — one sensitive value in a repeated `env { }` block type
  can flatten the redaction across every instance of that block type.
  The actual values apply correctly; only the plan *display* is
  affected.
- **`nat_ip_addresses` on the Kafka stack shows `toset([])`.** Expected
  for `nat_ip_allocate_option = "AUTO_ONLY"` — Google manages those IPs
  dynamically and doesn't expose them through this Terraform attribute.
  NAT itself is still functioning; only this one output is a known gap
  in the provider. Use if you ever need the actual IP.

```bash
  gcloud compute routers get-nat-mapping-info
```
 
