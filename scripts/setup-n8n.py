#!/usr/bin/env python3
"""Set up n8n for the LeadQualifyFlow demo.

Run it after `docker compose up -d` and after creating the n8n owner account in the browser.
It does four things:
  1. creates the n8n credentials (Redis, MongoDB, Postgres, Anthropic) with fixed ids;
  2. imports the workflows from workflows/ (their nodes already point at those credential ids);
  3. publishes the main workflow and the error handler (use --extras for the optional workflows);
  4. restarts n8n so the webhooks are registered, then checks the result.

Re-running it is safe: credentials and workflows are overwritten by id.
Usage:  python3 scripts/setup-n8n.py [--extras]
"""
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MAIN = "lqfMainPipeline01"
CORE = [MAIN, "lqfErrorHandler01"]
EXTRAS = ["lqfGetTopLeads01", "lqfOpsDashboard01", "lqfReplayEvents01", "lqfSemanticSearch1"]
LOCAL_DB_PASSWORD = "leadqualifyflow_demo_local_only"  # same value as docker-compose.yml (local demo only)


def read_env():
    env = {}
    path = ROOT / ".env"
    if not path.exists():
        sys.exit("No .env file. Run: cp .env.example .env  and fill it in.")
    for line in path.read_text(encoding="utf-8").splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            key, value = line.split("=", 1)
            env[key.strip()] = value.strip()
    return env


def compose(*args, check=True):
    result = subprocess.run(["docker", "compose", *args], cwd=ROOT, capture_output=True, text=True)
    if check and result.returncode != 0:
        sys.exit(f"docker compose {' '.join(args)} failed:\n{result.stdout}{result.stderr}")
    return result


def n8n(*args, check=True):
    return compose("exec", "-T", "n8n", "n8n", *args, check=check)


def step(message):
    print(f"==> {message}", flush=True)


def http_status(url):
    try:
        return urllib.request.urlopen(url, timeout=5).status
    except urllib.error.HTTPError as err:
        return err.code
    except Exception:
        return 0


def wait_for(check, seconds, what):
    deadline = time.time() + seconds
    while time.time() < deadline:
        if check():
            return True
        time.sleep(2)
    print(f"    (timeout waiting for {what})")
    return False


def main():
    extras = "--extras" in sys.argv
    env = read_env()
    port = env.get("N8N_HOST_PORT") or "5679"
    webhook_path = env.get("N8N_WEBHOOK_PATH") or "lead-intake"
    base = f"http://127.0.0.1:{port}"
    api_key = env.get("ANTHROPIC_API_KEY", "")
    if not api_key:
        sys.exit("ANTHROPIC_API_KEY is empty in .env. Add your key, then run this script again.")

    step("Checking that n8n is running")
    running = compose("ps", "--status", "running", "--services").stdout.split()
    if "n8n" not in running:
        sys.exit("The n8n container is not running. Start it with: docker compose up -d")
    if not wait_for(lambda: http_status(f"{base}/healthz") == 200, 90, "n8n health check"):
        sys.exit(f"n8n did not answer at {base}/healthz")

    step("Creating credentials (Redis, MongoDB, Postgres, Anthropic)")
    credentials = [
        {"id": "lqf-redis", "name": "Redis (LeadQualifyFlow)", "type": "redis",
         "data": {"host": "redis", "port": 6379, "database": 0, "ssl": False}},
        {"id": "lqf-mongodb", "name": "MongoDB (LeadQualifyFlow)", "type": "mongoDb",
         "data": {"configurationType": "connectionString",
                  "connectionString": f"mongodb://leadqualifyflow:{LOCAL_DB_PASSWORD}@mongo:27017/?authSource=admin",
                  "database": "leadqualifyflow", "tls": False}},
        {"id": "lqf-postgres", "name": "Postgres (LeadQualifyFlow)", "type": "postgres",
         "data": {"host": "postgres", "port": 5432, "database": "leadqualifyflow", "user": "leadqualifyflow",
                  "password": LOCAL_DB_PASSWORD, "ssl": "disable", "allowUnauthorizedCerts": False,
                  "maxConnections": 100, "sshTunnel": False}},
        {"id": "lqf-anthropic", "name": "Anthropic (LeadQualifyFlow)", "type": "anthropicApi",
         "data": {"apiKey": api_key}},
    ]
    handle = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8")
    try:
        os.chmod(handle.name, 0o600)
        json.dump(credentials, handle)
        handle.close()
        compose("cp", handle.name, "n8n:/tmp/lqf-credentials.json")
    finally:
        os.unlink(handle.name)
    result = n8n("import:credentials", "--input=/tmp/lqf-credentials.json", check=False)
    compose("exec", "-T", "n8n", "rm", "-f", "/tmp/lqf-credentials.json", check=False)
    if result.returncode != 0:
        text = result.stdout + result.stderr
        hint = "\nHave you created the n8n owner account in the browser yet?" if "owner" in text.lower() or "user" in text.lower() else ""
        sys.exit(f"Importing credentials failed:\n{text}{hint}")

    step("Importing workflows")
    compose("exec", "-T", "n8n", "rm", "-rf", "/tmp/lqf-workflows", check=False)
    compose("cp", str(ROOT / "workflows"), "n8n:/tmp/lqf-workflows")
    result = n8n("import:workflow", "--separate", "--input=/tmp/lqf-workflows", check=False)
    print("   ", (result.stdout.strip().splitlines() or [""])[-1])
    if result.returncode != 0:
        sys.exit(f"Importing workflows failed:\n{result.stdout}{result.stderr}")

    step("Publishing workflows")
    for workflow_id in CORE + (EXTRAS if extras else []):
        result = n8n("publish:workflow", f"--id={workflow_id}", check=False)
        print(f"    {workflow_id}: {'ok' if result.returncode == 0 else 'FAILED'}")
        if result.returncode != 0:
            sys.exit(result.stdout + result.stderr)

    step("Restarting n8n so the webhooks are registered")
    compose("restart", "n8n")
    wait_for(lambda: http_status(f"{base}/healthz") == 200, 90, "n8n health check")
    registered = wait_for(lambda: http_status(f"{base}/webhook/{webhook_path}") not in (0, 404), 90, "webhook registration")

    step("Checking the saved workflow")
    n8n("export:workflow", f"--id={MAIN}", "--output=/tmp/lqf-check.json")
    exported = compose("exec", "-T", "n8n", "cat", "/tmp/lqf-check.json").stdout
    compose("exec", "-T", "n8n", "rm", "-f", "/tmp/lqf-check.json", check=False)
    workflow = json.loads(exported)
    workflow = workflow[0] if isinstance(workflow, list) else workflow
    wanted = {"redis": "lqf-redis", "mongoDb": "lqf-mongodb", "anthropicApi": "lqf-anthropic"}
    bad = [node["name"] for node in workflow["nodes"] for kind, ref in (node.get("credentials") or {}).items()
           if kind in wanted and ref.get("id") != wanted[kind]]
    if bad:
        sys.exit(f"These nodes still have no credential: {bad}")
    print("    all Redis, MongoDB and Anthropic nodes use the credentials created above")
    if not registered:
        sys.exit(f"The webhook did not register. Check: docker compose logs n8n")
    print(f"\nDone. Send a test lead:\n  curl -i -X POST {base}/webhook/{webhook_path} "
          f"-H 'Content-Type: application/json' --data @examples/hot-lead.json")


if __name__ == "__main__":
    main()
