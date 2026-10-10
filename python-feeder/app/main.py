"""
Python feeder — placeholder implementation.

Cloud Run Jobs run a container to completion rather than serving
requests, so this script does its work and exits: 0 on success, non-zero
to trigger Cloud Scheduler's retry_config. Replace the body of main()
with the real Kafka -> CockroachDB logic once it's built; the env vars,
logging, and exit-code convention here are what the real job will use
too.
"""

import logging
import os
import sys

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("python-feeder")


def main() -> int:
    kafka_bootstrap_servers = os.environ.get("KAFKA_BOOTSTRAP_SERVERS", "")
    crdb_hosts = os.environ.get("COCKROACHDB_HOSTS", "")

    log.info("Starting python-feeder run")
    log.info("KAFKA_BOOTSTRAP_SERVERS=%s", kafka_bootstrap_servers or "(not set)")
    log.info("COCKROACHDB_HOSTS=%s", crdb_hosts or "(not set)")

    if not kafka_bootstrap_servers:
        log.warning("KAFKA_BOOTSTRAP_SERVERS is not set — placeholder run, nothing to consume")
    if not crdb_hosts:
        log.warning("COCKROACHDB_HOSTS is not set — placeholder run, nowhere to write")

    # TODO: replace with real logic —
    #   1. Consume messages from Kafka (kafka_bootstrap_servers)
    #   2. Transform/validate
    #   3. Write to CockroachDB (crdb_hosts)

    log.info("python-feeder run complete")
    return 0


if __name__ == "__main__":
    sys.exit(main())