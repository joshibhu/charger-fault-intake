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

Day 23: the stack, the schema, and one workflow that runs end to end.

- `docker-compose.yml` — n8n (pinned to 2.45.6) and one Postgres.
- `db/init/01-schema.sql` — two tables, and two constraints that refuse bad
  data rather than asking a model nicely for good data.
- `workflows/fault-report-intake.json` — the workflow, seven nodes. The canvas
  is the editor; this file is the source of truth.
- `scripts/check.sh` — one command that says whether the stack is usable.

Not yet: de-duplication, a ticket, a real notification, resolving the charger
to an identifier, and any check that the message is a fault report at all.

## The seven nodes, and which one decides

```
Fault report in → Store the report as it arrived → Read the complaint
    → Decide if a human must see it → Store what the model made of it
        → Reply to the reporter                 ↑
                                           gpt-5-nano
```

**One door, so the pipeline is written once.** Every channel POSTs the same
three fields — `channel`, `reporter`, `body` — and nothing downstream knows
where a message came from.

**The complaint reaches disk before the model sees it.** If the provider is
down, rate-limits us or answers nonsense, the report is already stored. A lost
complaint is a charger nobody fixes.

**The model extracts, it does not diagnose.** Six fields, each field's
description serving as its own prompt, with one hard rule: never invent a
charger. An empty field is a correct answer; an invented one sends a technician
to the wrong site.

**Exactly one node makes a decision, and it is not the model.** `needs_human`
is *unsure, or no charger named, or critical* — our rule, evaluated over the
model's output. Everything else in the workflow describes; this one routes.

**The reply is a receipt, not the product.** The product is two rows. The
reply stands in for a notification until a real channel arrives, which is why
nothing upstream knows how an answer gets delivered.

## What running it actually taught

**The model ignored a prompt instruction, and the rule we own caught it.** The
field description says: if the charger is not named, leave it empty *and set
`confident` to false*. On a complaint naming no charger the model left the
field empty and returned `confident: true` anyway. `needs_human` still came out
true, because our rule tests the empty field directly rather than trusting the
model's own hedge. A prompt is a request; a rule you evaluate yourself is a
refusal. This is the day's actual result.

**An item's shape is replaced at every node, not extended.** After
`insert ... returning id, needs_human` the item holds those two columns and
nothing else, so an expression reading `$json.report_id` resolved to undefined
— and n8n dropped the key from the response silently, with no error. Values
needed late are read from a *named node*, never from whatever the item happens
to be carrying. Note the distinction that makes this confusing: the node still
*wrote* `report_id` into the table. What a node stores and what it passes on
are two different things.

**An empty string is not a missing value.** The model returns `""` for a field
it cannot fill. `where charger_label is null` then finds nothing, and the
complaints that most need a human become the ones that are hardest to query.
`nullif($4, '')` fixes it in the one place the column is named, rather than in
six expressions that would drift apart.

**The bind-value behaviour is tied to the node version.** From Postgres node
2.8 each `{{ }}` expression becomes exactly one bind value, so a comma inside a
complaint no longer splits it into two. On an older node version the same
complaint corrupts the insert. The version in the file is load-bearing.

## Two n8n facts that cost time, written down so they cost it once

**`Import → From file` appends to the canvas; it does not replace it.**
Importing an edited copy of the open workflow produced fourteen nodes, the new
seven renamed with a `1` suffix — and their expressions still referenced the
*old* names, so the new copy was wired to the old nodes. Re-importing means:
select all, delete, import, save, publish.

**Publish is a snapshot, and `workflow_entity.active` is not where it lives.**
n8n 2.x keeps the published state in `workflow_published_version`. The canvas
is a draft; publishing promotes a version, and the webhook serves that version.
So breaking something on the canvas does not break the live endpoint until you
publish — and a `Publish` button that is disabled means there is nothing new to
promote, not that publishing failed.

## Run it

```bash
cp .env.example .env         # then fill in both secrets as the comments say
docker compose up -d
./scripts/check.sh           # eight checks, all should say ok
open http://localhost:5678   # first visit creates the owner account
```

Then import `workflows/fault-report-intake.json` (⋯ → Import → From file),
add a Postgres credential — host `db`, port `5432`, inside the compose network,
not `localhost:5436` — and an OpenAI credential, then publish. Send a report:

```bash
curl -s -X POST http://localhost:5678/webhook/fault-report \
  -H 'Content-Type: application/json' \
  -d '{"channel":"whatsapp","reporter":"site host",
       "body":"charger 3 at Noida mall shows error, car not charging since morning"}'
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
