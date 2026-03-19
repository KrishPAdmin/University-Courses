#!/usr/bin/env python3
# COE892 Lab 3: Deminer (RabbitMQ consumer + publisher)
import argparse
import hashlib
import json
import logging
import time
from typing import Any, Dict

import pika

LOG = logging.getLogger("deminer")

DEMINE_QUEUE = "Demine-Queue"
DEFUSED_EXCHANGE = "Defused-Mines"


def serial_to_pin(serial: str) -> str:
    h = hashlib.sha256(serial.encode("utf-8", errors="ignore")).hexdigest()
    n = int(h[:12], 16) % 1_000_000
    return f"{n:06d}"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("deminer_id", type=int)
    parser.add_argument("--mq_host", default="localhost")
    parser.add_argument("--mq_port", type=int, default=5672)
    parser.add_argument("--disarm_time_s", type=float, default=0.35)
    parser.add_argument("--idle_sleep_s", type=float, default=0.05)
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")

    params = pika.ConnectionParameters(host=args.mq_host, port=args.mq_port, heartbeat=30, blocked_connection_timeout=30)
    conn = pika.BlockingConnection(params)
    ch = conn.channel()

    ch.queue_declare(queue=DEMINE_QUEUE, durable=True)
    ch.exchange_declare(exchange=DEFUSED_EXCHANGE, exchange_type="fanout", durable=True)
    ch.basic_qos(prefetch_count=1)

    LOG.info("deminer_started id=%d", args.deminer_id)

    def on_task(channel, method, properties, body: bytes):
        raw = body.decode("utf-8", errors="replace")
        try:
            task = json.loads(raw)
        except Exception:
            task = {"raw": raw}

        mine_id = str(task.get("mine_id", "UNKNOWN"))
        x = int(task.get("x", -1))
        y = int(task.get("y", -1))
        serial = str(task.get("serial", "UNKNOWN"))
        rover_id = task.get("rover_id", "UNKNOWN")

        LOG.info("task_received mine_id=%s pos=(%d,%d) rover=%s", mine_id, x, y, rover_id)

        time.sleep(args.disarm_time_s)
        pin = serial_to_pin(serial)

        result: Dict[str, Any] = {"deminer_id": args.deminer_id, "mine_id": mine_id, "x": x, "y": y, "pin": pin, "serial": serial, "ts": time.time()}
        channel.basic_publish(exchange=DEFUSED_EXCHANGE, routing_key="", body=json.dumps(result, ensure_ascii=False).encode("utf-8"), properties=pika.BasicProperties(delivery_mode=2))

        channel.basic_ack(delivery_tag=method.delivery_tag)
        LOG.info("task_completed mine_id=%s pin=%s", mine_id, pin)
        time.sleep(args.idle_sleep_s)

    ch.basic_consume(queue=DEMINE_QUEUE, on_message_callback=on_task, auto_ack=False)

    try:
        ch.start_consuming()
    except KeyboardInterrupt:
        pass

    try:
        conn.close()
    except Exception:
        pass


if __name__ == "__main__":
    main()
