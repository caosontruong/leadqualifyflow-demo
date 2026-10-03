#!/usr/bin/env bash
# Measures end-to-end latency from sending a lead to the Slack message.
#   ack latency   = from sending the request to HTTP 200 (curl time_total)
#   alert latency = from n8n receiving the webhook to the Slack node finishing (node timestamps in the n8n execution)
# Every lead uses DIFFERENT content (avoids dedup and the AI cache). The first 2 runs are warm-up (reported separately).
# Usage:  scripts/measure-latency.sh [RUNS=12] [GAP_SECONDS=20] [LABEL=run]
#         (example labels: minimal | full; result file: results/latency_runs_<label>.json)
# Requires: the stack started with docker compose and scripts/setup-n8n.py done. Reads N8N_API_KEY / N8N_WEBHOOK_PATH from the local .env; prints measurements only, never secrets.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
export N_RUNS="${1:-12}" GAP="${2:-20}" LABEL="${3:-run}"
export BASE="${N8N_BASE:-http://127.0.0.1:${N8N_HOST_PORT:-5679}}"
export WEBHOOK_PATH="${N8N_WEBHOOK_PATH:-lead-intake}"
export WORKFLOW_ID="${LQF_WORKFLOW_ID:-lqfMainPipeline01}"
: "${N8N_API_KEY:?N8N_API_KEY is missing in .env (create it in the n8n UI: Settings -> n8n API)}"
export OUT="results/latency_runs_${LABEL}.json"
python3 - <<'PY'
import json, os, statistics, subprocess, time, urllib.request, urllib.error, uuid, sys, datetime

BASE=os.environ["BASE"]; WP=os.environ["WEBHOOK_PATH"]; WF=os.environ["WORKFLOW_ID"]
KEY=os.environ["N8N_API_KEY"]; N=int(os.environ["N_RUNS"]); GAP=int(os.environ["GAP"]); OUT=os.environ["OUT"]; LABEL=os.environ["LABEL"]
WARM=2; RUN_ID=uuid.uuid4().hex[:6]

def unflatted(text):
    arr=json.loads(text); memo={}
    def res(i):
        if i in memo: return memo[i]
        e=arr[i]
        if isinstance(e,str): memo[i]=e; return e
        if isinstance(e,dict):
            o={}; memo[i]=o
            for k,v in e.items(): o[k]=ref(v)
            return o
        if isinstance(e,list):
            l=[]; memo[i]=l
            for v in e: l.append(ref(v))
            return l
        memo[i]=e; return e
    def ref(v): return res(int(v)) if isinstance(v,str) else v
    return res(0)

def api(path):
    req=urllib.request.Request(BASE+path, headers={"X-N8N-API-KEY":KEY,"accept":"application/json"})
    with urllib.request.urlopen(req, timeout=20) as r: return json.load(r)

def node_times(run_data, name):
    rs=run_data.get(name)
    if not rs: return None
    r=rs[0]; return r["startTime"], r["startTime"]+r["executionTime"]

PHRASES=[
 "We just got budget approval and want to roll this out next week, please send me a quote for the Pro plan",
 "Our director approved the budget this morning; we need to start onboarding next Monday. Can you send pricing for 50 seats?",
 "Budget is signed off for this quarter and we plan to go live within two weeks. Please share a quote and a start date.",
 "We have approval to purchase and want to kick off immediately. What is the price for the annual plan?",
]
def payload(n):
    marker=f"LQF-LAT-{RUN_ID}-{n:02d}"
    return {"name":f"Latency Test {marker}","email":f"latency.{RUN_ID}.{n:02d}@example.com",
            "phone":f"+1555010{n:04d}"[:12],"message":f"[{marker}] "+PHRASES[n%len(PHRASES)],"source":"typeform"}, marker

def find_execution(marker, tries=40):
    for _ in range(tries):
        lst=api(f"/api/v1/executions?workflowId={WF}&includeData=true&limit=15")
        for ex in lst.get("data",[]):
            d=ex.get("data")
            if isinstance(d,str): d=unflatted(d)
            if not d: continue
            blob=json.dumps(d.get("resultData",{}).get("runData",{}).get("Webhook - Lead Intake",[{}])[0].get("data",{}),ensure_ascii=False)
            if marker in blob:
                rd=d["resultData"]["runData"]
                if "Notify Slack (Hot Lead)" in rd or ex.get("finished"):
                    return ex, rd
        time.sleep(1.5)
    return None, None

def container_flags():
    try:
        o=subprocess.run(["docker","compose","exec","-T","n8n","sh","-c","printenv | grep '^ENABLE_'"],capture_output=True,text=True,timeout=20).stdout
        return dict(l.split("=",1) for l in sorted(o.strip().splitlines()) if "=" in l)
    except Exception as e:
        return {"error":str(e)}
def running():
    try:
        o=subprocess.run(["docker","compose","ps","--status","running","--services"],capture_output=True,text=True,timeout=20).stdout.split()
        return sorted(o)
    except Exception: return []
FLAGS=container_flags(); CONTAINERS=running()
rows=[]
total=WARM+N
print(f"Measuring [{LABEL}] {total} leads ({WARM} warm-up + {N} measured), {GAP}s apart, run={RUN_ID}, {datetime.datetime.utcnow().isoformat()}Z", flush=True)
print("ENABLE_* configuration:", json.dumps(FLAGS), flush=True)
for n in range(total):
    body,marker=payload(n)
    data=json.dumps(body).encode()
    t_send=time.time()
    out=subprocess.run(["curl","-s","-o","/dev/null","-w","%{http_code} %{time_total}","-X","POST",
        f"{BASE}/webhook/{WP}","-H","Content-Type: application/json","-d",data.decode()],capture_output=True,text=True).stdout.split()
    code,ack=out[0],float(out[1])*1000
    ex,rd=find_execution(marker)
    row={"n":n,"warmup":n<WARM,"marker":marker,"http":code,"ack_ms":round(ack,1),"slack":False}
    if rd:
        row["exec_status"]=ex.get("status")
        row["node_errors"]=[k for k,v in rd.items() if v and v[0].get("error")]
        wh=node_times(rd,"Webhook - Lead Intake"); sl=node_times(rd,"Notify Slack (Hot Lead)")
        acc=node_times(rd,"Respond 200 (Accepted)"); late=node_times(rd,"Respond 200")
        if wh: row["webhook_to_clientsend_gap_ms"]=round(wh[0]-t_send*1000,1)
        if wh and acc: row["accepted_at_ms"]=acc[0]-wh[0]
        if wh and late: row["late_respond_at_ms"]=late[0]-wh[0]
        if wh and sl: row["slack"]=True; row["slack_start_ms"]=sl[0]-wh[0]; row["alert_ms"]=sl[1]-wh[0]
        row["classification_class"]="hot" if sl else "not-hot/none"
    rows.append(row)
    print(f"  #{n:02d}{' (warm-up)' if n<WARM else ''}: http={code} ack={row['ack_ms']}ms"+
          (f" alert={row['alert_ms']}ms" if row.get('slack') else " alert=- (no Slack message)"), flush=True)
    if n<total-1: time.sleep(GAP)

def stats(vals):
    if not vals: return None
    v=sorted(vals); p90=v[min(len(v)-1,int(round(0.9*(len(v)-1))))]
    return {"n":len(v),"min":round(v[0],1),"median":round(statistics.median(v),1),"p90":round(p90,1),"max":round(v[-1],1)}
meas=[r for r in rows if not r["warmup"]]
summary={"label":LABEL,"enable_flags":FLAGS,"containers_running":CONTAINERS,"run_id":RUN_ID,"utc":datetime.datetime.utcnow().isoformat()+"Z","runs":N,"warmup":WARM,"gap_s":GAP,
 "ack_ms":stats([r["ack_ms"] for r in meas]),
 "alert_ms":stats([r["alert_ms"] for r in meas if r.get("slack")]),
 "runs_with_node_errors":sum(1 for r in meas if r.get("node_errors")),
 "no_slack_count":sum(1 for r in meas if not r.get("slack")),
 "warmup_alert_ms":[r.get("alert_ms") for r in rows if r["warmup"]]}
json.dump({"summary":summary,"rows":rows},open(OUT,"w"),ensure_ascii=False,indent=2)
print("\n=== SUMMARY (warm-up excluded) ===")
print(json.dumps(summary,ensure_ascii=False,indent=2))
print(f"\nWrote {OUT}")
PY
