import os
import random
import time
import uuid

DEVICE_COUNT = int(os.environ.get("DEVICE_COUNT", "10"))

# Synthetic telemetry — swap this out for whatever shape of data actually
# matters once there's a real use case; this is just a lab placeholder.
EVENT_TYPES = ["temperature", "humidity", "pressure"]

VALUE_RANGES = {
    "temperature": (15.0, 35.0),  # Celsius
    "humidity": (20.0, 90.0),     # % relative humidity
    "pressure": (980.0, 1030.0),  # hPa
}


def generate_event():
    event_type = random.choice(EVENT_TYPES)
    low, high = VALUE_RANGES[event_type]
    return {
        "event_id": str(uuid.uuid4()),
        "device_id": f"device-{random.randint(0, DEVICE_COUNT - 1)}",
        "event_type": event_type,
        "value": round(random.uniform(low, high), 2),
        "ts": time.time(),
    }