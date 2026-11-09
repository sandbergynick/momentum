-- Momentum lobbyist registration tool — Supabase schema (v1)
-- Run once in the SQL editor of the new project (or via the Supabase connector).
-- Access: only signed-in users with an @momentum-advocacy.com email.

-- ---------- helpers ----------
create or replace function public.is_momentum()
returns boolean language sql stable set search_path = '' as $$
  select coalesce((auth.jwt() ->> 'email') ilike '%@momentum-advocacy.com', false)
$$;

create or replace function public.touch_updated_at()
returns trigger language plpgsql set search_path = '' as $$
begin new.updated_at = now(); return new; end $$;

-- ---------- lobbyists ----------
create table public.lobbyists (
  id          uuid primary key default gen_random_uuid(),
  reg_num     text unique,                 -- CFB lobbyist registration #
  name        text not null,
  initials    text,                        -- roster initials (NS, AK2, ...)
  email       text,
  phone       text,
  employer    text default 'Momentum Advocacy',
  address1    text default '4530 W 77th St',
  address2    text default 'Ste 305',
  city        text default 'Edina',
  state       text default 'MN',
  zip         text default '55435',
  signature_path text,                     -- object in private 'signatures' bucket
  active      boolean not null default true,
  updated_at  timestamptz not null default now()
);

-- ---------- organizations (principals) ----------
create table public.organizations (
  id            uuid primary key default gen_random_uuid(),
  entity_id     text unique,               -- CFB principal / association ID
  name          text not null,
  address text, city text, state text default 'MN', zip text,
  phone text, website text,
  contact_name text, contact_email text, contact_phone text,
  officers      jsonb not null default '[]',   -- [{name, address}]
  last_setup    jsonb not null default '{}',   -- per-lobbyist form setup remembered from last generate
  last_lobbyist_ids uuid[] not null default '{}',
  updated_at    timestamptz not null default now()
);

-- ---------- staffing (from the Client Leads roster) ----------
create table public.staffing (
  org_id      uuid references public.organizations on delete cascade,
  lobbyist_id uuid references public.lobbyists on delete cascade,
  role        text check (role in ('lead','second','assist','designated')),
  primary key (org_id, lobbyist_id, role)
);

-- ---------- CFB snapshot (nightly sync) ----------
create table public.cfb_registrations (
  lobbyist_reg text not null,
  entity_id    text not null,
  principal    text,
  first_seen   date not null default current_date,
  last_seen    date not null default current_date,
  primary key (lobbyist_reg, entity_id)
);

create table public.sync_runs (
  id         bigint generated always as identity primary key,
  ran_at     timestamptz not null default now(),
  source     text not null,                -- 'cfb' | 'roster'
  ok         boolean not null,
  added      int default 0,
  removed    int default 0,
  note       text
);

-- ---------- filing queue ----------
create table public.filings (
  id          uuid primary key default gen_random_uuid(),
  lobbyist_id uuid references public.lobbyists on delete cascade,
  org_id      uuid references public.organizations on delete cascade,
  action      text not null check (action in ('registration','amendment','termination')),
  reason      text,                        -- why the gap engine flagged it
  priority    text default 'normal' check (priority in ('high','normal','confirm')),
  status      text not null default 'todo' check (status in ('todo','generated','filed','confirmed','skip')),
  due_date    date,                        -- 5-day (register) / 10-day (amend) windows
  filed_at    timestamptz,
  confirmed_at timestamptz,                -- set by sync when CFB shows the change
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (lobbyist_id, org_id, action, status)
);
create index on public.staffing (lobbyist_id);
create index on public.filings (org_id);
create index on public.filings (lobbyist_id);

-- ---------- gap engine: what needs filing right now ----------
create or replace view public.registration_gaps with (security_invoker = true) as
-- staffed but not registered
select s.lobbyist_id, s.org_id, 'registration'::text as action,
       'Staffed on roster, not registered with CFB' as reason
from public.staffing s
join public.lobbyists l on l.id = s.lobbyist_id
join public.organizations o on o.id = s.org_id
where not exists (select 1 from public.cfb_registrations r
                  where r.lobbyist_reg = l.reg_num and r.entity_id = o.entity_id)
union
-- registered but no longer staffed
select l.id, o.id, 'termination',
       'Registered with CFB, not on roster'
from public.cfb_registrations r
join public.lobbyists l on l.reg_num = r.lobbyist_reg
join public.organizations o on o.entity_id = r.entity_id
where r.last_seen = (select max(last_seen) from public.cfb_registrations)
  and not exists (select 1 from public.staffing s where s.lobbyist_id = l.id and s.org_id = o.id);

-- ---------- triggers ----------
create trigger t_lobbyists_upd before update on public.lobbyists for each row execute function public.touch_updated_at();
create trigger t_orgs_upd      before update on public.organizations for each row execute function public.touch_updated_at();
create trigger t_filings_upd   before update on public.filings for each row execute function public.touch_updated_at();

-- ---------- row level security ----------
alter table public.lobbyists         enable row level security;
alter table public.organizations     enable row level security;
alter table public.staffing          enable row level security;
alter table public.cfb_registrations enable row level security;
alter table public.sync_runs         enable row level security;
alter table public.filings           enable row level security;

create policy momentum_all on public.lobbyists     for all using ((select public.is_momentum())) with check ((select public.is_momentum()));
create policy momentum_all on public.organizations for all using ((select public.is_momentum())) with check ((select public.is_momentum()));
create policy momentum_all on public.staffing      for all using ((select public.is_momentum())) with check ((select public.is_momentum()));
create policy momentum_all on public.filings       for all using ((select public.is_momentum())) with check ((select public.is_momentum()));
-- CFB snapshot + sync log are written only by the server (service role); staff can read
create policy momentum_read on public.cfb_registrations for select using ((select public.is_momentum()));
create policy momentum_read on public.sync_runs         for select using ((select public.is_momentum()));

-- ---------- private storage for signatures ----------
insert into storage.buckets (id, name, public) values ('signatures', 'signatures', false)
on conflict (id) do nothing;
create policy momentum_sig_read on storage.objects for select
  using (bucket_id = 'signatures' and (select public.is_momentum()));
create policy momentum_sig_write on storage.objects for insert
  with check (bucket_id = 'signatures' and (select public.is_momentum()));
