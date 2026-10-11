#!/usr/bin/env bash
# Exercise the existing MS4 deployment. No keys, builds, or billing changes.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
EXPECTED_PROJECT='project-9ac387a6-66c9-4c04-81d'
[[ "$(gcloud config get-value project 2>/dev/null)" == "$EXPECTED_PROJECT" ]] || { echo 'Wrong active project; stopped.' >&2; exit 1; }
[[ "$(gcloud config get-value account 2>/dev/null)" == 'romyromy455@gmail.com' ]] || { echo 'Wrong active account; stopped.' >&2; exit 1; }
[[ "$(kubectl config current-context)" == "gke_${EXPECTED_PROJECT}_northamerica-northeast2-a_ms4-cluster" ]] || { echo 'Wrong Kubernetes context; stopped.' >&2; exit 1; }
[[ -x .venv/bin/python ]] || { echo 'Repository .venv is missing.' >&2; exit 1; }
export MS4_TEST_PROJECT="$EXPECTED_PROJECT"
mkdir -p evidence
EVIDENCE="evidence/voting-test-$(date -u +%Y%m%dT%H%M%SZ).txt"
.venv/bin/python -u - <<'PY' 2>&1 | tee "$EVIDENCE"
import json
import subprocess
import time
import uuid
from google.api_core.exceptions import DeadlineExceeded
from google.cloud import pubsub_v1
import os

project = os.environ['MS4_TEST_PROJECT']
publisher = pubsub_v1.PublisherClient()
subscriber = pubsub_v1.SubscriberClient()
topic = publisher.topic_path(project, 'election')
token = uuid.uuid4().hex
election = int(token[:8], 16) % 2_000_000_000 + 1
machine = int(token[8:16], 16) % 2_000_000_000 + 1
voter = int(token[16:24], 16) % 2_000_000_000 + 1
created = []

def check(condition, description):
    if not condition:
        raise RuntimeError('FAIL: ' + description)
    print('PASS:', description)

def command(arguments):
    return subprocess.check_output(arguments, text=True).strip()

def database_rows():
    sql = (f'SELECT electionid,machineid,voting FROM votes '
           f'WHERE electionid={election} ORDER BY id;')
    return command(['kubectl', '-n', 'ms4', 'exec', 'deployment/postgres-deployment',
                    '--', 'psql', '-U', 'admin', '-d', 'election', '-At', '-c', sql])

def wait_message(path, expected_uuid, seconds=45):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            response = subscriber.pull(
                request={'subscription': path, 'max_messages': 20}, timeout=5)
        except DeadlineExceeded:
            continue
        match = None
        for received in response.received_messages:
            payload = json.loads(received.message.data)
            if payload.get('UUID') == expected_uuid:
                match = payload
        if response.received_messages:
            subscriber.acknowledge(request={
                'subscription': path,
                'ack_ids': [r.ack_id for r in response.received_messages]})
        if match is not None:
            return match
    raise RuntimeError(f'No matching message within {seconds}s on {path}')

try:
    print('MS4 voting integration test')
    print('Project:', project)
    print(f'Isolated test IDs: election={election}, machine={machine}, voter={voter}')
    for name, expected_filter in (
        ('election-submit-sub', 'attributes.function="submit vote"'),
        ('election-record-sub', 'attributes.function="record vote"')):
        existing = subscriber.get_subscription(request={
            'subscription': subscriber.subscription_path(project, name)})
        check(existing.topic == topic and existing.filter == expected_filter,
              name + ' topic and filter')

    result_path = subscriber.subscription_path(project, 'ms4-test-result-' + token)
    audit_path = subscriber.subscription_path(project, 'ms4-test-record-' + token)
    for path, filter_text in (
        (result_path, f'attributes.function="result" AND attributes.machineID="{machine}"'),
        (audit_path, 'attributes.function="record vote"')):
        subscriber.create_subscription(request={
            'name': path, 'topic': topic, 'filter': filter_text,
            'expiration_policy': {'ttl': {'seconds': 86400}}})
        created.append(path)
    print('Temporary test subscriptions created before publishing.')
    check(not database_rows(), 'test election has no previous rows')

    first_uuid = str(uuid.uuid4())
    timestamp = int(time.time() * 1000)
    vote = {'machine_ID': machine, 'voter_ID': voter, 'voting': 2,
            'election_ID': election, 'UUID': first_uuid, 'timestamp': timestamp}
    publisher.publish(topic, json.dumps(vote).encode(), function='submit vote').result(timeout=30)
    first_result = wait_message(result_path, first_uuid)
    print('First response:', first_result)
    check(first_result.get('result') == 'successful', 'first vote accepted with matching UUID')
    record = wait_message(audit_path, first_uuid)
    check('voter_ID' not in record, 'forwarded record excludes voter ID')
    check(record == {'machine_ID': machine, 'voting': 2, 'election_ID': election,
                     'UUID': first_uuid}, 'forwarded record preserves vote and correlation fields')
    expected_row = f'{election}|{machine}|2'
    check(database_rows() == expected_row, 'PostgreSQL stores exactly one correct vote')
    redis_value = command(['kubectl', '-n', 'ms4', 'exec', 'deployment/redis-deployment',
                           '--', 'env', 'REDISCLI_AUTH=election', 'redis-cli', '--raw',
                           'GET', f'{voter},{election}'])
    check(redis_value == str(timestamp), 'Redis remembers voter and election')

    second_uuid = str(uuid.uuid4())
    vote.update(UUID=second_uuid, voting=4, timestamp=int(time.time() * 1000))
    publisher.publish(topic, json.dumps(vote).encode(), function='submit vote').result(timeout=30)
    second_result = wait_message(result_path, second_uuid)
    print('Repeated-voter response:', second_result)
    check(second_result.get('result') == 'Already Voted!!!', 'repeated voter rejected with matching UUID')
    # Allow asynchronous downstream activity before the final database assertion.
    time.sleep(3)
    check(database_rows() == expected_row, 'rejected vote creates no additional database row')
    print('ALL VOTING TESTS PASSED.')
    print('This verifies sequential voting, not concurrent delivery or failure recovery.')
    print('The isolated test row and Redis key remain as demonstration evidence.')
finally:
    for path in reversed(created):
        try:
            subscriber.delete_subscription(request={'subscription': path})
            print('Removed temporary subscription:', path.rsplit('/', 1)[-1])
        except Exception as error:
            print('Temporary subscription cleanup failed:', type(error).__name__)
            print('Subscription to remove:', path)
    subscriber.close()
    publisher.stop()
PY
printf '\nTest evidence saved to %s\n' "$EVIDENCE"
printf 'Existing cluster and databases remain running. No commit or push performed.\n'
