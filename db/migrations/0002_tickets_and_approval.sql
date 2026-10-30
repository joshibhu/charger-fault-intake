-- 0002: tickets, the approval gate, and the two columns that make a rerun safe.
--
-- Applied by scripts/migrate.sh, not by Docker. db/init/01-schema.sql only runs
-- against an empty volume, so from here on the init file is history and this
-- directory is the present.
--
-- The whole file is one transaction. The first statement that does real work is
-- the insert into schema_migration, so a second run fails on its primary key
-- before touching anything else - the migration's own record is the guard.

begin;

create table if not exists intake.schema_migration (
    filename    text primary key,
    applied_at  timestamptz not null default now()
);

insert into intake.schema_migration (filename) values ('0002_tickets_and_approval.sql');


-- ---------------------------------------------------------------- idempotency
--
-- REPLAY, WHICH IS NOT THE SAME PROBLEM AS DUPLICATION. Two site hosts
-- complaining about one charger is duplication - a judgement call about whether
-- they mean the same fault. WhatsApp re-delivering one message because our ACK
-- was slow is a replay - not a judgement call at all, just the same event
-- arriving twice. Meta, Twilio and every webhook provider worth using will do
-- this, by design, on timeout.
--
-- So the sender's own message id becomes part of the row, and the database
-- refuses the second copy. Not nullable: a nullable unique column silently
-- gives up on every caller who forgets to send one, and "idempotency that is
-- off unless you remember it" is not idempotency. A channel with no provider
-- id (a web form, a manual entry) must generate one - a form resubmitted on
-- purpose IS a new report, and deserves a new id.
alter table intake.report add column inbound_id text;

update intake.report set inbound_id = 'backfill:' || id where inbound_id is null;

alter table intake.report alter column inbound_id set not null;

comment on column intake.report.inbound_id is
    'the sender''s own id for this message (wamid.*, Twilio MessageSid, email Message-ID), unique per channel';

-- Scoped per channel, because two providers numbering their own messages are
-- under no obligation to avoid each other.
create unique index report_inbound_idx on intake.report (channel, inbound_id);


-- --------------------------------------------------------------------- tickets
--
-- THE DISPATCHABLE UNIT. A report is what someone said; a ticket is what we are
-- going to do about it. Many reports, one ticket - that asymmetry is the whole
-- reason this table exists separately.
create table intake.ticket (
    id             bigserial primary key,
    opened_at      timestamptz not null default now(),
    site           text,
    charger_label  text        not null,
    symptom        text,
    severity       text        not null,
    status         text        not null default 'open',
    closed_at      timestamptz,
    closed_note    text,

    constraint ticket_severity_is_known check (
        severity in ('critical', 'high', 'normal', 'low')
    ),

    constraint ticket_status_is_known check (status in ('open', 'closed')),

    -- A closed ticket with no closing time is an unfinished edit saved by
    -- accident. Stated as an equivalence so neither half can drift.
    constraint closed_has_a_time check ((status = 'closed') = (closed_at is not null))
);

comment on table intake.ticket is
    'one open ticket per charger, enforced by ticket_one_open_per_charger';
comment on column intake.ticket.charger_label is
    'not null on purpose: a ticket nobody can be dispatched against is not a ticket';

-- DEDUPLICATION, AS A REFUSAL RATHER THAN A LOOKUP. The workflow still asks
-- "is there an open ticket for this charger" so it can answer the reporter
-- properly, but if two complaints race, the second insert loses here. coalesce
-- because a null site would otherwise make every row distinct from every other
-- one - in a unique index, null is not equal to null.
create unique index ticket_one_open_per_charger
    on intake.ticket (coalesce(site, ''), charger_label)
    where status = 'open';

create index ticket_open_idx on intake.ticket (status, opened_at desc);


-- WHICH COMPLAINTS A TICKET IS ANSWERING. A link table and not a column on
-- report, because report is never updated - the complaint cannot change, but
-- which ticket it belongs to is decided later, and sometimes by a human.
create table intake.ticket_report (
    ticket_id  bigint      not null references intake.ticket (id),
    report_id  bigint      not null references intake.report (id) unique,
    linked_at  timestamptz not null default now(),

    primary key (ticket_id, report_id)
);

comment on column intake.ticket_report.report_id is
    'unique: one complaint answers to exactly one ticket, never two';


-- -------------------------------------------------------------- the gate's log
--
-- WHAT THE HUMAN DECIDED. This is the one table that gets written on a
-- rejection, and it is not a side effect of the gate - it IS the gate. "A
-- rejected approval leaves no side effects" means no ticket, no dispatch, no
-- message to a technician. It cannot also mean no record that a person looked
-- at this and said no; a review nobody can audit is indistinguishable from no
-- review at all.
create table intake.decision (
    id             bigserial primary key,
    report_id      bigint      not null references intake.report (id) unique,
    decided_at     timestamptz not null default now(),
    decided_by     text        not null,
    approved       boolean     not null,
    reason         text,
    site           text,
    charger_label  text,

    -- An approval has to say what it is approving. The reviewer sees the
    -- model's guess pre-filled and may correct it, but may not leave the
    -- charger blank and still approve - that would create a ticket nobody can
    -- act on, which ticket.charger_label already refuses one layer down.
    constraint approved_needs_a_charger check (not approved or charger_label is not null)
);

-- The reviewer double-clicking the approve link is the most ordinary failure
-- there is, so one report gets one decision and the second attempt is refused
-- by the primary key's cousin above (report_id unique), not by a flag we hope
-- to have set.
comment on table intake.decision is
    'insert-only; report_id unique makes a double-approval a database error, not a second ticket';

commit;
