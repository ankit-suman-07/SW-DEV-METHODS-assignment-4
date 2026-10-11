#!/usr/bin/env bash
# Prepare or deploy two workers and a native BigQuery export subscription.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
MODE="${1:---prepare-only}"
[[ "$MODE" == '--prepare-only' || "$MODE" == '--deploy' ]] || { echo 'Use --prepare-only or --deploy'; exit 1; }
export MS4_DESIGN_MODE="$MODE"
python3 -u - <<'PY'
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

PROJECT = 'project-9ac387a6-66c9-4c04-81d'
REGION = 'northamerica-northeast2'
CLUSTER = 'ms4-cluster'
ZONE = REGION + '-a'
NAMESPACE = 'ms4'
TOPIC = 'smartMeterDesign'
DATASET = 'ms4_design'
TABLE = 'converted_readings'
TABLE_RESOURCE = f'{PROJECT}:{DATASET}.{TABLE}'
TABLE_API = f'{PROJECT}.{DATASET}.{TABLE}'
REPO = f'{REGION}-docker.pkg.dev/{PROJECT}/sofe4630u'
SCHEMA = [('ID', 'STRING'), ('time', 'INTEGER'), ('profile_name', 'STRING'),
          ('temperature', 'FLOAT'), ('humidity', 'FLOAT'), ('pressure', 'FLOAT')]

def run(args, capture=False):
    if not capture:
        print('Running:', ' '.join(args), flush=True)
    result = subprocess.run(args, check=True, text=True,
                            stdout=subprocess.PIPE if capture else None)
    return result.stdout.strip() if capture else ''

def probe_json(args):
    result = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        return None
    return json.loads(result.stdout)

if not all(Path(name).is_dir() for name in ['voting_logger', 'voting_record', 'Design']):
    raise SystemExit('Stopped: expected MS4 repository and prepared Design directory.')
for filename in ['Design/filter_reading/Dockerfile', 'Design/convert_reading/Dockerfile',
                 'Design/producer.py', 'Design/common/transforms.py']:
    if not Path(filename).is_file():
        raise SystemExit('Missing preparation file: ' + filename)

tag = run(['git', 'rev-parse', '--short=12', 'HEAD'], capture=True) + '-design'
images = {'filter': f'{REPO}/filter-reading:{tag}',
          'convert': f'{REPO}/convert-reading:{tag}'}
items = []
for stage, subscription in [('filter', 'ms4-reading-filter-sub'),
                            ('convert', 'ms4-reading-convert-sub')]:
    name = f'{stage}-reading-deployment'
    app = f'{stage}-reading'
    items.append({
        'apiVersion': 'apps/v1', 'kind': 'Deployment',
        'metadata': {'name': name, 'namespace': NAMESPACE, 'labels': {'assignment': 'ms4'}},
        'spec': {'replicas': 1, 'selector': {'matchLabels': {'app': app}},
                 'template': {'metadata': {'labels': {'app': app}},
                              'spec': {'serviceAccountName': 'ms4-voting',
                                       'containers': [{'name': app, 'image': images[stage],
                                           'env': [{'name': 'GCP_PROJECT', 'value': PROJECT},
                                                   {'name': 'TOPIC_NAME', 'value': TOPIC},
                                                   {'name': 'SUBSCRIPTION_ID', 'value': subscription}],
                                           'resources': {'requests': {'cpu': '100m', 'memory': '128Mi'},
                                                         'limits': {'cpu': '500m', 'memory': '256Mi'}}}]}}}})
Path('deploy').mkdir(exist_ok=True)
# JSON is valid YAML and kubectl accepts a Kubernetes List manifest.
Path('deploy/design-services.yaml').write_text(json.dumps(
    {'apiVersion': 'v1', 'kind': 'List', 'items': items}, indent=2) + '\n')
Path('deploy/design-table.sql').write_text(
    f'CREATE TABLE IF NOT EXISTS `{TABLE_API}` (\n'
    '  ID STRING,\n  time INT64,\n  profile_name STRING,\n'
    '  temperature FLOAT64 OPTIONS(description="Temperature in Fahrenheit"),\n'
    '  humidity FLOAT64 OPTIONS(description="Relative humidity in percent"),\n'
    '  pressure FLOAT64 OPTIONS(description="Pressure in psi")\n);\n')
Path('deploy/design-config.sh').write_text(
    '# Non-secret MS4 design configuration\n'
    f'export GCP_PROJECT="{PROJECT}"\nexport DESIGN_TOPIC="{TOPIC}"\n'
    f'export BQ_DATASET="{DATASET}"\nexport BQ_TABLE="{TABLE}"\n'
    f'export BQ_LOCATION="{REGION}"\n')
print('Prepared deploy/design-services.yaml, design-table.sql, design-config.sh')

if os.environ['MS4_DESIGN_MODE'] == '--prepare-only':
    run(['git', 'status', '--short'])
    print('PREPARATION COMPLETE. No cloud resources or image builds created.')
    print('Review and commit before running --deploy.')
    raise SystemExit(0)

for tool in ['gcloud', 'bq', 'docker', 'kubectl']:
    if not shutil.which(tool):
        raise SystemExit('Missing tool: ' + tool)
if run(['gcloud', 'config', 'get-value', 'project'], capture=True) != PROJECT:
    raise SystemExit('Wrong active project; stopped.')
if run(['gcloud', 'config', 'get-value', 'account'], capture=True) != 'romyromy455@gmail.com':
    raise SystemExit('Wrong active account; stopped.')
if run(['kubectl', 'config', 'current-context'], capture=True) != f'gke_{PROJECT}_{ZONE}_{CLUSTER}':
    raise SystemExit('Wrong Kubernetes context; stopped.')
cluster = json.loads(run(['gcloud', 'container', 'clusters', 'describe', CLUSTER,
                         '--zone=' + ZONE, '--project=' + PROJECT, '--format=json'], capture=True))
if (cluster.get('resourceLabels', {}).get('assignment') != 'ms4' or
    cluster.get('workloadIdentityConfig', {}).get('workloadPool') != PROJECT + '.svc.id.goog'):
    raise SystemExit('Cluster ownership or Workload Identity settings do not match.')
run(['kubectl', '-n', NAMESPACE, 'get', 'serviceaccount', 'ms4-voting'])
run(['docker', 'info'], capture=True)

try:
    print('[1/5] Building and pushing two design images')
    run(['gcloud', 'auth', 'configure-docker', REGION + '-docker.pkg.dev', '--quiet'])
    for stage, folder in [('filter', 'filter_reading'), ('convert', 'convert_reading')]:
        run(['docker', 'build', '-f', f'Design/{folder}/Dockerfile', '-t', images[stage], 'Design'])
        run(['docker', 'push', images[stage]])

    print('[2/5] Ensuring the single design topic exists')
    gc = ['--project=' + PROJECT, '--quiet']
    topic = probe_json(['gcloud', 'pubsub', 'topics', 'describe', TOPIC, '--format=json', *gc])
    if topic is None:
        run(['gcloud', 'pubsub', 'topics', 'create', TOPIC, '--labels=assignment=ms4', *gc])

    print('[3/5] Preparing the BigQuery dataset, table, and table-scoped export permission')
    bq = ['bq', '--project_id=' + PROJECT, '--location=' + REGION]
    dataset = probe_json([*bq, '--format=json', 'show', '--dataset', f'{PROJECT}:{DATASET}'])
    if dataset is None:
        run([*bq, 'mk', '--dataset', '--description=MS4 smart-meter design', f'{PROJECT}:{DATASET}'])
    elif dataset.get('location', '').lower() != REGION:
        raise RuntimeError('Existing dataset is in a different location; stopped.')
    run([*bq, 'query', '--use_legacy_sql=false', '--maximum_bytes_billed=1000000',
         Path('deploy/design-table.sql').read_text()])
    table = probe_json([*bq, '--format=json', 'show', TABLE_RESOURCE])
    if table is None:
        raise RuntimeError('BigQuery table could not be inspected.')
    actual_schema = [(f['name'], f['type']) for f in table['schema']['fields']]
    if actual_schema != SCHEMA:
        raise RuntimeError('Existing BigQuery table schema does not match; no schema overwritten.')
    number = run(['gcloud', 'projects', 'describe', PROJECT,
                  '--format=value(projectNumber)'], capture=True)
    agent = f'service-{number}@gcp-sa-pubsub.iam.gserviceaccount.com'
    run([*bq, 'add-iam-policy-binding', '--member=serviceAccount:' + agent,
         '--role=roles/bigquery.dataEditor', '--table=true', TABLE_RESOURCE])

    print('[4/5] Creating and checking the three filtered subscriptions')
    for name, function in [('ms4-reading-filter-sub', 'raw'),
                           ('ms4-reading-convert-sub', 'filtered'),
                           ('ms4-reading-bigquery-sub', 'converted')]:
        expected_filter = f'attributes.function="{function}"'
        description = probe_json(['gcloud', 'pubsub', 'subscriptions', 'describe',
                                  name, '--format=json', *gc])
        if description is None:
            args = ['gcloud', 'pubsub', 'subscriptions', 'create', name,
                    '--topic=' + TOPIC, '--message-filter=' + expected_filter,
                    '--labels=assignment=ms4', '--expiration-period=never', *gc]
            if function == 'converted':
                args += ['--bigquery-table=' + TABLE_RESOURCE, '--use-table-schema']
            # A newly granted table IAM role can take time to propagate.
            for attempt in range(6):
                result = subprocess.run(args)
                if result.returncode == 0:
                    break
                if function != 'converted' or attempt == 5:
                    raise RuntimeError('Subscription creation failed: ' + name)
                print('Retrying BigQuery subscription after IAM propagation wait...')
                time.sleep(10)
            description = json.loads(run(['gcloud', 'pubsub', 'subscriptions', 'describe',
                                          name, '--format=json', *gc], capture=True))
        if (description.get('topic') != f'projects/{PROJECT}/topics/{TOPIC}' or
            description.get('filter') != expected_filter):
            raise RuntimeError('Existing subscription has different topic or filter: ' + name)
        config = description.get('bigqueryConfig', {})
        if function == 'converted':
            if config.get('table') != TABLE_API or not config.get('useTableSchema'):
                raise RuntimeError('Existing BigQuery subscription configuration differs; stopped.')
        elif config or description.get('pushConfig', {}).get('pushEndpoint'):
            raise RuntimeError('Expected a pull subscription for worker: ' + name)
        print('Verified:', name, expected_filter)

    print('[5/5] Deploying both workers in the existing cluster')
    run(['kubectl', '-n', NAMESPACE, 'apply', '-f', 'deploy/design-services.yaml'])
    for stage in ['filter', 'convert']:
        run(['kubectl', '-n', NAMESPACE, 'rollout', 'status',
             f'deployment/{stage}-reading-deployment', '--timeout=300s'])
    run(['kubectl', '-n', NAMESPACE, 'get', 'pods'])
    run(['gcloud', 'pubsub', 'subscriptions', 'describe', 'ms4-reading-bigquery-sub',
         '--format=yaml(name,filter,bigqueryConfig)', *gc])
    print('DESIGN DEPLOYMENT COMPLETE. Live transformation/export tests are next.')
    print('Reused existing cluster; no new database workers or public load balancers.')
    print('No keys, billing upgrade, commit, push, or continuous producer started.')
    run(['git', 'status', '--short'])
except Exception:
    print('Deployment stopped. No resources automatically deleted; existing resources keep running.')
    subprocess.run(['kubectl', '-n', NAMESPACE, 'get', 'pods'])
    subprocess.run(['kubectl', '-n', NAMESPACE, 'get', 'events', '--sort-by=.lastTimestamp'])
    raise
PY
