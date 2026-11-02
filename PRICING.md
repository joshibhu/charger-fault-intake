# What this is worth, as a fixed-price project

Day 24's log item was one line: *price this workflow as a fixed-price project,
write the number down.* This is the number and the arithmetic behind it, written
before any client asked, so that the first time somebody does ask there is
nothing to invent.

The client in mind is the operator from the README: roughly 90 sites, 400
chargers, 40 complaints a day arriving as WhatsApp messages, phone calls and
forwarded email, triaged by a person reading them one at a time.

## The running cost, measured

Taken from n8n's own execution records for the fifteen complaints that reached
the model, not estimated:

    9794 prompt + 790 completion tokens over 15 complaints
    per complaint   $0.000054      (Rs 0.0045)
    40 / day        $0.06 / month  (Rs 5)
    400 / day       $0.64 / month  (Rs 54)

Prices are gpt-5-nano at $0.05 / $0.40 per million tokens, checked 2026-10-21.

Two honest qualifications. Completion tokens average 53 per complaint, which is
low enough to suspect that reasoning tokens are not being reported through the
LangChain node at all - so this is a floor, not a ceiling. And the same model
costs Rs 0.124 per call in the RAG project next door, twenty-seven times more,
because that prompt carries five retrieved passages where this one carries about
650 tokens. The two numbers disagree for a reason that can be named, which is
the only kind of disagreement worth trusting.

**The model is not the cost.** A small VPS to run n8n and Postgres is $6-12 a
month, which is more than a hundred times the inference bill at 400 complaints a
day. Anyone pricing this as an AI project is pricing the wrong thing.

## What is actually being sold

Not the canvas. The canvas is the part a competitor reproduces in an afternoon.
What takes the time, and what breaks in production when it is missing:

- A schema that refuses bad data instead of a prompt that requests good data.
  Severity restricted to four words, low confidence forced to human review,
  one open ticket per charger, one decision per report.
- Replay protection on the sender's own message id, because WhatsApp and Twilio
  re-deliver on timeout and will otherwise create a second complaint every time
  the acknowledgement is slow.
- Deduplication that survives two people reporting one fault in two languages.
- A human gate where a rejection leaves nothing behind - no ticket, no
  dispatch - and the decision itself is still on the record.
- Escalation ranking, so a charger reported as sparking after being reported as
  tripping raises the row the dispatcher actually reads.
- An audit trail where every complaint, every model reading and every human
  decision is kept, because the day a technician is sent to the wrong site the
  only useful question is what the system was told.

None of that is visible on a canvas screenshot, and all of it is why the work
is not a twenty-dollar-an-hour job.

## Hours, honestly

The demo in this repository took about eight hours of work. That number is
useless for a quote, because the demo has one channel, no deployment, no
monitoring, no client data and no meetings. A real engagement:

    schema and migrations                                     6
    intake, extraction, prompt tuning on THEIR complaints     10
    dedup, tickets, escalation                                 8
    approval gate, review queue, notifier with retries        10
    deployment, secrets, backups, basic monitoring             8
    handover document, runbook, one training session           6
    contingency for their data and their IT department        10
                                                            ----
                                                              58

Email as the only channel. WhatsApp adds roughly 12 more hours and three weeks
of somebody else's calendar, for reasons below.

## The number

Two phases, and the split is the point.

**Phase one - email intake, deployed, handed over. $1,800 fixed.**
About 40 hours at $45, which is the rate, not a discount on it. There is no risk
premium in the price because the risk is handled in the exclusions instead:
padding a quote loses the work, and a scope boundary does not.

**Phase two - WhatsApp, the notifier, escalation push. $1,400 fixed.**
About 30 hours at the same $45: the 12 for WhatsApp plus the 18 of queue,
notifier and escalation work that phase one leaves out. Quoted separately and
deliberately not bundled, because its longest pole is not engineering. The
client's own legal entity has to pass Meta Business verification and get a
message template approved, which takes one to three weeks and is entirely
outside our control. A fixed price that absorbs somebody else's approval queue
is a fixed price that loses money - so the queue is excluded instead, which is
the same principle as above and not a different one.

Both phases together are $3,200, which is 70 hours at the same rate. The rate
does not move between them. The first draft of this file priced phase two at
$2,200, a 63% premium over its own hour count, in a document whose previous
paragraph refuses to pad quotes. Checking the arithmetic found it; the number
is corrected rather than the principle.

**$1,800 is the number to write down**, because it is the one that can be
closed in a single conversation.

## Explicitly not included

Fixed-price projects die here, so it is written before it is argued about:

- Resolving the words a reporter uses into the client's own charger
  identifiers. "charger no 2" and "the DC one" still open their own tickets
  today, and the extraction itself misses an explicitly written label about
  once in three runs of the same sentence - measured, not feared. This needs
  their asset data and is its own discovery exercise. It is also the single
  most valuable thing to quote next, because it is the one fix that closes
  deduplication, escalation and extraction together.
- Integration with an existing ticketing system (Freshdesk, Zoho, Jira).
- Meta Business verification and WhatsApp template approval, and DLT
  registration if SMS is wanted.
- Any CSMS or OCPP integration. This system reads complaints; it does not talk
  to chargers.
- Support beyond thirty days of fixes to delivered scope.

## Does it pay back

The weakest part of the value case is the one easiest to say out loud:
deduplication removes wasted technician trips. At Rs 2,000-5,000 a trip in
India, five avoided dispatches a month is Rs 10,000-25,000.

The stronger part is the reading. Forty complaints a day at two minutes each is
about 40 hours a month of an operations person, roughly Rs 16,000 loaded. Phase
one at Rs 1.5 lakh pays that back in under a year, before counting a single
avoided trip.

The part nobody puts in a spreadsheet is the sparking charger. Today it reaches
a human when somebody happens to read the right message. After this, the ticket
it joins says critical.
