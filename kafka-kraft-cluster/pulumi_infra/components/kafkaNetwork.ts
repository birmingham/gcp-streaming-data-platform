import * as pulumi from "@pulumi/pulumi";
import * as gcp from "@pulumi/gcp";

// =============================================================================
// KafkaNetwork component
//
// Port of modules/network-kafka. Owns the VPC, subnet, Cloud NAT, firewall
// rules, and optional VPC peering for the Kafka KRaft cluster. Broker-specific resources
// (static IPs, disks, instances) live in the KafkaCluster component and
// consume this component's outputs.
// =============================================================================

export interface KafkaNetworkArgs {
    region: string;
    subnetCidr: string;

    // Inputs for the firewall rules (firewall.tf).
    brokerPort: number;
    controllerPort: number;
    brokerTag: string;
    clientSourceRanges: string[];

    // Empty string skips peering, matching the Terraform count conditionals.
    crdbNetworkName: string;
    feederNetworkName: string;
}

export class KafkaNetwork extends pulumi.ComponentResource {
    public readonly networkId: pulumi.Output<string>;
    public readonly networkName: pulumi.Output<string>;
    public readonly subnetworkId: pulumi.Output<string>;
    public readonly natIps: pulumi.Output<string[]>;

    constructor(name: string, args: KafkaNetworkArgs, opts?: pulumi.ComponentResourceOptions) {
        super("kafkakraft:network:KafkaNetwork", name, {}, opts);

        // Every child sets parent: this so it nests under the component in
        // the resource tree, like resources inside a Terraform module.
        const childOpts = { parent: this };

        // Explicit names keep GCP resource names identical to the Terraform
        // stack. Without "name", Pulumi appends a random suffix (auto-naming).
        const network = new gcp.compute.Network("kafka-kraft-network", {
            name: "kafka-kraft-network",
            autoCreateSubnetworks: false,
        }, childOpts);

        const subnet = new gcp.compute.Subnetwork("kafka-kraft-subnet", {
            name: "kafka-kraft-subnet",
            ipCidrRange: args.subnetCidr,
            region: args.region,
            network: network.id,
            privateIpGoogleAccess: true,
        }, childOpts);

        const router = new gcp.compute.Router("kafka-kraft-router", {
            name: "kafka-kraft-router",
            region: args.region,
            network: network.id,
        }, childOpts);

        const nat = new gcp.compute.RouterNat("kafka-kraft-nat", {
            name: "kafka-kraft-nat",
            router: router.name,
            region: args.region,
            natIpAllocateOption: "AUTO_ONLY",
            sourceSubnetworkIpRangesToNat: "ALL_SUBNETWORKS_ALL_IP_RANGES",
            logConfig: {
                enable: true,
                filter: "ERRORS_ONLY",
            },
        }, childOpts);

        // ---------------------------------------------------------------------
        // Firewall rules (port of firewall.tf). All rules target the broker
        // network tag rather than a CIDR range.
        // ---------------------------------------------------------------------

        // Broker-to-broker and KRaft controller quorum traffic, plus ICMP,
        // allowed only between instances carrying the broker tag.
        new gcp.compute.Firewall("kafka-kraft-allow-broker-internal", {
            name: "kafka-kraft-allow-broker-internal",
            network: network.name,
            allows: [
                { protocol: "tcp", ports: [String(args.brokerPort), String(args.controllerPort)] },
                { protocol: "icmp" },
            ],
            sourceTags: [args.brokerTag],
            targetTags: [args.brokerTag],
        }, childOpts);

        // SSH only through IAP TCP forwarding; brokers have no external IPs.
        new gcp.compute.Firewall("kafka-kraft-allow-ssh-iap", {
            name: "kafka-kraft-allow-ssh-iap",
            network: network.name,
            allows: [{ protocol: "tcp", ports: ["22"] }],
            sourceRanges: ["35.235.240.0/20"], // IAP TCP forwarding range
            targetTags: [args.brokerTag],
        }, childOpts);

        // Client access to the broker port, created only once client ranges
        // are known (Terraform: count = length(...) > 0 ? 1 : 0).
        if (args.clientSourceRanges.length > 0) {
            new gcp.compute.Firewall("kafka-kraft-allow-client-access", {
                name: "kafka-kraft-allow-client-access",
                network: network.name,
                allows: [{ protocol: "tcp", ports: [String(args.brokerPort)] }],
                sourceRanges: args.clientSourceRanges,
                targetTags: [args.brokerTag],
            }, childOpts);
        }

        // Terraform's `count = var.x != "" ? 1 : 0` becomes a plain if.
        // getNetworkOutput is the equivalent of a `data` block.
        if (args.crdbNetworkName !== "") {
            const crdb = gcp.compute.getNetworkOutput({ name: args.crdbNetworkName }, childOpts);
            new gcp.compute.NetworkPeering("kafka-to-crdb-peering", {
                name: "kafka-to-crdb-peering",
                network: network.id,
                peerNetwork: crdb.selfLink,
            }, childOpts);
        }

        if (args.feederNetworkName !== "") {
            const feeder = gcp.compute.getNetworkOutput({ name: args.feederNetworkName }, childOpts);
            new gcp.compute.NetworkPeering("kafka-to-feeder-peering", {
                name: "kafka-to-feeder-peering",
                network: network.id,
                peerNetwork: feeder.selfLink,
            }, childOpts);
        }

        this.networkId = network.id;
        this.networkName = network.name;
        this.subnetworkId = subnet.id;
        this.natIps = nat.natIps;

        this.registerOutputs({
            networkId: this.networkId,
            networkName: this.networkName,
            subnetworkId: this.subnetworkId,
            natIps: this.natIps,
        });
    }
}
