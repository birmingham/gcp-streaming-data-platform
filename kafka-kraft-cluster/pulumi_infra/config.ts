import * as pulumi from "@pulumi/pulumi";

// Mirrors terraform_infra/variables.tf. Provider settings (project, region,
// zone) live under the "gcp:" namespace; everything else is project config.
// Defaults match the Terraform defaults so both stacks behave the same.
const gcpConfig = new pulumi.Config("gcp");
const cfg = new pulumi.Config();

export const settings = {
    project: gcpConfig.require("project"),
    region: gcpConfig.require("region"),
    zone: gcpConfig.require("zone"),

    // Required, like the Terraform variable. Kept distinct from the
    // CockroachDB VPC's 10.20.0.0/24 in case the two are ever peered.
    subnetCidr: cfg.require("subnetCidr"),

    // Each node runs combined broker+controller KRaft roles, so this is
    // also the size of the controller quorum.
    nodeCount: cfg.getNumber("nodeCount") ?? 3,
    machineType: cfg.get("machineType") ?? "n2-standard-4", // 4 vCPU / 16 GB RAM
    dataDiskSizeGb: cfg.getNumber("dataDiskSizeGb") ?? 500,
    dataMountPath: cfg.get("dataMountPath") ?? "/kafka",

    brokerPort: cfg.getNumber("brokerPort") ?? 9092,
    controllerPort: cfg.getNumber("controllerPort") ?? 9093,

    kafkaVersion: cfg.get("kafkaVersion") ?? "4.3.1",
    scalaVersion: cfg.get("scalaVersion") ?? "2.13",

    // Firewall rules are scoped to this tag rather than a CIDR range.
    brokerTag: cfg.get("brokerTag") ?? "kafka-broker",
    clientSourceRanges: cfg.getObject<string[]>("clientSourceRanges") ?? [],

    // Empty string = no peering, same as the Terraform count conditionals.
    // Current design keeps Kafka and CockroachDB unpeered; the feeder talks to both.
    crdbNetworkName: cfg.get("crdbNetworkName") ?? "",
    feederNetworkName: cfg.get("feederNetworkName") ?? "",
};
