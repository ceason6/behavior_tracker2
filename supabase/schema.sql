-- ABC Behavior Tracker — multi-tenant schema (Supabase / Postgres)
-- ---------------------------------------------------------------------------
-- Every row is scoped by school_id and protected by Row-Level Security (RLS),
-- so a signed-in user can ONLY ever read/write their own school's data. This is
-- the core of multi-tenant isolation — enforced by the database, not the app.
--
-- Run this in the Supabase SQL editor (see supabase/SETUP.md). Safe to re-run.

-- ===========================================================================
-- Tables
-- ===========================================================================

-- Schools = tenants.
create table if not exists public.schools (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  created_at timestamptz not null default now()
);

-- One profile per auth user, linking them to a school and a role.
create table if not exists public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  school_id  uuid not null references public.schools(id) on delete cascade,
  full_name  text,
  role       text not null default 'staff' check (role in ('staff','admin')),
  created_at timestamptz not null default now()
);
create index if not exists profiles_school_idx on public.profiles(school_id);

-- Configurable dropdown lists per school (students, staff, periods, behaviors,
-- antecedents, consequences, strategies) — replaces the hardcoded app lists.
create table if not exists public.dropdown_options (
  id         uuid primary key default gen_random_uuid(),
  school_id  uuid not null references public.schools(id) on delete cascade,
  category   text not null check (category in
              ('student','staff','period','antecedent','behavior','consequence','strategy')),
  value      text not null,
  sort_order int  not null default 0,
  created_at timestamptz not null default now()
);
create index if not exists options_school_cat_idx on public.dropdown_options(school_id, category);

-- ABC event logs (replaces the single logs.json), scoped per school.
create table if not exists public.abc_logs (
  id                 uuid primary key default gen_random_uuid(),
  school_id          uuid not null references public.schools(id) on delete cascade,
  student            text,
  period             text,
  antecedent         text,
  antecedent_desc    text,
  behavior           text,
  behavior_desc      text,
  consequence        text,
  consequence_desc   text,
  proactive_strategy text,
  staff              text,
  occurred_at        timestamptz not null default now(),
  created_by         uuid references auth.users(id),
  created_at         timestamptz not null default now()
);
create index if not exists logs_school_time_idx on public.abc_logs(school_id, occurred_at);

-- Pending invitations: an admin pre-authorizes an email to join their school.
create table if not exists public.invites (
  id         uuid primary key default gen_random_uuid(),
  school_id  uuid not null references public.schools(id) on delete cascade,
  email      text not null,
  role       text not null default 'staff' check (role in ('staff','admin')),
  created_at timestamptz not null default now()
);
create index if not exists invites_email_idx on public.invites(lower(email));

-- ===========================================================================
-- Helper functions (SECURITY DEFINER: they bypass RLS to avoid recursion)
-- ===========================================================================

create or replace function public.current_school_id()
returns uuid language sql stable security definer set search_path = public as $$
  select school_id from public.profiles where id = auth.uid()
$$;

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.profiles where id = auth.uid() and role = 'admin')
$$;

-- Onboarding: a brand-new signed-in user creates their school and becomes admin.
create or replace function public.create_school(p_name text)
returns uuid language plpgsql security definer set search_path = public as $$
declare new_id uuid;
begin
  if exists (select 1 from public.profiles where id = auth.uid()) then
    raise exception 'You already belong to a school.';
  end if;
  insert into public.schools(name) values (p_name) returning id into new_id;
  insert into public.profiles(id, school_id, role) values (auth.uid(), new_id, 'admin');
  return new_id;
end $$;

-- Onboarding: a signed-in user joins the school that invited their email.
create or replace function public.accept_invite()
returns uuid language plpgsql security definer set search_path = public as $$
declare inv record;
begin
  if exists (select 1 from public.profiles where id = auth.uid()) then
    return public.current_school_id();
  end if;
  select * into inv from public.invites
    where lower(email) = lower(auth.jwt() ->> 'email')
    order by created_at desc limit 1;
  if inv is null then
    raise exception 'No invitation found for your email. Ask your coordinator to invite you.';
  end if;
  insert into public.profiles(id, school_id, role) values (auth.uid(), inv.school_id, inv.role);
  delete from public.invites where id = inv.id;
  return inv.school_id;
end $$;

-- ===========================================================================
-- Row-Level Security
-- ===========================================================================

alter table public.schools          enable row level security;
alter table public.profiles         enable row level security;
alter table public.dropdown_options enable row level security;
alter table public.abc_logs         enable row level security;
alter table public.invites          enable row level security;

-- Schools: members see their own; admins can rename it.
drop policy if exists schools_select on public.schools;
create policy schools_select on public.schools
  for select using (id = public.current_school_id());
drop policy if exists schools_update on public.schools;
create policy schools_update on public.schools
  for update using (id = public.current_school_id() and public.is_admin());

-- Profiles: see everyone in your school; update only your own row.
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles
  for select using (school_id = public.current_school_id());
drop policy if exists profiles_update_self on public.profiles;
create policy profiles_update_self on public.profiles
  for update using (id = auth.uid());

-- Dropdown options: read within your school; only admins can change them.
drop policy if exists options_select on public.dropdown_options;
create policy options_select on public.dropdown_options
  for select using (school_id = public.current_school_id());
drop policy if exists options_admin_write on public.dropdown_options;
create policy options_admin_write on public.dropdown_options
  for all using (school_id = public.current_school_id() and public.is_admin())
  with check (school_id = public.current_school_id() and public.is_admin());

-- ABC logs: read within your school; any member logs events (as themselves);
-- the creator or an admin may edit/delete.
drop policy if exists logs_select on public.abc_logs;
create policy logs_select on public.abc_logs
  for select using (school_id = public.current_school_id());
drop policy if exists logs_insert on public.abc_logs;
create policy logs_insert on public.abc_logs
  for insert with check (school_id = public.current_school_id() and created_by = auth.uid());
drop policy if exists logs_update on public.abc_logs;
create policy logs_update on public.abc_logs
  for update using (school_id = public.current_school_id()
                    and (created_by = auth.uid() or public.is_admin()));
drop policy if exists logs_delete on public.abc_logs;
create policy logs_delete on public.abc_logs
  for delete using (school_id = public.current_school_id()
                    and (created_by = auth.uid() or public.is_admin()));

-- Invites: only admins of the school manage them.
drop policy if exists invites_admin on public.invites;
create policy invites_admin on public.invites
  for all using (school_id = public.current_school_id() and public.is_admin())
  with check (school_id = public.current_school_id() and public.is_admin());
