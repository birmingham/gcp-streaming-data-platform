import * as path from "path";
import * as pulumi from "@pulumi/pulumi";
import { settings } from "./config";
import { KafkaNetwork } from "./components/kafkaNetwork";
import { KafkaCluster } from "./components/kafkaCluster";

const kafkaNetwork = new KafkaNetwork("kafka", {
    region: settings.region,
    subnetCidr: settings.subnetCidr,
    brokerPort: settings.brokerPort,
    controllerPort: settings.controllerPort,
    brokerTag: settings.brokerTag,
    clientSourceRanges: settings.clientSourceRanges,
    crdbNetworkName: settings.crdbNetworkName,
    feederNetworkName: settings.feederNetworkName,
});

const kafkaCluster = new KafkaCluster("kafka", {
    subnetworkId: kafkaNetwork.subnetworkId,
    region: settings.region,
    zone: settings.zone,
    nodeCount: settings.nodeCount,
    machineType: settings.machineType,
    dataDiskSizeGb: settings.dataDiskSizeGb,
    dataMountPath: settings.dataMountPath,
    brokerPort: settings.brokerPort,
    controllerPort: settings.controllerPort,
    brokerTag: settings.brokerTag,
    kafkaVersion: settings.kafkaVersion,
    scalaVersion: settings.scalaVersion,
    // Same shared template the Terraform stack uses.
    startupTemplatePath: path.join(__dirname, "..", "templates", "kafka-startup.sh.tpl"),
});

// Network outputs (equivalent to the network module's outputs).
export const networkId = kafkaNetwork.networkId;
export const networkName = kafkaNetwork.networkName;
export const subnetworkId = kafkaNetwork.subnetworkId;
export const natIps = kafkaNetwork.natIps;

// Cluster outputs (new; handy for the feeder and for verifying the quorum).
export const kraftClusterId = kafkaCluster.clusterId;
export const brokerNames = kafkaCluster.brokerNames;
export const brokerIps = kafkaCluster.brokerIps;
export const quorumVoters = kafkaCluster.quorumVoters;
export const bootstrapServers = pulumi
    .all(kafkaCluster.brokerIps)
    .apply(ips => ips.map(ip => `${ip}:${settings.brokerPort}`).join(","));
