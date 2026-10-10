# Feeder / Kafka / CockroachDB — First Apply Sequence

## Why this order matters

`python-feeder`, `kafka-kraft-cluster`, and `crdb-cluster` peer their VPCs
to each other. Each side's peering is a `data "google_compute_network"`
lookup against a VPC that has to already exist, so applying any of them
too early fails with a "network not found" error. This is a three-way
circular dependency on the first-ever apply — nothing is broken, it just
has to be unwound one step at a time.

## Step 1 — Apply the feeder stack with peering temporarily disabled

In `python-feeder/terraform_infra/terraform.tfvars`, temporarily set:

```hcl
crdb_network_name  = ""
kafka_network_name = ""
```

Then apply. This creates only the feeder VPC, subnet, and the two worker
pools — both peering resources are `count`-gated to 0 since their target
variables are empty.

```bash
cd python-feeder/terraform_infra
terraform apply
```

## Step 2 — Apply the CockroachDB stack

Not part of the cycle yet at this point (its `terraform.tfvars` doesn't
reference the feeder network until Step 5), so this applies cleanly on
its own.

```bash
cd ../../crdb-cluster/terraform_infra
terraform apply
```

## Step 3 — Apply the Kafka stack

`kafka-kraft-cluster/terraform.tfvars` already has
`feeder_network_name = "python-feeder-network"` set. That VPC now exists
(from Step 1), so this apply succeeds and creates the
`kafka-to-feeder-peering` resource.

```bash
cd ../../kafka-kraft-cluster/terraform_infra
terraform apply
```

## Step 4 — Re-enable the feeder's peering and re-apply

Back in `python-feeder/terraform_infra/terraform.tfvars`, remove the two
empty-string overrides from Step 1 (or set them explicitly):

```hcl
crdb_network_name  = "crdb-lab-network"
kafka_network_name = "kafka-kraft-network"
```

Both target VPCs exist now, so this apply adds
`feeder-to-crdb-peering` and `feeder-to-kafka-peering`.

```bash
cd ../../python-feeder/terraform_infra
terraform apply
```

## Step 5 — Close the loop on the CockroachDB side

Add to `crdb-cluster/terraform_infra/terraform.tfvars`:

```hcl
feeder_network_name            = "python-feeder-network"
additional_admin_source_ranges = ["10.40.0.0/24"]
```

Then re-apply:

```bash
cd ../../crdb-cluster/terraform_infra
terraform apply
```

After this step, all three VPCs exist and all three peering
relationships (`feeder<->crdb`, `feeder<->kafka`) are live. Kafka and
CockroachDB remain unpeered to each other — VPC peering is non-transitive,
so this hub-and-spoke shape holds without any extra configuration.

## Plan-output quirks that are expected, not bugs

- **`Plan: 4 to add`** for the feeder stack (Step 1) is correct: network,
  subnet, producer worker pool, consumer worker pool. No NAT, no
  unexpected resources.
- **All five `env` blocks under the consumer worker pool show as
  redacted** in the plan diff, not just `CRDB_CONN_STRING`. This is a
  Terraform CLI display quirk — when one block among a repeated block
  type (`env { }`) contains a sensitive value, the diff can flatten the
  redaction across every instance of that block type rather than just
  the sensitive one. The actual values apply correctly; only the plan
  *display* is affected.
