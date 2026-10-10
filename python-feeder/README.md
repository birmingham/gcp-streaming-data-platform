# python-feeder

One image, two roles, controlled by the `MODE` env var:

- `MODE=producer` — generates synthetic device-telemetry events and publishes them to a Kafka topic.
- `MODE=consumer` — reads from that topic and writes each event into a CockroachDB table (`events`, created automatically on first run).

## Environment variables

| Variable | Used by | Required | Default | Notes |
|---|---|---|---|---|
| `MODE` | both | yes | — | `producer` or `consumer` |
| `KAFKA_BOOTSTRAP_SERVERS` | both | yes | — | Comma-separated `host:port` list, e.g. the three Kafka broker internal IPs on port `9092` |
| `KAFKA_TOPIC` | both | no | `feeder-events` | Must match between producer and consumer deployments |
| `KAFKA_CONSUMER_GROUP` | consumer | no | `feeder-consumer` | |
| `CRDB_CONN_STRING` | consumer | yes | — | Postgres-wire connection string, e.g. `postgresql://user@<crdb-node-ip>:30257/defaultdb?sslmode=require` |
| `PRODUCE_INTERVAL_SECONDS` | producer | no | `1` | Seconds between synthetic events |
| `DEVICE_COUNT` | producer | no | `10` | Number of distinct simulated `device_id`s |

## Build and push

The project ID (`<PROJECT_ID>`) is already known from the CockroachDB/Kafka Terraform, but the Artifact Registry repo doesn't exist yet — create it once, then submit the build from this directory:

```bash
gcloud artifacts repositories create feeder-repo \
  --repository-format=docker \
  --location=us-west1 \
  --project=<PROJECT_ID>

gcloud builds submit --tag us-west1-docker.pkg.dev/<PROJECT_ID>/feeder-repo/python-feeder:latest .
```

Using the regional host (`us-west1-docker.pkg.dev`) rather than the multi-region `us-docker.pkg.dev` from the original command keeps the image in the same region as the Kafka brokers and CockroachDB nodes it'll be pulled by.

## Run locally (optional sanity check)

```bash
docker build -t python-feeder:local .

docker run --rm \
  -e MODE=producer \
  -e KAFKA_BOOTSTRAP_SERVERS=<broker-ip>:9092 \
  python-feeder:local
```

## Not yet handled

- No `python-feeder-network` VPC or GCE/GKE deployment for this image yet — that's the next piece once the image is building cleanly.
- No retry/backoff around the CockroachDB connection in `db.py` — fine for a lab, worth hardening before anything long-running.
