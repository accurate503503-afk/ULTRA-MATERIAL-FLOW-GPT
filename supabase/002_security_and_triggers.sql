-- ULTRA@503 security, ledger, audit, and storage policies
create or replace function public.my_role() returns text language sql stable security definer set search_path=public
as $$ select role from public.profiles where id=auth.uid() $$;
create or replace function public.is_admin() returns boolean language sql stable security definer set search_path=public
as $$ select coalesce(public.my_role()='admin',false) $$;
create or replace function public.can_create_route() returns boolean language sql stable security definer set search_path=public
as $$ select coalesce(public.my_role() in ('admin','fitting'),false) $$;

alter table public.profiles enable row level security;
alter table public.parts enable row level security;
alter table public.pos enable row level security;
alter table public.process_stages enable row level security;
alter table public.route_cards enable row level security;
alter table public.stage_transactions enable row level security;
alter table public.handovers enable row level security;
alter table public.receipts enable row level security;
alter table public.rework_events enable row level security;
alter table public.rejection_events enable row level security;
alter table public.quantity_movements enable row level security;
alter table public.attachments enable row level security;
alter table public.audit_log enable row level security;

create policy "profiles read signed in" on profiles for select to authenticated using(true);
create policy "profile self insert" on profiles for insert to authenticated with check(id=auth.uid() and role is null);
create policy "profile self update without role" on profiles for update to authenticated using(id=auth.uid()) with check(id=auth.uid() and role is not distinct from (select p.role from profiles p where p.id=auth.uid()));
create policy "admin profile update" on profiles for update to authenticated using(public.is_admin()) with check(public.is_admin());
create policy "parts read" on parts for select to authenticated using(true);
create policy "parts create" on parts for insert to authenticated with check(public.can_create_route());
create policy "pos read" on pos for select to authenticated using(true);
create policy "pos create" on pos for insert to authenticated with check(public.can_create_route());
create policy "stages read" on process_stages for select to authenticated using(true);
create policy "route cards read" on route_cards for select to authenticated using(true);
create policy "route cards create" on route_cards for insert to authenticated with check(public.can_create_route() and created_by=auth.uid());
create policy "route cards admin supervisor update" on route_cards for update to authenticated using(public.my_role() in ('admin','supervisor')) with check(public.my_role() in ('admin','supervisor'));
create policy "stage tx read" on stage_transactions for select to authenticated using(true);
create policy "stage tx insert scoped" on stage_transactions for insert to authenticated with check(responsible_user_id=auth.uid() and (public.is_admin() or exists(select 1 from process_stages s where s.id=stage_id and (s.code=public.my_role() or (public.my_role()='dispatch' and s.code in ('rfd','customer_pickup'))))));
create policy "handover read" on handovers for select to authenticated using(true);
create policy "handover release self" on handovers for insert to authenticated with check(released_by=auth.uid());
create policy "receipt read" on receipts for select to authenticated using(true);
create policy "receipt insert separated" on receipts for insert to authenticated with check(received_by=auth.uid() and exists(select 1 from handovers h where h.id=handover_id and (public.is_admin() or (h.released_by<>auth.uid() and exists(select 1 from process_stages s where s.id=h.to_stage_id and s.code=public.my_role())))));
create policy "rework read" on rework_events for select to authenticated using(true);
create policy "rework insert role" on rework_events for insert to authenticated with check(raised_by=auth.uid() and public.my_role() in ('admin','final_inspection','visual_inspection','packing','dock_audit'));
create policy "rework update role" on rework_events for update to authenticated using(public.my_role() in ('admin','final_inspection','visual_inspection','packing','dock_audit')) with check(public.my_role() in ('admin','final_inspection','visual_inspection','packing','dock_audit'));
create policy "rejection read" on rejection_events for select to authenticated using(true);
create policy "rejection insert role" on rejection_events for insert to authenticated with check(reported_by=auth.uid() and public.my_role() in ('admin','mpi_pmi','final_inspection','visual_inspection','dock_audit'));
create policy "ledger read" on quantity_movements for select to authenticated using(true);
create policy "attachments read" on attachments for select to authenticated using(true);
create policy "attachments insert self" on attachments for insert to authenticated with check(uploaded_by=auth.uid());
create policy "audit read admin" on audit_log for select to authenticated using(public.is_admin());

-- Server-side append-only guard
create or replace function public.block_mutation() returns trigger language plpgsql as $$ begin raise exception 'This table is append-only'; end $$;
drop trigger if exists quantity_movements_immutable on public.quantity_movements;
create trigger quantity_movements_immutable before update or delete on public.quantity_movements for each row execute function public.block_mutation();
drop trigger if exists audit_log_immutable on public.audit_log;
create trigger audit_log_immutable before update or delete on public.audit_log for each row execute function public.block_mutation();

create or replace function public.log_audit() returns trigger language plpgsql security definer set search_path=public as $$
declare rid text;
begin
 rid:=coalesce((to_jsonb(new)->>'id'),(to_jsonb(old)->>'id'));
 insert into public.audit_log(table_name,record_id,operation,changed_by,old_data,new_data)
 values(tg_table_name,rid,tg_op,auth.uid(),case when tg_op='INSERT' then null else to_jsonb(old) end,case when tg_op='DELETE' then null else to_jsonb(new) end);
 return coalesce(new,old);
end $$;
do $$ declare t text; begin foreach t in array array['route_cards','stage_transactions','handovers','receipts','rework_events','rejection_events','quantity_movements'] loop
 execute format('drop trigger if exists audit_%I on public.%I',t,t);
 execute format('create trigger audit_%I after insert or update or delete on public.%I for each row execute function public.log_audit()',t,t);
end loop; end $$;

create or replace function public.write_quantity_movement() returns trigger language plpgsql security definer set search_path=public as $$
begin
 if tg_table_name='stage_transactions' then
  insert into quantity_movements(route_card_id,event_type,quantity,to_stage_id,reference_table,reference_id,actor_id)
  values(new.route_card_id,'stage_completion',new.quantity,new.stage_id,'stage_transactions',new.id,new.responsible_user_id);
 elsif tg_table_name='handovers' then
  insert into quantity_movements(route_card_id,event_type,quantity,from_stage_id,to_stage_id,reference_table,reference_id,actor_id)
  values(new.route_card_id,'handover_release',new.quantity,new.from_stage_id,new.to_stage_id,'handovers',new.id,new.released_by);
 elsif tg_table_name='receipts' then
  update handovers set status='received' where id=new.handover_id;
  insert into quantity_movements(route_card_id,event_type,quantity,reference_table,reference_id,actor_id)
  select h.route_card_id,'handover_receipt',new.quantity_received,'receipts',new.id,new.received_by from handovers h where h.id=new.handover_id;
 elsif tg_table_name='rework_events' then
  insert into quantity_movements(route_card_id,event_type,quantity,reference_table,reference_id,actor_id)
  values(new.route_card_id,'rework_'||new.status,new.quantity,'rework_events',new.id,coalesce(new.verified_by,new.raised_by));
 elsif tg_table_name='rejection_events' then
  insert into quantity_movements(route_card_id,event_type,quantity,reference_table,reference_id,actor_id)
  values(new.route_card_id,'rejection',new.quantity,'rejection_events',new.id,new.reported_by);
 end if;
 return new;
end $$;
drop trigger if exists ledger_stage on stage_transactions;
create trigger ledger_stage after insert on stage_transactions for each row execute function write_quantity_movement();
drop trigger if exists ledger_handover on handovers;
create trigger ledger_handover after insert on handovers for each row execute function write_quantity_movement();
drop trigger if exists ledger_receipt on receipts;
create trigger ledger_receipt after insert on receipts for each row execute function write_quantity_movement();
drop trigger if exists ledger_rework on rework_events;
create trigger ledger_rework after insert or update on rework_events for each row execute function write_quantity_movement();
drop trigger if exists ledger_rejection on rejection_events;
create trigger ledger_rejection after insert on rejection_events for each row execute function write_quantity_movement();

-- Storage bucket is private; create bucket through Dashboard or uncomment for SQL Editor:
insert into storage.buckets(id,name,public) values('attachments','attachments',false) on conflict(id) do nothing;
create policy "private attachments signed-in read" on storage.objects for select to authenticated using(bucket_id='attachments');
create policy "private attachments uploader insert" on storage.objects for insert to authenticated with check(bucket_id='attachments' and auth.uid() is not null);

-- Migration self-check: visible result confirms core objects exist.
select table_name from information_schema.tables where table_schema='public'
and table_name in ('profiles','parts','pos','route_cards','stage_transactions','handovers','receipts','rework_events','rejection_events','quantity_movements','attachments','audit_log','process_stages')
order by table_name;
