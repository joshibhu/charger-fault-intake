-- Runs once, when the data volume is created. A later change goes in
-- db/migrations/ and is applied by hand; editing this file after the first
-- `docker compose up` changes nothing, which is the kind of silence that
-- costs an afternoon.

create schema if not exists n8n;    -- n8n's own tables; ours never go here
create schema if not exists intake;

-- THE COMPLAINT, EXACTLY AS IT ARRIVED. Nothing in this table is ever
-- updated, and that is the point. A model's reading of "charger 3 at Noida
-- mall is not working" will sometimes be wrong, and the only way to find out
-- which way it was wrong is to still have the sentence. Interpretation that
-- overwrites its own input cannot be audited, and an operations system that
-- cannot be audited is one nobody trusts with a dispatch.
create table intake.report (
    id           bigserial primary key,
    received_at  timestamptz not null default now(),
    channel      text        not null,
    reporter     text,
    body         text        not null,
    payload      jsonb       not null
);

comment on column intake.report.channel  is 'webhook | email | whatsapp — how it reached us';
comment on column intake.report.reporter is 'free text; a site host name, a phone number, an email';
comment on column intake.report.body     is 'the complaint in the reporter''s own words';
comment on column intake.report.payload  is 'the whole request as received, for the day the parsing turns out to be wrong';

-- WHAT THE MODEL MADE OF IT. One row per attempt, and attempts are kept, so
-- re-running a report after a prompt change leaves both readings side by side
-- instead of quietly replacing the old one.
create table intake.classification (
    id             bigserial primary key,
    report_id      bigint      not null references intake.report (id),
    classified_at  timestamptz not null default now(),
    model          text        not null,
    site           text,
    charger_label  text,
    symptom        text,
    severity       text,
    confident      boolean     not null,
    needs_human    boolean     not null,
    note           text,

    -- The severity vocabulary is enforced here and not in the prompt. A
    -- prompt asking for one of four words is a request; this is a refusal.
    -- When the model invents "urgent" the insert fails loudly, which is the
    -- behaviour we want - a fifth severity silently entering the table is how
    -- a dashboard starts lying.
    constraint severity_is_known check (
        severity is null or severity in ('critical', 'high', 'normal', 'low')
    ),

    -- Low confidence and no human review is the one combination that must not
    -- exist: it is the system acting on a guess it has already admitted to.
    constraint unsure_means_ask check (confident or needs_human)
);

comment on column intake.classification.charger_label is 'the charger as the REPORTER named it, not an id we resolved — resolution is a separate problem with its own failure mode';
comment on column intake.classification.confident     is 'the model''s own hedge about its reading';
comment on column intake.classification.needs_human   is 'true routes this to review instead of to the field';

create index report_received_idx       on intake.report (received_at desc);
create index classification_report_idx on intake.classification (report_id);
