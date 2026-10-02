# LeadQualifyFlow (demo preview)

An n8n workflow that takes a new lead from any intake form or chat, has an AI model label it **hot / warm / cold**, adds an explainable score, saves it to a CRM with a draft reply, and alerts the team on Slack.

> **Self-initiated case study, not a client project.** All data here is sample (fictional) data. This is a **demo preview**: it shows how the system is built so you can read it and run it locally. It is not production software (see [Known limitations](#known-limitations)).

Video walkthrough (made with AI from real screenshots captured during live tests, synthetic AI voice): https://youtu.be/Y7Lepf6CbW0

## What it does

```
POST /webhook/lead-intake
  -> duplicate-delivery guard (Redis)
  -> normalize shape (Facebook Lead Ads, Calendly, Shopify, Typeform, Telegram, Zalo OA, WhatsApp, Tally, plain JSON)
  -> validate (contact info present?)  -- invalid -> HTTP 400
  -> AI classify + draft reply (Claude Haiku, temperature 0, JSON output; Redis cache for repeated content)
  -> parse (safe fallback to cold if the AI output cannot be parsed)
  -> explainable score
  -> route
       hot  -> Slack alert -> CRM (Airtable)
       warm -> CRM (Airtable)
       cold -> CRM (Airtable)
  -> optional extra hot-lead channels (Discord, Telegram, ntfy, email, Notion, WhatsApp)
  -> optional extra backends (Postgres + pgvector, Google Sheets, Baserow, Supabase)
```

Notes on the design:
- The webhook answers quickly and the slower work continues after the response, so the sender is not kept waiting for the AI call.
- On the hot path the order is deliberately sequential (Switch -> Slack -> Airtable): n8n does not run two nodes fed by the same output in parallel, so the alert is placed before the CRM write.
- Every external call has Continue On Fail enabled, and an Error Handler workflow catches uncaught failures.

In one recorded run the webhook acknowledged in about 0.2 s and the Slack alert arrived about 6.6 s after the lead was sent (this includes the AI call and the CRM write). Your numbers will depend on your setup; `scripts/measure-latency.sh` measures it.

## What is in this repo

| Path | Content |
|---|---|
| `workflows/LeadQualifyFlow-MVP-01.json` | The main pipeline (77 nodes). Start here. |
| `workflows/LeadQualifyFlow-Error-Handler.json` | Error Trigger workflow for uncaught failures |
| `workflows/LeadQualifyFlow-GetTopLeads-AC24.json` | Query the highest-scored leads (Redis + Postgres) |
| `workflows/LeadQualifyFlow-SemanticSearch-AC21.json` | Find similar leads by embedding similarity (Postgres + pgvector, Ollama) |
| `workflows/LeadQualifyFlow-ReplayEventLog-AC23.json` | Replay the event log (Redis) |
| `workflows/LeadQualifyFlow-OpsDashboard-AC25.json` | Small ops dashboard page served by n8n |
| `data/demo-dataset.json` | 11 fictional leads (6 English, 5 Vietnamese) |
| `scripts/` | Seed the dataset into the real pipeline; measure latency; toggle test mode |
| `docker-compose.yml`, `.env.example` | Local stack and configuration |

Credentials and instance identifiers were removed from the workflow files: each credential field says `REPLACE_AFTER_IMPORT` and you select your own after importing.

## Run it locally

You need Docker, an Anthropic API key, an Airtable base (any table with the fields your mapping uses), and a Slack Incoming Webhook URL.

1. `cp .env.example .env` and fill in the core values (Airtable, Slack, `N8N_WEBHOOK_PATH`).
2. `docker compose up -d` (core services: n8n, Redis, MongoDB). For the optional workflows use `docker compose --profile extras up -d` as well.
3. Open http://127.0.0.1:5679, create the owner account, then create an n8n API key (Settings -> n8n API) and put it in `.env` as `N8N_API_KEY`.
4. Import the workflows from `workflows/` (Workflows -> Import from file). All are imported inactive.
5. Create these credentials in n8n and select them in the nodes that show a missing credential:
   - **Anthropic API** (for the classify node)
   - **Redis**: host `redis`, port `6379`
   - **MongoDB**: connection string `mongodb://leadqualifyflow:leadqualifyflow_demo_local_only@mongo:27017/?authSource=admin`
   - Only if you enable them: Postgres (`postgres:5432`, user/db `leadqualifyflow`), SMTP, Google, Baserow, Supabase.
6. In the Ops Dashboard workflow, replace `REPLACE_WITH_MVP01_WORKFLOW_ID` in the "Fetch Main Workflow (Live)" node with the id of your imported MVP-01 workflow (it is in that workflow's URL). Optionally set the Error Handler as the error workflow of MVP-01 (Workflow settings).
7. Activate the MVP-01 workflow, then send a lead:

```bash
curl -X POST http://127.0.0.1:5679/webhook/lead-intake \
  -H "Content-Type: application/json" \
  -d '{"name":"Sarah Mitchell","email":"sarah.mitchell@example.com","message":"We just got budget approval and want to roll this out next week, please send me a quote for the Pro plan"}'
```

To run the whole dataset against the real pipeline and save what the pipeline produced (never edited by hand):

```bash
export LQF_WORKFLOW_ID=<id of the imported MVP-01 workflow>
scripts/seed-demo.sh en        # or: vi | all | EN-01,EN-02
```

Point `AIRTABLE_*` and `SLACK_WEBHOOK_URL` at **demo** targets first: the script writes real records and sends real Slack messages.

## Known limitations

- **The intake webhook has no authentication.** Anyone who knows the URL can post to it. This is acceptable for a local demo and must be fixed before using the pattern with real customer data.
- Sample data only; no real customer information is included or should be sent to this demo.
- Not load-tested and not production-hardened. The compose file uses unpinned `latest` images for n8n and Ollama; pin tested versions before relying on it.
- The Airtable table schema is not provided as code: create a table whose fields match the field names in the Airtable HTTP Request nodes.

## License

MIT, see `LICENSE`. The license covers the files in this repository only; n8n, the Docker images and the third-party services it connects to have their own licenses and terms.

Made by Truong Cao Son for Kinder AIs, a service line operated by Kinder OS Co., Ltd. Contact: hello@kinderais.com
