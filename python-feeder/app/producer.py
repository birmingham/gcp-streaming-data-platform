import json
import os
import time

from kafka import KafkaProducer

from data_gen import generate_event


def build_producer():
    bootstrap_servers = os.environ["KAFKA_BOOTSTRAP_SERVERS"].split(",")
    return KafkaProducer(
        bootstrap_servers=bootstrap_servers,
        value_serializer=lambda v: json.dumps(v).encode("utf-8"),
        key_serializer=lambda k: k.encode("utf-8") if k else None,
        acks="all",
        retries=5,
    )


def run_producer():
    topic = os.environ.get("KAFKA_TOPIC", "feeder-events")
    interval = float(os.environ.get("PRODUCE_INTERVAL_SECONDS", "1"))
    producer = build_producer()

    print(f"Producing synthetic events to topic '{topic}' every {interval}s")
    try:
        while True:
            event = generate_event()
            producer.send(topic, key=event["device_id"], value=event)
            producer.flush()
            print(f"Produced: {event}")
            time.sleep(interval)
    except KeyboardInterrupt:
        pass
    finally:
        producer.close()