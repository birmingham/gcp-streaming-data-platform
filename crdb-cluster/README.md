# CockroachDB on RKE2 (GCP Compute Engine) — Quick Start

> **Note:** This lab runs CockroachDB in `--insecure` mode (no TLS, no
> authentication) for lab use only. See [Security Posture](#security-posture)
> for what that means and what a production setup would change.

## What Terraform Builds

A custom VPC with no default routes, a Cloud Router + Cloud NAT for
outbound internet access, and 5 GCE VMs (`e2-standard-4`, one 200GB
`pd-ssd` data disk each) that install and join RKE2 into a single
5-node HA cluster automatically on boot. Each node gets a reserved
static internal IP before any VM is created, and a shared cluster
token is generated once by Terraform — there's no manual token-copying
or IP-discovery step involved anywhere in this flow.

## Networking

The VMs have no external IPs. Outbound access (package installs, pulling
RKE2/images) goes through Cloud NAT. Inbound admin access goes through IAP
tunnels rather than a public source IP:

- **SSH (`22`)** and the **Kubernetes API (`6443`)** are reachable via a
  direct IAP tunnel to any node.
- **CockroachDB's SQL port (`30257`) and DB console (`30080`) are *not*
  reachable this same way**, even though the firewall allows it. Those only
  listen inside each pod's own network namespace — nothing is bound to
  those ports on the VM itself. Reaching them requires `kubectl
  port-forward`, which rides through the API-server connection you already
  have via the `6443` tunnel, rather than a second direct tunnel to a node.
  (This distinction cost real time during initial bring-up.)

## Security Posture

CockroachDB runs with `--insecure` to keep the focus on cluster formation,
networking, and failure behavior rather than certificate management. In
insecure mode:

- Node-to-node and client-to-node traffic is unencrypted.
- There is no client authentication; any client that can reach the SQL
  port connects as `root`.
- The DB console is served over plain HTTP with no login.

What limits exposure here is the network layer: the VMs have no external
IPs, inbound access is IAP-only, and the SQL port and DB console are only
reachable through `kubectl port-forward` over the IAP-tunneled API server
connection. That is acceptable for a short-lived lab holding synthetic
data. It is not acceptable for production or any real data.

### Moving to secure mode

A production version of this cluster would:

1. Generate a CA plus node and client certificates with `cockroach cert`
   (or cert-manager). Node certificate SANs must cover each pod's
   fully-qualified name
   (`cockroachdb-N.cockroachdb.cockroachdb.svc.cluster.local`), the short
   names, `cockroachdb-public`, and `localhost` — the same SAN discipline
   applied to RKE2's `tls-san` below.
2. Store the certificates as Kubernetes Secrets, mount them into the
   StatefulSet, and replace `--insecure` with `--certs-dir`.
3. Create SQL users authenticated by password or client certificate and
   grant least-privilege roles instead of connecting as `root`.
4. Serve the DB console over HTTPS with login required.

## RKE2 Install Is Automatic — Including Fixes for Two Real Bugs

`main.tf` renders `templates/rke2-startup.sh.tpl` per node via
`templatefile()` and attaches it as each VM's GCE `startup-script`, so RKE2
installs and joins itself on boot. It handles:

- **Disk format + mount**, with a retry loop — GCE's `startup-script` can
  run before udev finishes enumerating an attached (non-boot) disk, so it
  waits up to 60s for the device before formatting. Idempotent: it checks
  for an existing filesystem first, since GCE re-runs `startup-script` on
  every boot, not just the first.
- **A pinned RKE2 version** (`v1.36.4+rke2r1`, via `var.rke2_version`) —
  the install script's `stable` channel has a known intermittent bug where
  it resolves to a release before that release's assets are fully
  uploaded, causing a 404 mid-install.
- **Node 0 bootstraps, nodes 1–4 join it.** Joining nodes wait for node 0
  to actually answer before attempting to join, since instances boot in
  parallel with no ordering guarantee otherwise.
- **`tls-san` includes every node's IP**, not just its own — preventing the
  certificate SAN mismatch that occurs when a node or client reaches the
  API server through another node's address.
- **A Canal/Flannel MTU override** (`vethuMTU: "1410"`, dropped as a
  `HelmChartConfig` manifest for RKE2's embedded controller to auto-apply).
  This was the first of two real root causes behind a very stubborn
  cluster-formation bug: GCP's actual VPC MTU is `1460`, not the `1500`
  Canal assumes by default, and VXLAN encapsulation adds ~50 bytes of its
  own overhead on top. Left uncorrected, small packets (handshakes, pings)
  work fine while real cross-node traffic silently stalls — which looks
  exactly like a random, intermittent networking problem until you check
  the actual interface MTUs end to end.

Startup progress on any node is logged to `/var/log/rke2-startup.log`
(`sudo journalctl -u google-startup-scripts.service -f` also works, and
shows earlier boot activity than the log file does).

## The Kubernetes Manifests

Applied in order: `01-namespace.yaml`, `02-service.yaml`,
`03-statefulset.yaml`, `04-cluster-init.yaml`, `05-storage.yaml`.

- **`03-statefulset.yaml`** runs 5 replicas and sets
  `--advertise-host=$(hostname -f)` on the `cockroach start` command. This
  was the **second** of the two root causes: without it, CockroachDB
  advertises its bare pod name (`cockroachdb-0`) to the rest of the
  cluster instead of its fully-qualified one. Other pods can *reach* that
  node outbound via the `--join` list (which already uses fully-qualified
  names) just fine, but can never resolve the bare name it advertises back
  — so gossip and liveness heartbeats fail indefinitely with a
  `DistSender ... context deadline exceeded` error that looks identical to
  a raw networking failure, even once the network itself is completely
  healthy. Both this and the MTU fix were needed together; either alone
  left the cluster stuck.
- **`05-storage.yaml`** defines a `local-storage` StorageClass
  (`kubernetes.io/no-provisioner`, `WaitForFirstConsumer`) plus one
  `PersistentVolume` per node (`crdb-data-pv-0` through `-4`), each pinned
  to its node via `nodeAffinity` and sized at `200Gi` to match
  `var.data_disk_size_gb`. RKE2 doesn't ship a default StorageClass the
  way GKE or k3s do, so without this the StatefulSet's PVCs have nothing
  to bind to.

## Steps

1. Configure and provision everything. From `terraform_infra/`:

   ```
   cp terraform.tfvars.example terraform.tfvars    # set project_id and other values
   echo 'bucket = "<your-state-bucket>"' > backend.hcl   # create the GCS bucket first
   terraform init -backend-config=backend.hcl
   terraform apply
   ```

   `terraform.tfvars` and `backend.hcl` are git-ignored. Give it several
   minutes for all 5 nodes to boot, mount their disks, install RKE2, and
   join.

2. Pull node 0's kubeconfig to your own machine and tunnel the API server
   port, rather than SSHing in to run `kubectl` remotely:

   ```
   gcloud compute ssh crdb-lab-node-0 --zone=us-west1-a --tunnel-through-iap \
     --command="sudo cat /etc/rancher/rke2/rke2.yaml" > cockroachdb-lab-kubeconfig.yaml
   ```

   In a separate terminal, keep this running for as long as you're working
   with the cluster:

   ```
   gcloud compute start-iap-tunnel crdb-lab-node-0 6443 \
     --local-host-port=localhost:6443 --zone=us-west1-a
   ```

   Back in your first terminal:

   ```
   export KUBECONFIG=./cockroachdb-lab-kubeconfig.yaml
   kubectl get nodes
   ```

   RKE2's kubeconfig already points at `https://127.0.0.1:6443` by
   default, which is exactly what the tunnel makes true from your own
   machine — no editing needed. All 5 nodes should show `Ready`. The
   kubeconfig contains cluster-admin credentials and is git-ignored; never
   commit it.

3. Apply the manifests from `crdb_manifests/`:

   ```
   cd crdb_manifests
   kubectl apply -f 01-namespace.yaml -f 02-service.yaml -f 03-statefulset.yaml \
     -f 04-cluster-init.yaml -f 05-storage.yaml
   ```

4. Watch the pods come up:

   ```
   kubectl get pods -n cockroachdb -w
   ```

   `cluster-init` will show a couple of restarts before landing on
   `Completed` — it's retrying until `cockroachdb-0` is actually ready to
   accept the init command, which is expected. Each `cockroachdb-N` pod
   should reach `1/1 Running` within seconds to low tens of seconds of
   being created; if any one of them stalls for several minutes instead,
   that's the signal something's actually wrong rather than just still
   starting up.

5. Open the DB console via `kubectl port-forward`, not a direct IAP tunnel:

   ```
   kubectl port-forward -n cockroachdb svc/cockroachdb-public 8080:8080
   ```

   then browse to `http://localhost:8080` — plain HTTP, not HTTPS, since
   the cluster runs `--insecure`.

6. Connect with the SQL shell (CockroachDB speaks the PostgreSQL wire
   protocol):

   ```
   kubectl exec -it cockroachdb-0 -n cockroachdb -- \
     ./cockroach sql --insecure --host=cockroachdb-public
   ```

## Failure / CAP Theorem Exercises

With 5 nodes, quorum is 3 — the cluster tolerates losing any 2 nodes and
stays fully available, but loses write availability the moment a 3rd goes
down.

- **Single node failure** (should survive, no data loss):

  ```
  kubectl delete pod cockroachdb-1 -n cockroachdb
  ```

  Watch ranges re-replicate in the DB console "Overview" tab.

- **Two-node failure** (should *also* survive — this is the actual payoff
  of running 5 nodes instead of 3):

  ```
  kubectl delete pod cockroachdb-1 -n cockroachdb
  kubectl delete pod cockroachdb-2 -n cockroachdb
  ```

  3 of 5 nodes remain — still a majority, so the cluster stays available.

- **Quorum loss** (kill a 3rd node on top of the two above):

  ```
  kubectl delete pod cockroachdb-3 -n cockroachdb
  ```

  Down to 2 of 5 — this is the live CAP theorem demo: consistency
  preserved, availability sacrificed.

- **Scale to 7 nodes** to push the quorum math further (tolerates 3 node
  failures instead of 2): bump `node_count` in `variables.tf`, add matching
  PV blocks for nodes 5 and 6 in `05-storage.yaml`, `terraform apply`, then
  `kubectl scale statefulset cockroachdb -n cockroachdb --replicas=7`.

## Working Directly on Node 0 Instead (Alternative)

If you'd rather SSH into node 0 and run `kubectl` from there instead of
tunneling to your own machine, copy the kubeconfig into place first:

```
mkdir -p ~/.kube
sudo cp /etc/rancher/rke2/rke2.yaml ~/.kube/config
sudo chown "$(id -u):$(id -g)" ~/.kube/config
chmod 600 ~/.kube/config
kubectl get nodes
```

You'd then need to `gcloud compute scp` the manifest files to node 0
before applying them, since they won't exist there otherwise.

`mount-crdb-disk.sh` is **not** part of the normal flow — the startup
script already formats and mounts each node's data disk automatically. It
only exists as a manual fallback if a specific node's disk somehow didn't
mount on boot (check `/var/log/rke2-startup.log` on that node first to see
why, before reaching for this):

```
gcloud compute scp mount-crdb-disk.sh crdb-lab-node-N:~/ --zone=us-west1-a --tunnel-through-iap
gcloud compute ssh crdb-lab-node-N --zone=us-west1-a --tunnel-through-iap \
  --command="chmod +x mount-crdb-disk.sh && ./mount-crdb-disk.sh"
```

## Next Phase — Kafka Tie-In

Once this is stable, add a small Kafka cluster in the same namespace
pattern, write a Python producer emitting synthetic events, and either use
Kafka Connect (JDBC sink connector, Postgres-compatible) or a small custom
consumer to land events into a CockroachDB table. That gives you the full
ingestion -> distributed storage story end to end.
