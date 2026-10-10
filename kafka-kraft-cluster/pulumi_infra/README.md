# Kafka KRaft Cluster — Pulumi (TypeScript)

A Pulumi/TypeScript port of the Terraform stack in `../terraform_infra`: the same three-node Kafka KRaft cluster in a private VPC (no external IPs, Cloud NAT egress, IAP-only SSH, tag-scoped firewall rules, dedicated SSD data disks).

- `components/kafkaNetwork.ts` — VPC, subnet, Cloud Router and NAT, firewall rules
- `components/kafkaCluster.ts` — broker VMs, data disks, startup script
- `components/template.ts` — renders `../templates/kafka-startup.sh.tpl`
- `config.ts` — stack configuration

```bash
npm install
pulumi stack init dev
pulumi config set gcp:project <PROJECT_ID>
pulumi up
```

Stack config files (`Pulumi.<stack>.yaml`) are git-ignored.
