"""Bounded synthetic input: Celsius, kPa, and occasional missing values."""
import argparse
import json
import os
import random
import time
import uuid
from google.cloud import pubsub_v1

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--count", type=int, default=20)
    parser.add_argument("--delay", type=float, default=0.5)
    args = parser.parse_args()
    if args.count < 1 or args.delay < 0:
        parser.error("count must be positive and delay non-negative")
    project = os.environ["GCP_PROJECT"]
    topic = os.environ.get("DESIGN_TOPIC", "smartMeterDesign")
    publisher = pubsub_v1.PublisherClient()
    path = publisher.topic_path(project, topic)
    run_id = uuid.uuid4().hex
    try:
        for index in range(args.count):
            record = {"ID": f"{run_id}-{index}", "time": int(time.time()),
                      "profile_name": random.choice(["boston", "denver", "losang"]),
                      "temperature": round(random.uniform(10, 35), 3),
                      "humidity": round(random.uniform(20, 90), 3),
                      "pressure": round(random.uniform(95, 105), 3)}
            if (index + 1) % 4 == 0:
                record[random.choice(["temperature", "humidity", "pressure"])] = None
            publisher.publish(path, json.dumps(record).encode("utf-8"),
                              function="raw").result(timeout=30)
            print("Published:", record, flush=True)
            time.sleep(args.delay)
        print(f"Published {args.count} raw readings; run ID={run_id}")
    finally:
        publisher.stop()

if __name__ == "__main__":
    main()
