import os

import psycopg2


def get_connection():
    conn_string = os.environ["CRDB_CONN_STRING"]
    conn = psycopg2.connect(conn_string)
    conn.autocommit = True
    return conn


def ensure_schema(conn):
    with conn.cursor() as cur:
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS events (
                id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
                device_id STRING NOT NULL,
                event_type STRING NOT NULL,
                value FLOAT8 NOT NULL,
                created_at TIMESTAMPTZ DEFAULT now()
            )
            """
        )


def insert_event(conn, event):
    with conn.cursor() as cur:
        cur.execute(
            "INSERT INTO events (device_id, event_type, value) VALUES (%s, %s, %s)",
            (event["device_id"], event["event_type"], event["value"]),
        )