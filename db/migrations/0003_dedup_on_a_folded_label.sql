-- 0003: fold case and whitespace before comparing charger labels.
--
-- 0002 indexed charger_label raw, which means "Charger 2" and "charger 2 "
-- would each get their own open ticket. Folding is not a fix - "charger no 2"
-- and "the DC one" still slip through, and the only real answer is resolving
-- the reporter's words to a charger id in the operator's own system, which is
-- an open gap with its own failure mode. This buys the two cheapest cases and
-- claims nothing more.
--
-- The lookup in the workflow uses the same two expressions. An index and a
-- query that fold differently are two different questions, and the one that
-- loses is always the index.

begin;

insert into intake.schema_migration (filename) values ('0003_dedup_on_a_folded_label.sql');

drop index intake.ticket_one_open_per_charger;

create unique index ticket_one_open_per_charger
    on intake.ticket (coalesce(lower(btrim(site)), ''), lower(btrim(charger_label)))
    where status = 'open';

commit;
