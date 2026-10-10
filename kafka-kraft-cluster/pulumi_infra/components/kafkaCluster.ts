import * as fs from "fs";
import * as pulumi from "@pulumi/pulumi";
import * as gcp from "@pulumi/gcp";
import * as random from "@pulumi/random";
import { renderTemplate } from "./template";

// =============================================================================
// KafkaCluster component
//
// Port of terraform_infra/main.tf (everything broker-specific). N brokers,
// each running combined broker+controller KRaft roles (no Zookeeper, no
// dedicated controllers). Private IPs only; egress via Cloud NAT; SSH via IAP.
// Networking comes from the KafkaNetwork component.
// =============================================================================

export interface KafkaClusterArgs {
    subnetworkId: pulumi.Input<string>;
    region: string;
    zone: string;
    nodeCount: number;
    machineType: string;
    dataDiskSizeGb: number;
    dataMountPath: string;
    brokerPort: number;
    controllerPort: number;
    brokerTag: string;
    kafkaVersion: string;
    scalaVersion: string;
    startupTemplatePath: string;
}

export class KafkaCluster extends pulumi.ComponentResource {
    public readonly clusterId: pulumi.Output<string>;
    public readonly brokerNames: pulumi.Output<string>[];
    public readonly brokerIps: pulumi.Output<string>[];
    public readonly quorumVoters: pulumi.Output<string>;

    constructor(name: string, args: KafkaClusterArgs, opts?: pulumi.ComponentResourceOptions) {
        super("kafkakraft:cluster:KafkaCluster", name, {}, opts);
        const childOpts = { parent: this };

        // Terraform's count.index becomes an ordinary array of indices.
        const indices = Array.from({ length: args.nodeCount }, (_, i) => i);

        // KRaft cluster identity: generated once and handed to every node so
        // all brokers format storage with the same ID and can form a quorum.
        const clusterId = new random.RandomUuid("kraft-cluster-id", {}, childOpts);

        // Static internal IPs, reserved before any instance exists. They feed
        // each broker's advertised.listeners and the shared quorum voters list.
        const addresses = indices.map(i =>
            new gcp.compute.Address(`kafka-kraft-node-ip-${i}`, {
                name: `kafka-kraft-node-ip-${i}`,
                addressType: "INTERNAL",
                subnetwork: args.subnetworkId,
                region: args.region,
            }, childOpts));

        const disks = indices.map(i =>
            new gcp.compute.Disk(`kafka-kraft-data-${i}`, {
                name: `kafka-kraft-data-${i}`,
                type: "pd-ssd",
                zone: args.zone,
                size: args.dataDiskSizeGb,
            }, childOpts));

        // Identical on every node: "0@ip0:9093,1@ip1:9093,2@ip2:9093".
        // The IPs are Outputs (unknown until GCP allocates them), so the
        // string is built inside pulumi.all(...).apply(...), not directly.
        const quorumVoters = pulumi
            .all(addresses.map(a => a.address))
            .apply(ips => ips.map((ip, i) => `${i}@${ip}:${args.controllerPort}`).join(","));

        // Read the shared template once; rendered per broker below.
        const template = fs.readFileSync(args.startupTemplatePath, "utf8");

        const brokers = indices.map(i => {
            const brokerName = `kafka-kraft-broker-${i}`;

            // Replaces templatefile(): wait for the IP, quorum list, and
            // cluster ID to resolve, then render the script with plain strings.
            const startupScript = pulumi
                .all([addresses[i].address, quorumVoters, clusterId.result])
                .apply(([advertisedIp, voters, id]) => renderTemplate(template, {
                    node_id: String(i),
                    node_name: brokerName,
                    broker_port: String(args.brokerPort),
                    controller_port: String(args.controllerPort),
                    advertised_ip: advertisedIp,
                    controller_quorum_voters: voters,
                    cluster_id: id,
                    data_mount: args.dataMountPath,
                    kafka_version: args.kafkaVersion,
                    scala_version: args.scalaVersion,
                }));

            return new gcp.compute.Instance(brokerName, {
                name: brokerName,
                machineType: args.machineType,
                zone: args.zone,
                allowStoppingForUpdate: true,

                bootDisk: {
                    initializeParams: {
                        image: "ubuntu-os-cloud/ubuntu-2204-lts",
                        size: 50,
                        type: "pd-ssd",
                    },
                },

                // Separate data disk per broker for Kafka log segments,
                // formatted XFS and mounted by the startup script.
                attachedDisks: [{
                    source: disks[i].id,
                    deviceName: "kafka-data",
                }],

                // No accessConfigs: brokers are private-only, egress via Cloud NAT.
                networkInterfaces: [{
                    subnetwork: args.subnetworkId,
                    networkIp: addresses[i].address,
                }],

                tags: ["kafka-kraft", args.brokerTag],

                metadata: {
                    "enable-oslogin": "TRUE",
                    "startup-script": startupScript,
                },

                labels: {
                    environment: "client-project",
                    project: "kafka-kraft-cluster",
                },
            }, childOpts);
        });

        this.clusterId = clusterId.result;
        this.brokerNames = brokers.map(b => b.name);
        this.brokerIps = addresses.map(a => a.address);
        this.quorumVoters = quorumVoters;

        this.registerOutputs({
            clusterId: this.clusterId,
            brokerNames: this.brokerNames,
            brokerIps: this.brokerIps,
            quorumVoters: this.quorumVoters,
        });
    }
}
