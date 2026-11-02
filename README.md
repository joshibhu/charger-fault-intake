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
Day 24: the same workflow made safe to re-run, and a human gate that costs
nothing when it says no.

- `docker-compose.yml` — n8n (pinned to 2.45.6) and one Postgres.
- `db/init/01-schema.sql` — two tables, and two constraints that refuse bad
  data rather than asking a model nicely for good data.
- `workflows/fault-report-intake.json` — the workflow, twenty-one nodes. The
  canvas is the editor; this file is the source of truth. It carries credential
  *references* only — ids and labels — so it is safe to commit; hosts and
  passwords stay in n8n's own store, encrypted with `N8N_ENCRYPTION_KEY`.
- `scripts/check.sh` — one command that says whether the stack is usable.
- `db/migrations/` — everything after the first `docker compose up`: tickets,
  the approval gate, folded dedup keys, the review queue.
- `scripts/migrate.sh` — applies them in order and records what it applied.
- `PRICING.md` — what this is worth as a fixed-price project, with the
  measured running cost and the hours behind the number.

Not yet: a real notification, resolving the charger to an identifier, and any
check that the message is a fault report at all.

## The shape of it, and which node decides

Day 23 built this as seven nodes in a straight line. Day 24 took it to
twenty-one and three branches, and every one of those branches exists because a
question got asked in the right order.

```
Fault report in → Give the message an id → Store it, or find the one we have
                                                        ↓
                                              Is this a new message? ──no──→ already have it
                                                        │yes
                                              Read the complaint ←── gpt-5-nano
                                                        ↓
                                              Decide if a human must see it
                                                        ↓
                                              Store what the model made of it
                                                        ↓
                                              Find an open ticket for this charger
                                                        ↓
                                              Already on a ticket? ──yes──→ Attach it
                                                        │no                  (and escalate)
                                                        ↓                        ↓
                                              Does a human have to approve?   Reply
                                       no ↓                       ↓ yes
                                   Open a ticket → Reply     Put it in the review queue
                                                                  ↓
                                                             Tell them it is under review
                                                                  ↓
                                                             Wait for a person to decide
                                                                  ↓
                                                             Approved? ──→ decision + ticket
                                                                      └──→ decision, and nothing else
```

**One door, and exactly one place that normalises.** Every channel POSTs the
same fields, and `Give the message an id` is the only node that reads them raw.
Adding WhatsApp means a trigger plus a second copy of that one node; nothing
downstream moves. It is also where the sender's message id becomes
`inbound_id` — and where a channel without one is honestly marked as having no
replay protection rather than given a fake key made from the text, which would
merge two real complaints that happened to be worded alike.

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

**The reply is a receipt, not the product.** The product is the rows. On the
review branch the reply comes *before* the waiting, not after - nobody holds an
HTTP request open while a person reads their complaint - and the queue row is
written before the reply, because saying "under review" first and queueing
second leaves a promise nobody can keep.

**Every node that could lose work retries.** Both report writes and the
extraction carry `retryOnFail`. The retry is also the race handler: the
idempotent insert can only fail when two copies of one message land inside a
single snapshot, and by the second attempt the row is there. The OpenAI SDK's
own `maxRetries` was dropped from 2 to 1 for the same reason it exists - node
retries of 2 on top of SDK retries of 2 would allow six model calls for one
complaint, where 2 x 2 caps it at four. The ceiling is written down rather than
discovered on a bill.

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

## Three questions, in this order

Everything the pipeline does follows from the order of three questions, and the
order is the design rather than an accident of how it was built.

    1  "Have we seen this message before?"       replay
    2  "Is this charger already on a ticket?"    duplicate
    3  "Does a human have to approve?"           judgement

They are three different problems wearing similar clothes. A replay is one
message arriving twice, which is a machine's mistake - a provider re-delivering
because our acknowledgement was slow. A duplicate is two people reporting one
broken charger, which is not a mistake at all, it is the world. Judgement is our
own admission that we are not sure.

Question one is first because answering it costs nothing and running the model
on a replay costs money. Question two is second because a charger with an open
ticket has nothing left for a human to decide. Question three is last because by
then the queue is as short as it is going to get.

Four messages, and what each one leaves behind:

    (a) charger 2 at Noida mall tripping again        4 rows   report, classification, ticket, link
    (b) the same message, delivered twice             0 rows   nothing at all
    (c) same charger, different person, different     3 rows   report, classification, link
        words                                                  - no second ticket
    (d) Gurgaon hub, no charger named                 2 rows   report, classification
                                                               - stops at the gate

Run against the published workflow, that is exactly three reports, one ticket
and two links from four messages.

### A replay is free. A duplicate is not.

Both look like the same complaint twice, and their costs are nowhere near each
other:

    (b) the replay     0.043s    the model was never called
    (c) the duplicate  4.82s     a full extraction, paid for

Gate one sits before the model and gate two cannot, because until the complaint
has been read we do not know which charger it is about. Recognising a duplicate
requires understanding it first, and understanding is the expensive part. Which
also means idempotency and cost control are not two mechanisms here - they are
one, and the false branch of a single IF node is both.

## The human gate, and what a rejection costs

A rejection leaves no ticket, no link and no dispatch. Measured either side of
one real rejection and one real approval, not asserted:

    BEFORE REJECT    ticket=1  ticket_report=2  decision=1
    AFTER  REJECT    ticket=1  ticket_report=2  decision=1    (decision 0 -> 1)
    BEFORE APPROVE   ticket=1  ticket_report=2  decision=1
    AFTER  APPROVE   ticket=2  ticket_report=3  decision=2    queue emptied

The ticket is written only on approval, never before. That is what makes "no
side effects" a property of the workflow's shape instead of a promise about its
code - there is no cleanup path to forget, because there is nothing to clean up.

`intake.decision` is the one table a rejection does write, and it is not a side
effect of the gate, it is the gate. A review nobody can audit is
indistinguishable from no review. The form asks for the charger both times,
because approving means a ticket and `ticket.charger_label` is not null; on a
rejection that answer is discarded, because a rejection carrying a value nobody
was deciding about would be a fact invented by a form layout.

    id | report_id | approved | site        | charger | reason
     6 |        23 |    f     | (null)      | (null)  | complaint too vague
     7 |        24 |    t     | Gurgaon hub | DC-1    | site host confirmed on call

`DC-1` in the second row came from the reviewer. The model left it empty, which
is why that complaint stopped at the gate at all - so the one thing the human
was asked for is the one thing that was missing.

## Run it

```bash
cp .env.example .env         # then fill in both secrets as the comments say
docker compose up -d
./scripts/check.sh           # eight checks, all should say ok
open http://localhost:5678   # first visit creates the owner account
```

Then apply the migrations and import the workflow:

```bash
./scripts/migrate.sh         # db/init only runs on an empty volume
```

Import `workflows/fault-report-intake.json` (⋯ → Import from File). **Import
appends, it does not replace** — on a canvas that already holds a version,
select all and delete first, or you get two of every node with the new copies
suffixed `1` and their expressions still pointing at the old names. Add a
Postgres credential — host `db`, port `5432`, inside the compose network, not
`localhost:5436` — and an OpenAI credential. Then **Save, and then Publish**:
they are two different things, and the webhook serves only what was published.

Send a report. `message_id` is the sender's own id, and sending the same one
twice is how you watch the replay branch work:

```bash
curl -s -X POST http://localhost:5678/webhook/fault-report \
  -H 'Content-Type: application/json' \
  -d '{"channel":"whatsapp","message_id":"wamid.1","reporter":"site host",
       "body":"charger 3 at Noida mall shows error, car not charging since morning"}'
```

A complaint that names no charger stops at the gate. The signed form URL it is
waiting on is in the queue, not in the logs:

```bash
docker compose exec -T db psql -U ops_owner -d opsintake \
  -c 'select report_id, severity, review_url from intake.review_queue'
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

- **An escalation tells nobody.** A complaint reporting sparks and a burning
  smell raised ticket 8 from high to critical and was never queued for a human,
  because deduplication runs before the gate and the ticket was already open.
  Its own classification row says `needs_human = true`. "Dedup before approval"
  holds for equal-severity duplicates and fails exactly where it matters most.
  The remedy is not a gate - the fault is already accepted and the dispatch row
  now says critical - it is somebody being told, and no channel exists yet.
- **An escalation keeps no history.** The old severity is overwritten, so "when
  did this become critical, and from which complaint" can only be reconstructed
  from the reports. For an audit that is the first question asked.
- **The review form is only reachable with a signed URL.** n8n 2.x signs
  `/form-waiting/<execution>` with a resume token and answers 401 without it, so
  the link is unguessable and therefore undiscoverable. `intake.pending_review`
  now records it, which is why the queue exists - but nothing sends it, and the
  URL it records still says `localhost`, which is a dead link in anybody else's
  message. That needs a public hostname: a tunnel, or the day-26 VPS.
- **The gate has no deadline.** An approval nobody opens waits for ever and
  there is no reminder sweep.
- **Dedup compares the reporter's own words.** Case and whitespace are folded;
  "charger no 2" and "the DC one" still open their own tickets. The same
  vocabulary gap as the RAG project next door, in different clothes, and the
  only real answer is resolving a label to an identifier in the operator's own
  system.
- **Saving a workflow is not publishing it.** The canvas held sixteen nodes
  while `workflow_published_version` still pointed at a ten-node snapshot, so a
  whole test run went through the old pipeline and wrote no tickets. Compiled,
  not deployed.
- **The internal task runner is deprecated.** n8n 2.x wants the runner
  launched as a separate process for isolation and scaling. Fine for a laptop,
  not fine for a deployment, and it is a day-26 job rather than a surprise.
- **No authentication in front of n8n and no HTTPS.** Local only.
- **`db/init` runs once**, on an empty volume. Later schema changes belong in
  `db/migrations/` and are applied deliberately.
