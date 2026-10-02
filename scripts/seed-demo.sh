#!/usr/bin/env bash
# Seeds the demo dataset (data/demo-dataset.json) into the REAL pipeline through the webhook, then reads
# the results produced by the pipeline (Classification, Confidence, Lead Score, Draft Reply) from the n8n
# executions. Outputs are never edited by hand.
# It writes to the Airtable base / Slack webhook configured in .env, so point those at DEMO targets first.
# Usage:  scripts/seed-demo.sh <select> [GAP_SECONDS=12] [-y]
#   <select> = en | vi | all | comma-separated record IDs (e.g. VI-01 or EN-01,EN-02)
# Output: results/demo-run-<timestamp>.json  (provenance label: sample-data)
# Requires: LQF_WORKFLOW_ID (the id of the imported "LeadQualifyFlow - MVP-01" workflow, visible in its n8n URL)
set -euo pipefail
cd "$(dirname "$0")/.."
SEL="${1:-}"; GAP="${2:-12}"; YES="${3:-}"
[ -n "$SEL" ] || { sed -n 2,10p "$0"; exit 2; }
[ "$GAP" = "-y" ] && { YES="-y"; GAP=12; }
set -a; . ./.env; set +a
: "${N8N_API_KEY:?N8N_API_KEY is missing in .env}"
: "${LQF_WORKFLOW_ID:?Set LQF_WORKFLOW_ID to the id of the imported MVP-01 workflow}"
export SEL GAP BASE="${N8N_BASE:-http://127.0.0.1:5679}" WEBHOOK_PATH="${N8N_WEBHOOK_PATH:-lead-intake}" WORKFLOW_ID="$LQF_WORKFLOW_ID"
echo "Current targets: Airtable base ...${AIRTABLE_BASE_ID: -4}, table '${AIRTABLE_TABLE_NAME:-?}'; Slack webhook ...${SLACK_WEBHOOK_URL: -4}"
echo "ENABLE_* flags in the container:"; docker exec leadqualifyflow-n8n sh -c "printenv | grep '^ENABLE_'" | sort | sed 's/^/  /'
if [ "$YES" != "-y" ]; then read -r -p "Are these DEMO targets (not a real base/channel)? Type y to continue: " a; [ "$a" = "y" ] || { echo "Stopped."; exit 1; }; fi
python3 - <<'PY'
import json, os, re, subprocess, time, urllib.request, datetime
BASE=os.environ["BASE"]; WP=os.environ["WEBHOOK_PATH"]; WF=os.environ["WORKFLOW_ID"]; KEY=os.environ["N8N_API_KEY"]
SEL=os.environ["SEL"]; GAP=int(os.environ["GAP"])
ds=json.load(open("data/demo-dataset.json"))["records"]
if SEL=="all": recs=ds
elif SEL in ("en","vi"): recs=[r for r in ds if r["locale"]==SEL]
else:
    ids=[x.strip() for x in SEL.split(",")]; recs=[r for r in ds if r["id"] in ids]
if not recs: raise SystemExit("No record selected")

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
VI=re.compile(r"[ăâđêôơưàáạảãằắặẳẵầấậẩẫèéẹẻẽềếệểễìíịỉĩòóọỏõồốộổỗờớợởỡùúụủũừứựửữỳýỵỷỹ]",re.I)
def find(name, since, tries=40):
    """Find the NEWEST execution for persona `name` that started after the send time (avoids picking an older execution with the same name)."""
    for _ in range(tries):
        best=None
        for ex in api(f"/api/v1/executions?workflowId={WF}&includeData=true&limit=20").get("data",[]):
            st=ex.get("startedAt")
            if st and datetime.datetime.fromisoformat(st.replace("Z","+00:00")).timestamp() < since-2: continue
            d=ex.get("data")
            if isinstance(d,str): d=unflatted(d)
            if not d: continue
            rd=d.get("resultData",{}).get("runData",{})
            blob=json.dumps(rd.get("Webhook - Lead Intake",[{}])[0].get("data",{}),ensure_ascii=False)
            if name in blob and ("Format Lead" in rd or ex.get("finished")):
                if best is None or int(ex["id"])>int(best[0]["id"]): best=(ex,rd)
        if best: return best
        time.sleep(1.5)
    return None, None

out=[]
print(f"Seeding {len(recs)} records, {GAP}s apart", flush=True)
for i,r in enumerate(recs):
    p=r["payload"]
    t_send=time.time()
    res=subprocess.run(["curl","-s","-o","/dev/null","-w","%{http_code}","-X","POST",f"{BASE}/webhook/{WP}","-H","Content-Type: application/json","--data-binary",json.dumps(p,ensure_ascii=False)],capture_output=True,text=True).stdout.strip()
    row={"id":r["id"],"locale":r["locale"],"role":r["role"],"target":r["target"],"http":res,"provenance":"sample-data","payload":p}
    ex,rd=find(p["name"], t_send) if res=="200" else (None,None)
    if rd and "Format Lead" in rd:
        j=rd["Format Lead"][0]["data"]["main"][0][0]["json"]
        row.update({"classification":j.get("Classification"),"confidence":j.get("Confidence"),"lead_score":j.get("Lead Score"),
                    "score_reason":j.get("Score Reason"),"draft_reply":j.get("Draft Reply"),"airtable_source":j.get("Source"),
                    "draft_reply_has_vietnamese_diacritics":bool(VI.search(j.get("Draft Reply") or "")),
                    "slack_notified":"Notify Slack (Hot Lead)" in rd,"execution_id":ex.get("id"),"exec_status":ex.get("status")})
    out.append(row)
    print(f"  {r['id']}: http={res} target={r['target']} -> actual={row.get('classification','—')} (conf={row.get('confidence')}, score={row.get('lead_score')}, draft_has_VN_diacritics={row.get('draft_reply_has_vietnamese_diacritics')})", flush=True)
    if i<len(recs)-1: time.sleep(GAP)
ts=datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ"); path=f"results/demo-run-{ts}.json"
json.dump({"utc":ts,"selection":SEL,"rows":out},open(path,"w"),ensure_ascii=False,indent=2)
print(f"\nWrote {path}")
PY
