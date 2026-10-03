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
  -> explainable score (fit + intent)
  -> route
       hot  -> Slack alert -> CRM (Airtable)
       warm -> CRM (Airtable)
       cold -> CRM (Airtable)
  -> optional extra hot-lead channels (Discord, Telegram, ntfy, email, Notion, WhatsApp)
  -> optional extra backends (Postgres + pgvector, Google Sheets, Baserow, Supabase)
```

Notes on the design:
- The webhook answers quickly and the slower work continues after the response, so the sender is not kept waiting for the AI call.
- **Hot is decided by the score, not by the AI label alone.** A lead needs enough fit points (a clear source, both email and phone) and intent points (buying intent, a clear problem, urgency) to pass the hot threshold. A lead without `source` or `phone` can legitimately end up warm.
- On the hot path the order is deliberately sequential (Switch -> Slack -> Airtable): n8n does not run two nodes fed by the same output in parallel, so the alert is placed before the CRM write.
- Every external call has Continue On Fail enabled, so a failing Airtable write does not turn the execution red. If records are missing, look at the node output in **Executions**, or run `python3 scripts/setup-airtable.py --check`.
- An Error Handler workflow catches uncaught failures.

In one recorded run the webhook acknowledged in about 0.2 s and the Slack alert arrived about 6.6 s after the lead was sent (this includes the AI call and the CRM write). Your numbers depend on your setup; `scripts/measure-latency.sh` measures it.

## What is in this repo

| Path | Content |
|---|---|
| `workflows/LeadQualifyFlow-Main-Pipeline.json` | The main pipeline (77 nodes). Start here. |
| `workflows/LeadQualifyFlow-Error-Handler.json` | Error Trigger workflow for uncaught failures |
| `workflows/` (4 more) | Optional and not covered by the quick start checks: top leads, semantic search (Postgres + pgvector, Ollama), event log replay, ops dashboard |
| `examples/` | Ready-to-send leads: `hot-lead.json`, `cold-lead.json`, `invalid-lead.json` |
| `data/demo-dataset.json` | 11 fictional leads (6 English, 5 Vietnamese) |
| `scripts/setup-airtable.py` | Creates and checks the two Airtable tables with the exact field names and types |
| `scripts/setup-n8n.py` | Creates the n8n credentials, imports and publishes the workflows |
| `scripts/seed-demo.sh`, `measure-latency.sh`, `latency-test-mode.sh` | Run the dataset through the real pipeline; measure latency; switch channels off for tests |
| `docker-compose.yml`, `.env.example` | Local stack and configuration |

## Requirements

- Docker with Compose v2, and Python 3 (standard library only).
- An **Anthropic API key** (the AI model that classifies leads; the account needs some credit).
- A free **Airtable** account: an **empty base** and a personal access token for that base with the scopes `data.records:read`, `data.records:write`, `schema.bases:read`, `schema.bases:write`. (The two `schema` scopes are only used by `setup-airtable.py`; remove them afterwards if you like.)
- A **Slack Incoming Webhook** URL for a test channel (Slack app -> Incoming Webhooks).

Use demo accounts for Airtable and Slack: the pipeline writes real records and sends real messages.

## Quick start

1. **Configure.** `cp .env.example .env`, then fill in `AIRTABLE_API_KEY`, `AIRTABLE_BASE_ID` (the `app...` part of the base URL), `SLACK_WEBHOOK_URL` and `ANTHROPIC_API_KEY`. Leave the rest. If port 5679 is taken, set `N8N_HOST_PORT`. Set `GENERIC_TIMEZONE` to your time zone (it decides the time in the `Received At` field).
2. **Start the stack.** `docker compose up -d` (the first start downloads the images). Only n8n is published on your machine, on `127.0.0.1`.
3. **Create the Airtable tables.** `python3 scripts/setup-airtable.py` creates the tables `Leads` and `Customers` with the 29 fields the workflow writes. It is safe to run again; add `--check` to only report differences.
4. **Create the n8n owner account.** Open http://127.0.0.1:5679 (use your `N8N_HOST_PORT` if you changed it; the examples below also assume 5679) and fill in the first-run form (any email and password; the account only exists on your machine).
5. **Set up n8n.** `python3 scripts/setup-n8n.py` creates the credentials (Redis, MongoDB, Anthropic), imports the workflows with those credentials already attached, publishes the main workflow, restarts n8n and checks the result. Add `--extras` to also publish the optional workflows (start the stack with `docker compose --profile extras up -d` first; these are not covered by the checks below).
6. **Send test leads** (see below).

The optional channels (email, Google Sheets, Baserow, Supabase) are switched off by default. To use one, create its credential in the n8n UI, select it in the matching node, and enable the channel in `.env` (see the `ENABLE_*` switches).

## Try it

```bash
curl -i -X POST http://127.0.0.1:5679/webhook/lead-intake \
  -H "Content-Type: application/json" --data @examples/hot-lead.json
```

| Send | Expect |
|---|---|
| `examples/hot-lead.json` | `HTTP 200` at once; after about 10 s a Slack message and a new row in `Leads` (`Classification` hot) plus a row in `Customers` |
| the same file again within 5 minutes | `HTTP 200`, but nothing new: the duplicate guard stops it (after the window it is processed again) |
| `examples/invalid-lead.json` | `HTTP 400`; nothing is written (no email and no phone) |
| `examples/cold-lead.json` | `HTTP 200`; a new row in `Leads` (cold), **no** Slack message |

To run the whole dataset instead, create an n8n API key (n8n -> Settings -> n8n API), put it in `.env` as `N8N_API_KEY`, and run `scripts/seed-demo.sh en` (or `vi`, `all`). It saves what the pipeline produced under `results/`.

## Troubleshooting

| Symptom | Likely cause and fix |
|---|---|
| Slack message arrives but `Leads` stays empty | Airtable rejected the write (the node still shows green). Run `python3 scripts/setup-airtable.py --check`; a missing field or a field with the wrong type is the usual cause |
| `Credential with ID ... does not exist` in an execution | Credentials were not created or attached. Run `python3 scripts/setup-n8n.py` again |
| `404` on the webhook | The workflow is not published or n8n was not restarted. Run `python3 scripts/setup-n8n.py` again |
| No Slack message for a lead you expected to be hot | Check `Classification` and `Lead Score` in Airtable; hot needs enough score (send `source` and `phone`) |
| `port is already allocated` | Set `N8N_HOST_PORT` in `.env` and run `docker compose up -d` again |
| The AI node fails with `Authorization failed` | The Anthropic key is wrong or the account has no credit; fix `ANTHROPIC_API_KEY`, then run `setup-n8n.py` again |

## Known limitations

- **The intake webhook has no authentication.** Running locally as described above is safe, because the stack only listens on `127.0.0.1` and nothing outside your machine can reach it. But if you expose the webhook on a public URL (a server, a tunnel, a form provider calling it), anyone who knows that URL can post fake leads to it. Add authentication (for example a secret header or a provider signature check) before using this pattern with real customers.
- Sample data only; no real customer information is included or should be sent to this demo.
- Not load-tested and not production-hardened. The database passwords in `docker-compose.yml` are for local use only.
- The credentials created by `setup-n8n.py` store your Anthropic key inside the n8n volume on your machine. Remove the stack with `docker compose down -v` when you are done.

## License

MIT, see `LICENSE`. The license covers the files in this repository only; n8n, the Docker images and the third-party services it connects to have their own licenses and terms.

Made by Truong Cao Son for Kinder AIs, a service line operated by Kinder OS Co., Ltd. Contact: hello@kinderais.com
