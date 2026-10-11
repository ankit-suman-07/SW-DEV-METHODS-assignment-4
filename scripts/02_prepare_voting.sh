#!/usr/bin/env bash
# Prepare local voting code. No cloud resource, credential or billing mutations.
set -Eeuo pipefail
trap 'printf "\nStopped at line %s. Resolve the error above before continuing.\n" "$LINENO" >&2' ERR
readonly EXPECTED_PROJECT='project-9ac387a6-66c9-4c04-81d'
readonly EXPECTED_ACCOUNT='romyromy455@gmail.com'
for tool in git gcloud python3; do
  command -v "$tool" >/dev/null || { printf 'Missing tool: %s\n' "$tool" >&2; exit 1; }
done
TASK_ROOT=$(git rev-parse --show-toplevel)
cd "$TASK_ROOT"
[[ -f .env.ms4 ]] || { printf 'Run script 1 first.\n' >&2; exit 1; }
[[ "$(gcloud config get-value project 2>/dev/null)" == "$EXPECTED_PROJECT" ]] || {
  printf 'Wrong active project; no changes made.\n' >&2; exit 1;
}
[[ "$(gcloud config get-value account 2>/dev/null)" == "$EXPECTED_ACCOUNT" ]] || {
  printf 'Wrong active account; no changes made.\n' >&2; exit 1;
}

printf '\n[1/3] Preparing authentication and project configuration\n'
python3 - "$EXPECTED_PROJECT" <<'PY'
import ast
import pathlib
import re
import sys

project = sys.argv[1]
planned = {}
marker = '# MS4: use Application Default Credentials (no embedded key files).'
for folder in ('voting_logger', 'voting_record', 'voting_machine'):
    file = pathlib.Path(folder) / 'main.py'
    text = file.read_text()
    if marker not in text:
        end_marker = '#To do:' if folder == 'voting_machine' else '# Get the environment variables'
        start = text.find('# Search the current directory')
        end = text.find(end_marker, start)
        if start < 0 or end < 0:
            raise SystemExit(f'Unexpected authentication block in {file}; no files changed.')
        text = text[:start] + marker + '\n# GKE uses Workload Identity; Cloud Shell uses locally authorized ADC.\n\n' + text[end:]
    text = re.sub(r'print\(files\[0\]\);?', 'print("Authentication: Application Default Credentials")', text)
    if folder == 'voting_machine':
        text, count = re.subn(
            r'^project_id\s*=.*$',
            f'project_id = os.environ.get("GCP_PROJECT", "{project}")',
            text, count=1, flags=re.MULTILINE)
        if count != 1:
            raise SystemExit(f'Project configuration not found in {file}; no files changed.')
    ast.parse(text, filename=str(file))
    if 'files[0]' in text or 'COPY *.json' in text:
        raise SystemExit(f'Unresolved credential dependency in {file}; no files changed.')
    planned[file] = text

dependencies = {
    'voting_logger': 'google-cloud-pubsub\nredis\n',
    'voting_record': 'google-cloud-pubsub\npsycopg2-binary\n',
    'voting_machine': 'google-cloud-pubsub\n',
}
for folder, requirements in dependencies.items():
    planned[pathlib.Path(folder) / 'requirements.txt'] = requirements
    if folder != 'voting_machine':
        planned[pathlib.Path(folder) / 'Dockerfile'] = '''FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt \\
    && useradd --uid 10001 --create-home appuser
COPY main.py ./
USER appuser
CMD ["python", "-u", "main.py"]
'''
        exclusions = '''*.json
.env
.env.*
.venv/
__pycache__/
*.pyc
.git/
'''
        # Preserve any existing exclusions instead of replacing them.
        for name in ('.dockerignore', '.gcloudignore'):
            target = pathlib.Path(folder) / name
            old = target.read_text() if target.exists() else ''
            lines = old.splitlines()
            for rule in exclusions.splitlines():
                if rule not in lines:
                    lines.append(rule)
            planned[target] = '\n'.join(lines) + '\n'

# Verify all source files before writing any planned changes.
for path, content in planned.items():
    path.write_text(content)
    print(f'Prepared: {path}')
PY

printf '\n[2/3] Checking Python syntax and container credential exclusions\n'
python3 - <<'PY'
import ast
from pathlib import Path
for folder in ('voting_logger', 'voting_record', 'voting_machine'):
    path = Path(folder) / 'main.py'
    ast.parse(path.read_text(), filename=str(path))
    print(f'Syntax OK: {path}')
for folder in ('voting_logger', 'voting_record'):
    text = (Path(folder) / 'Dockerfile').read_text()
    assert 'COPY *.json' not in text
    assert 'COPY . ' not in text
    assert 'COPY main.py ./' in text
    assert '*.json' in (Path(folder) / '.dockerignore').read_text().splitlines()
    print(f'Explicit code-only COPY checked: {folder}/Dockerfile')
PY

printf '\n[3/3] Reviewing pending Git changes\n'
git diff --stat
git status --short
printf '\nSUCCESS: Voting source files are prepared.\n'
printf 'Dependencies have been declared, not installed or executed.\n'
printf 'The deployment script must enable Workload Identity and assign the voting Kubernetes service account.\n'
printf 'The Cloud Shell voting machine will need ADC authorization before its live test.\n'
printf 'No cloud resources, keys, billing changes, commits or pushes were created.\n'
