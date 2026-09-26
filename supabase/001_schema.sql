-- ULTRA@503 Material Traceability — schema migration
create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null,
  employee_id text not null unique,
  role text null check (role is null or role in ('admin','supervisor','fitting','marking','mpi_pmi','final_inspection','cmm','coating','visual_inspection','packing','dispatch','dock_audit')),
  created_at timestamptz not null default now()
);
create table if not exists public.parts (
  id uuid primary key default gen_random_uuid(),
  part_number text not null unique,
  description text,
  created_at timestamptz not null default now()
);
create table if not exists public.pos (
  id uuid primary key default gen_random_uuid(),
  po_number text not null,
  po_line text not null,
  part_id uuid not null references public.parts(id),
  customer_name text,
  po_qty numeric(14,3),
  created_at timestamptz not null default now(),
  unique(po_number,po_line)
);
create table if not exists public.process_stages (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null,
  sequence_order integer not null unique
);
insert into public.process_stages(code,name,sequence_order) values
('fitting','Fitting',1),('marking','Marking',2),('mpi_pmi','MPI / PMI',3),('final_inspection','Final Inspection',4),
('special_process','Special Process',5),('cmm','CMM Inspection',6),('coating','Coating / Surface Treatment',7),
('visual_inspection','Visual Inspection',8),('packing','Packing',9),('rfd','RFD – Ready for Dispatch',10),
('customer_pickup','Customer Pickup Confirmed',11),('dock_audit','Dock Audit',12)
on conflict(code) do update set name=excluded.name,sequence_order=excluded.sequence_order;

create table if not exists public.route_cards (
 id uuid primary key default gen_random_uuid(),
 route_card_no text not null unique,
 po_id uuid not null references public.pos(id),
 uc_batch text not null,
 heat_batch text,
 qty numeric(14,3) not null check(qty>0),
 status text not null default 'active' check(status in ('active','completed','on_hold','scrapped')),
 current_stage_id uuid references public.process_stages(id),
 internal_tracking_id uuid not null default gen_random_uuid(),
 qr_payload text,
 cmm_required boolean,
 is_urgent boolean not null default false,
 urgent_reason text,
 urgent_set_by uuid references public.profiles(id),
 urgent_set_at timestamptz,
 is_deleted boolean not null default false,
 deleted_by uuid references public.profiles(id),
 deleted_at timestamptz,
 created_by uuid references public.profiles(id) default auth.uid(),
 created_at timestamptz not null default now()
);
-- UC batch is a natural key. Optional hard constraint: run after cleaning any legacy duplicates:
-- create unique index route_cards_uc_batch_unique on public.route_cards(uc_batch);
create index if not exists route_cards_uc_batch_idx on public.route_cards(uc_batch);
create index if not exists route_cards_po_idx on public.route_cards(po_id);
create table if not exists public.stage_transactions(
 id uuid primary key default gen_random_uuid(), route_card_id uuid not null references public.route_cards(id),
 stage_id uuid not null references public.process_stages(id), quantity numeric(14,3) not null check(quantity>=0),
 status text not null, responsible_user_id uuid not null references public.profiles(id),
 remarks text, created_at timestamptz not null default now()
);
create table if not exists public.handovers(
 id uuid primary key default gen_random_uuid(), route_card_id uuid not null references public.route_cards(id),
 quantity numeric(14,3) not null check(quantity>0), from_stage_id uuid references public.process_stages(id),
 to_stage_id uuid not null references public.process_stages(id), released_by uuid not null references public.profiles(id),
 released_at timestamptz not null default now(), helper_carrier text, remarks text,
 status text not null default 'awaiting_receipt' check(status in ('awaiting_receipt','received','cancelled'))
);
create table if not exists public.receipts(
 id uuid primary key default gen_random_uuid(), handover_id uuid not null unique references public.handovers(id),
 received_by uuid not null references public.profiles(id), received_at timestamptz not null default now(),
 quantity_received numeric(14,3) not null check(quantity_received>=0), remarks text
);
create table if not exists public.rework_events(
 id uuid primary key default gen_random_uuid(), route_card_id uuid not null references public.route_cards(id),
 stage_id uuid not null references public.process_stages(id), quantity numeric(14,3) not null check(quantity>0),
 reason text not null, raised_by uuid not null references public.profiles(id), raised_at timestamptz not null default now(),
 status text not null default 'raised' check(status in ('raised','completed','verified')),
 completed_at timestamptz, verified_by uuid references public.profiles(id), verified_at timestamptz, remarks text
);
create table if not exists public.rejection_events(
 id uuid primary key default gen_random_uuid(), route_card_id uuid not null references public.route_cards(id),
 stage_id uuid not null references public.process_stages(id), quantity numeric(14,3) not null check(quantity>0),
 reason text not null, reported_by uuid not null references public.profiles(id), reported_at timestamptz not null default now(),
 scrap_location text, remarks text
);
create table if not exists public.quantity_movements(
 id uuid primary key default gen_random_uuid(), route_card_id uuid not null references public.route_cards(id),
 event_type text not null, quantity numeric(14,3) not null, from_stage_id uuid references public.process_stages(id),
 to_stage_id uuid references public.process_stages(id), reference_table text, reference_id uuid,
 actor_id uuid references public.profiles(id), created_at timestamptz not null default now()
);
create table if not exists public.attachments(
 id uuid primary key default gen_random_uuid(), parent_table text not null, parent_id uuid not null,
 storage_path text not null, uploaded_by uuid not null references public.profiles(id), uploaded_at timestamptz not null default now()
);
create table if not exists public.audit_log(
 id bigint generated always as identity primary key, table_name text not null, record_id text,
 operation text not null, changed_by uuid, changed_at timestamptz not null default now(), old_data jsonb, new_data jsonb
);
create or replace view public.urgent_route_cards as
select r.*,p.part_number,p.description,po.po_number,po.po_line,po.customer_name,ps.name as stage_name
from route_cards r join pos po on po.id=r.po_id join parts p on p.id=po.part_id
left join process_stages ps on ps.id=r.current_stage_id
where r.is_urgent and not r.is_deleted;
