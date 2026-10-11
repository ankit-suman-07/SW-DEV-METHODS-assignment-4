#!/usr/bin/env bash
# Generate the assignment's smart-meter design; no cloud mutations.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
[[ -d voting_logger && -d voting_record && -d voting_machine ]] || { echo 'Run from the MS4 repository.' >&2; exit 1; }
python3 - <<'PY'
import ast
from pathlib import Path
import subprocess
import sys
import tempfile

files = {}
files['Design/common/transforms.py'] = '''"""Pure smart-meter preprocessing shared by both services."""
import math

MEASUREMENTS = ("temperature", "humidity", "pressure")

def filter_reading(record):
    if not isinstance(record, dict):
        raise ValueError("Reading must be a JSON object")
    if any(record.get(key) is None for key in MEASUREMENTS):
        return None
    if any(value is None for value in record.values()):
        return None
    for key in MEASUREMENTS:
        value = record[key]
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
            raise ValueError("Measurements must be finite numbers")
    return dict(record)

def convert_reading(record):
    cleaned = filter_reading(record)
    if cleaned is None:
        raise ValueError("Cannot convert a reading with missing measurements")
    cleaned["temperature"] = cleaned["temperature"] * 1.8 + 32
    cleaned["pressure"] = cleaned["pressure"] / 6.895
    return cleaned
'''

worker = '''"""Consume one filtered stage, publish the next, then acknowledge."""
import json
import logging
import os
from google.cloud import pubsub_v1
from transforms import filter_reading, convert_reading

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
PROJECT = os.environ["GCP_PROJECT"]
TOPIC = os.environ["TOPIC_NAME"]
SUBSCRIPTION = os.environ["SUBSCRIPTION_ID"]
STAGE = "STAGE_VALUE"
publisher = pubsub_v1.PublisherClient()
subscriber = pubsub_v1.SubscriberClient()
topic_path = publisher.topic_path(PROJECT, TOPIC)
subscription_path = subscriber.subscription_path(PROJECT, SUBSCRIPTION)

def callback(message):
    try:
        record = json.loads(message.data)
        result = filter_reading(record) if STAGE == "filter" else convert_reading(record)
    except (ValueError, TypeError, KeyError) as error:
        logging.warning("Discarding invalid reading: %s", error)
        message.ack()
        return
    if result is None:
        logging.info("Discarded missing-measurement reading ID=%s", record.get("ID"))
        message.ack()
        return
    try:
        output = "filtered" if STAGE == "filter" else "converted"
        publisher.publish(topic_path, json.dumps(result, allow_nan=False).encode("utf-8"),
                          function=output).result(timeout=30)
        message.ack()
        logging.info("Published %s ID=%s", output, result.get("ID"))
    except Exception:
        logging.exception("Publish failed; requesting redelivery")
        message.nack()

if __name__ == "__main__":
    logging.info("Listening on %s; stage=%s", subscription_path, STAGE)
    future = subscriber.subscribe(subscription_path, callback=callback,
                                  flow_control=pubsub_v1.types.FlowControl(max_messages=10))
    try:
        future.result()
    except KeyboardInterrupt:
        future.cancel()
        future.result()
    finally:
        subscriber.close()
        publisher.stop()
'''
for name, stage in [('filter_reading', 'filter'), ('convert_reading', 'convert')]:
    files[f'Design/{name}/main.py'] = worker.replace('STAGE_VALUE', stage)
    files[f'Design/{name}/Dockerfile'] = f'''FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt && useradd --uid 10001 --create-home appuser
COPY common/transforms.py ./transforms.py
COPY {name}/main.py ./main.py
USER appuser
CMD ["python", "-u", "main.py"]
'''
files['Design/requirements.txt'] = 'google-cloud-pubsub>=2.25,<3\n'
files['Design/.dockerignore'] = '*.json\n**/*.json\n.env\n.env.*\n**/.env*\n.venv/\n**/__pycache__/\n**/*.pyc\n.git/\ntests/\nREADME.md\n'
files['Design/.gcloudignore'] = files['Design/.dockerignore']
files['Design/producer.py'] = '''"""Bounded synthetic input: Celsius, kPa, and occasional missing values."""
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
'''
files['Design/tests/test_transforms.py'] = '''import math
import sys
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "common"))
from transforms import filter_reading, convert_reading

class TransformTests(unittest.TestCase):
    def setUp(self):
        self.record = {"ID": "test-1", "time": 123, "profile_name": "test",
                       "temperature": 20, "humidity": 50, "pressure": 6.895}

    def test_each_missing_measurement_is_discarded(self):
        for field in ("temperature", "humidity", "pressure"):
            with self.subTest(field=field):
                self.assertIsNone(filter_reading(dict(self.record, **{field: None})))

    def test_absent_measurement_is_discarded(self):
        record = dict(self.record)
        del record["pressure"]
        self.assertIsNone(filter_reading(record))

    def test_zero_measurements_are_valid(self):
        record = dict(self.record, temperature=0, humidity=0, pressure=0)
        converted = convert_reading(record)
        self.assertEqual(converted["temperature"], 32)
        self.assertEqual(converted["pressure"], 0)
        self.assertEqual(converted["humidity"], 0)

    def test_known_conversion_and_unchanged_metadata(self):
        converted = convert_reading(self.record)
        self.assertAlmostEqual(converted["temperature"], 68)
        self.assertAlmostEqual(converted["pressure"], 1)
        for field in ("ID", "time", "profile_name", "humidity"):
            self.assertEqual(converted[field], self.record[field])
        self.assertEqual(self.record["temperature"], 20)

    def test_negative_celsius(self):
        self.assertAlmostEqual(convert_reading(dict(self.record, temperature=-40))["temperature"], -40)

    def test_invalid_numeric_values(self):
        for value in ("20", True, math.nan, math.inf):
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    filter_reading(dict(self.record, temperature=value))

if __name__ == "__main__":
    unittest.main()
'''
files['Design/README.md'] = '''# Smart-meter preprocessing with Pub/Sub microservices

One topic, `smartMeterDesign`, carries all three stages, selected by the
`function` message attribute:

| Consumer | Subscription | Filter | Output |
| --- | --- | --- | --- |
| FilterReading | ms4-reading-filter-sub | function=raw | function=filtered |
| ConvertReading | ms4-reading-convert-sub | function=filtered | function=converted |
| BigQuery export | ms4-reading-bigquery-sub | function=converted | BigQuery rows |

FilterReading drops readings with missing measurements. ConvertReading uses
temperature F = temperature C * 1.8 + 32 and pressure psi = pressure kPa / 6.895.
Humidity and identification fields remain unchanged. Invalid numeric inputs
are also discarded. Input values are synthetic measurements, not real city data.

The BigQuery table will contain ID (STRING), time (INTEGER), profile_name
(STRING), temperature (FLOAT), humidity (FLOAT), and pressure (FLOAT).
Stored temperature is Fahrenheit; stored pressure is psi. A native BigQuery
subscription will export JSON using the table schema; workers do not write to
BigQuery directly. There are no additional worker databases.

Build each container from the Design context, for example:
`docker build -f Design/filter_reading/Dockerfile -t IMAGE Design`

Run pure transformation tests:
`python -m unittest discover -s Design/tests -v`

Run the producer after deployment with GCP_PROJECT set:
`python Design/producer.py --count 20`

Workers use Workload Identity; the producer uses Cloud Shell ADC.
The pipeline acknowledges only after downstream publication succeeds, and
requests redelivery on publication failure. Delivery is at least once: retries
can produce duplicates, so ID is a correlation field, not an exactly-once guarantee.

Preparation creates source files only. Deployment and live tests are separate
checkpoints. Original voting source credit remains with the upstream repository.
'''

# Refuse partial generation if any target already contains different content.
for filename, content in files.items():
    path = Path(filename)
    if path.exists() and path.read_text() != content:
        raise SystemExit(f'Stopped: {filename} already exists with different content. Review it first.')
    if filename.endswith('.py'):
        ast.parse(content, filename=filename)

# Test generated transformation logic without touching cloud resources.
with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    for filename, content in files.items():
        if filename.endswith('.py'):
            target = root / filename
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(content)
    subprocess.run([sys.executable, '-m', 'unittest', 'discover',
                    '-s', str(root / 'Design/tests'), '-v'], check=True)

for filename, content in files.items():
    path = Path(filename)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    print('Prepared:', filename)
print('Python syntax and six transformation tests passed.')
PY
git status --short
printf '\nDESIGN PREPARATION COMPLETE. No cloud resources or container builds created.\n'
printf 'Review and commit before deployment. No commit or push performed.\n'
