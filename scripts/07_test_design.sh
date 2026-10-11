#!/usr/bin/env bash
# Six-message integration test; no continuous producer or new compute resources.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
PROJECT='project-9ac387a6-66c9-4c04-81d'
[[ "$(gcloud config get-value project 2>/dev/null)" == "$PROJECT" ]] || { echo 'Wrong active project; stopped.' >&2; exit 1; }
[[ "$(gcloud config get-value account 2>/dev/null)" == 'romyromy455@gmail.com' ]] || { echo 'Wrong active account; stopped.' >&2; exit 1; }
[[ "$(kubectl config current-context)" == "gke_${PROJECT}_northamerica-northeast2-a_ms4-cluster" ]] || { echo 'Wrong Kubernetes context; stopped.' >&2; exit 1; }
[[ -x .venv/bin/python ]] || { echo 'Repository .venv is missing.' >&2; exit 1; }
command -v bq >/dev/null
mkdir -p evidence
EVIDENCE="evidence/design-test-$(date -u +%Y%m%dT%H%M%SZ).txt"
.venv/bin/python -u - <<'PY' 2>&1 | tee "$EVIDENCE"
import json
import math
import subprocess
import threading
import time
import uuid
from google.cloud import pubsub_v1

PROJECT = 'project-9ac387a6-66c9-4c04-81d'
REGION = 'northamerica-northeast2'
TOPIC = 'smartMeterDesign'
TABLE = PROJECT + '.ms4_design.converted_readings'
publisher = pubsub_v1.PublisherClient()
subscriber = pubsub_v1.SubscriberClient()
topic_path = publisher.topic_path(PROJECT, TOPIC)
token = uuid.uuid4().hex
prefix = 'ms4-test-' + token + '-'
audit_path = subscriber.subscription_path(PROJECT, 'ms4-design-test-' + token)
created = False
stream = None
seen = {'filtered': [], 'converted': []}
lock = threading.Lock()
ready = threading.Event()

def check(condition, description):
    if not condition:
        raise RuntimeError('FAIL: ' + description)
    print('PASS:', description)

def record(suffix, temperature, humidity, pressure):
    return {'ID': prefix + suffix, 'time': int(time.time()), 'profile_name': 'design-test',
            'temperature': temperature, 'humidity': humidity, 'pressure': pressure}

valid = [record('known', 20, 50, 6.895), record('zero', 0, 0, 0),
         record('negative', -40, 75, 13.79)]
invalid = [record('missing-temperature', None, 50, 6.895),
           record('missing-humidity', 20, None, 6.895),
           record('missing-pressure', 20, 50, None)]
valid_ids = {r['ID'] for r in valid}
invalid_ids = {r['ID'] for r in invalid}

def callback(message):
    try:
        data = json.loads(message.data)
        if isinstance(data, dict) and str(data.get('ID', '')).startswith(prefix):
            function = message.attributes.get('function')
            with lock:
                if function in seen:
                    seen[function].append(data)
                if valid_ids <= {r['ID'] for r in seen['converted']}:
                    ready.set()
            print('Observed', function + ':', data)
    finally:
        message.ack()

def query_rows():
    # prefix is internally generated from UUID hex, never taken from user input.
    sql = (f'SELECT ID,time,profile_name,temperature,humidity,pressure FROM `{TABLE}` '
           f"WHERE STARTS_WITH(ID, '{prefix}') ORDER BY ID LIMIT 100")
    result = subprocess.run(
        ['bq', '--project_id=' + PROJECT, '--location=' + REGION, '--format=json',
         'query', '--use_legacy_sql=false', '--use_cache=false',
         '--maximum_bytes_billed=20000000', sql],
        text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
    if result.returncode:
        raise RuntimeError('BigQuery query failed: ' + result.stderr + result.stdout)
    return json.loads(result.stdout)

def same_reading(actual, expected, converted=False):
    for field in ['ID', 'profile_name']:
        if actual.get(field) != expected[field]:
            return False
    if int(actual['time']) != expected['time']:
        return False
    for field in ['temperature', 'humidity', 'pressure']:
        value = expected[field]
        if converted and field == 'temperature':
            value = value * 1.8 + 32
        if converted and field == 'pressure':
            value = value / 6.895
        if not math.isclose(float(actual[field]), value, rel_tol=1e-9, abs_tol=1e-9):
            return False
    return True

try:
    print('MS4 smart-meter integration test; six input messages')
    print('Run prefix:', prefix)
    for name, function in [('ms4-reading-filter-sub', 'raw'),
                           ('ms4-reading-convert-sub', 'filtered'),
                           ('ms4-reading-bigquery-sub', 'converted')]:
        sub = subscriber.get_subscription(request={
            'subscription': subscriber.subscription_path(PROJECT, name)})
        check(sub.topic == topic_path and sub.filter == f'attributes.function="{function}"',
              name + ' has the correct topic and filter')
        if function == 'converted':
            check(sub.bigquery_config.table in (TABLE, PROJECT + ':ms4_design.converted_readings')
                  and sub.bigquery_config.use_table_schema,
                  'native BigQuery export points to the expected table and uses its schema')

    subscriber.create_subscription(request={
        'name': audit_path, 'topic': topic_path,
        'filter': 'attributes.function="filtered" OR attributes.function="converted"',
        'expiration_policy': {'ttl': {'seconds': 86400}}})
    created = True
    stream = subscriber.subscribe(audit_path, callback=callback)
    for data in valid + invalid:
        publisher.publish(topic_path, json.dumps(data).encode('utf-8'),
                          function='raw').result(timeout=30)
        print('Published raw:', data)
    check(ready.wait(90), 'all three valid readings reached the converted stage')

    print('Waiting for the native BigQuery subscription to export results...')
    rows = []
    for attempt in range(10):
        rows = query_rows()
        if valid_ids <= {r['ID'] for r in rows}:
            break
        print(f'Export check {attempt + 1}/10: {len(rows)} test rows so far')
        time.sleep(15)
    check(valid_ids <= {r['ID'] for r in rows}, 'all valid readings automatically exported to BigQuery')

    # Give missing-input messages an additional observation window.
    time.sleep(15)
    rows = query_rows()
    with lock:
        snapshot = {stage: list(values) for stage, values in seen.items()}
    expected_by_id = {r['ID']: r for r in valid}
    for stage, values in snapshot.items():
        ids = {r['ID'] for r in values}
        check(ids == valid_ids, stage + ' stage contains only the three valid test IDs')
        check(not ids & invalid_ids, stage + ' stage excludes every missing-measurement test ID')
        check(all(same_reading(r, expected_by_id[r['ID']], stage == 'converted') for r in values),
              stage + ' values and metadata match the expected transformation')
    check({r['ID'] for r in rows} == valid_ids, 'BigQuery contains no missing-measurement test IDs')
    check(all(same_reading(r, expected_by_id[r['ID']], converted=True) for r in rows),
          'BigQuery stores Fahrenheit, psi, unchanged humidity, and matching metadata')
    print('BigQuery evidence rows:')
    print(json.dumps(rows, indent=2))
    print(f'Exported rows={len(rows)}, unique valid IDs={len(valid_ids)}')
    print('ALL DESIGN TESTS PASSED.')
    print('At-least-once duplicates are allowed only when their values match.')
    print('Missing-record exclusion is checked over a bounded observation window.')
    print('Test rows remain in BigQuery as demonstration evidence.')
finally:
    if stream is not None:
        stream.cancel()
        try:
            stream.result(timeout=10)
        except Exception:
            pass
    if created:
        try:
            subscriber.delete_subscription(request={'subscription': audit_path})
            print('Removed temporary audit subscription:', audit_path.rsplit('/', 1)[-1])
        except Exception as error:
            print('Audit cleanup failed:', type(error).__name__, audit_path)
    subscriber.close()
    publisher.stop()
PY
printf '\nTest evidence saved to %s\n' "$EVIDENCE"
printf 'No cluster, key, billing change, commit, or push created. Existing resources remain running.\n'
