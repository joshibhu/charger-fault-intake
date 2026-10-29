# charger-fault-intake

A charging operator's fault reports arrive as sentences, from four places at
once: the site host's WhatsApp, customer care's inbox, a driver app review, a
technician's phone call. *"Charger 3 at Noida mall shows error, car not
charging since morning."* Somebody reads each one, guesses which charger it
is, opens the CMS, checks the status, raises a ticket, replies to the host.
Forty a day, two people, half a day gone — and the same dead charger reported
by three drivers becomes three tickets.

This turns that sentence into a structured, de-duplicated, auditable work
item, with a human in the loop exactly where a guess would be expensive.

Built on day 23–24 of a 30-day sprint. The retrieval side of the same problem
— *which OCPP error code does this symptom correspond to, and what does the
specification require* — lives in
[ocpp-spec-rag](https://github.com/joshibhu/ocpp-spec-rag), which carries a
measured accuracy figure and a measured prompt-injection result.

## What is here so far

Day 23 is the stack and the schema. The workflow itself is next.

- `docker-compose.yml` — n8n (pinned to 2.45.6) and one Postgres.
- `db/init/01-schema.sql` — two tables, and two constraints that refuse bad
  data rather than asking a model nicely for good data.
- `scripts/check.sh` — one command that says whether the stack is usable.

## Run it

```bash
cp .env.example .env         # then fill in both secrets as the comments say
docker compose up -d
./scripts/check.sh           # eight checks, all should say ok
open http://localhost:5678   # first visit creates the owner account
```

Postgres is on 5436 and n8n on 5678, chosen because the usual ports were
already taken on the machine this was built on. Nothing here touches any
other stack.

## Two decisions worth the argument

**The raw report is never updated.** `intake.report` holds the sentence as it
arrived; `intake.classification` holds what a model made of it, one row per
attempt, and old attempts are kept. A model's reading of *"charger 3 at Noida
mall"* will sometimes be wrong, and the only way to learn which way it was
wrong is to still have the original. Interpretation that overwrites its own
input cannot be audited, and an operations system that cannot be audited is
one nobody will let near a dispatch.

**The severity vocabulary is a database constraint, not a prompt
instruction.** A prompt asking for one of four words is a request. A `check`
constraint is a refusal. When the model returns `urgent` the insert fails
loudly — which is what you want, because a fifth severity entering the table
quietly is how a dashboard starts lying. The same thinking gives the second
constraint: *not confident* plus *nobody reviewing it* is the one combination
that must not exist, because it is the system acting on a guess it has already
admitted to.

```
ERROR:  new row violates check constraint "severity_is_known"
ERROR:  new row violates check constraint "unsure_means_ask"
```

## Known gaps, stated rather than discovered

- **The internal task runner is deprecated.** n8n 2.x wants the runner
  launched as a separate process for isolation and scaling. Fine for a laptop,
  not fine for a deployment, and it is a day-26 job rather than a surprise.
- **No authentication in front of n8n and no HTTPS.** Local only.
- **`db/init` runs once**, on an empty volume. Later schema changes belong in
  `db/migrations/` and are applied deliberately.
