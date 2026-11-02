-- 0004: make the review queue visible.
--
-- The gate built in piece 4 works and nobody can reach it. n8n 2.x signs the
-- waiting-form URL with a resume token (?signature=...) and returns 401 without
-- it, so the link is unguessable by design - which also means undiscoverable.
-- Today it was dug out of n8n's own flattened execution data by hand. That is
-- not an operations process, it is an archaeology dig.
--
-- So the workflow writes the link down before it starts waiting, and anything
-- that notifies people - email, Slack, WhatsApp, a wall display - reads this
-- table. No channel is wired yet; the queue being visible is what has to exist
-- first, because a notifier with nowhere to read from is the easier half.

begin;

insert into intake.schema_migration (filename) values ('0004_review_queue.sql');

-- WORKING STATE, NOT A LEDGER, and the difference is why this one may be
-- updated. report and classification record what happened and are never
-- rewritten. This records what is outstanding: re-running a report produces a
-- new execution and a new signed URL, and the old URL is dead, so overwriting
-- is the correct behaviour rather than a compromise.
create table intake.pending_review (
    report_id     bigint      primary key references intake.report (id),
    execution_id  text        not null,
    review_url    text        not null,
    queued_at     timestamptz not null default now()
);

comment on column intake.pending_review.review_url is
    'the signed /form-waiting/<execution>?signature=<token> URL; a reviewer cannot reach the form without it';

-- PENDING IS DERIVED, NEVER STORED. There is no status column here on purpose:
-- a flag saying "still waiting" is a second copy of a fact that intake.decision
-- already holds, and two fields encoding one state is the bug this whole sprint
-- keeps re-learning. A row leaves the queue the moment a decision exists for
-- it, and nothing has to remember to take it out.
create view intake.review_queue as
select p.report_id,
       p.queued_at,
       p.execution_id,
       p.review_url,
       r.channel,
       r.reporter,
       r.body,
       c.site,
       c.charger_label,
       c.symptom,
       c.severity,
       c.note
from intake.pending_review p
join intake.report r on r.id = p.report_id
left join lateral (
    select site, charger_label, symptom, severity, note
    from intake.classification
    where report_id = p.report_id
    order by id desc
    limit 1
) c on true
where not exists (
    select 1 from intake.decision d where d.report_id = p.report_id
)
order by p.queued_at;

comment on view intake.review_queue is
    'what a human still has to decide, derived from the absence of a decision row';

commit;
