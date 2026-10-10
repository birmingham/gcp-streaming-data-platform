import json
import os

from kafka import KafkaConsumer

from db import ensure_schema, get_connection, insert_event


def build_consumer():
    bootstrap_servers = os.environ["KAFKA_BOOTSTRAP_SERVERS"].split(",")
    topic = os.environ.get("KAFKA_TOPIC", "feeder-events")
    group_id = os.environ.get("KAFKA_CONSUMER_GROUP", "feeder-consumer")

    return KafkaConsumer(
        topic,
        bootstrap_servers=bootstrap_servers,
        group_id=group_id,
        value_deserializer=lambda v: json.loads(v.decode("utf-8")),
        key_deserializer=lambda k: k.decode("utf-8") if k else None,
        auto_offset_reset="earliest",
        enable_auto_commit=True,
    )


def run_consumer():
    conn = get_connection()
    ensure_schema(conn)

    consumer = build_consumer()
    print("Consuming events and writing to CockroachDB...")
    try:
        for message in consumer:
            event = message.value
            insert_event(conn, event)
            print(f"Wrote: {event}")
    except KeyboardInterrupt:
        pass
    finally:
        consumer.close()
        conn.close()