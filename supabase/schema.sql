-- BG3 Party Planner database (Supabase project blfgzzmmnbeswlmcleqa).
-- Already applied to the live project; kept here as the record of what's there.
-- Anyone can read. All writes go through the functions below, which check the party passcode.

create extension if not exists pgcrypto with schema extensions;

create table public.stops (
  id         text primary key default gen_random_uuid()::text,
  name       text not null check (char_length(name) between 1 and 200),
  detail     text not null default '' check (char_length(detail) <= 200),
  act        smallint not null check (act between 1 and 3),
  sort_order double precision not null
);

create table public.items (
  id       text primary key default gen_random_uuid()::text,
  who      char(1) not null check (who in ('S','D','A','C')),
  name     text not null check (char_length(name) between 1 and 200),
  slot     text not null default 'Other' check (char_length(slot) <= 40),
  stop_id  text references public.stops(id) on delete set null,
  how      text not null default '' check (char_length(how) <= 2000),
  optional boolean not null default false,
  got      boolean not null default false,
  created  bigint not null default (extract(epoch from now()) * 1000)::bigint
);
create index items_stop_id_idx on public.items (stop_id);

create table public.players (
  who  char(1) primary key check (who in ('S','D','A','C')),
  name text not null default '' check (char_length(name) <= 60)
);
insert into public.players (who) values ('S'),('D'),('A'),('C');

-- The passcode hash lives in a schema the API can't see.
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
create table private.settings (
  id            boolean primary key default true check (id),
  passcode_hash text not null
);
-- Set or change the passcode (run in the SQL editor):
--   insert into private.settings (passcode_hash) values (extensions.crypt('NEW-PASSCODE', extensions.gen_salt('bf')))
--   on conflict (id) do update set passcode_hash = excluded.passcode_hash;

alter table public.stops   enable row level security;
alter table public.items   enable row level security;
alter table public.players enable row level security;
alter table private.settings enable row level security;

create policy "anyone can read stops"   on public.stops   for select to anon, authenticated using (true);
create policy "anyone can read items"   on public.items   for select to anon, authenticated using (true);
create policy "anyone can read players" on public.players for select to anon, authenticated using (true);
revoke insert, update, delete, truncate on public.stops, public.items, public.players from anon, authenticated;

alter publication supabase_realtime add table public.stops, public.items, public.players;

create function private.require_passcode(p_passcode text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if p_passcode is null or not exists (
    select 1 from private.settings s
    where s.passcode_hash = extensions.crypt(p_passcode, s.passcode_hash)
  ) then
    raise exception 'wrong passcode' using errcode = '28P01';
  end if;
end $$;
revoke execute on function private.require_passcode(text) from public, anon, authenticated;

create function public.check_passcode(p_passcode text) returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  perform private.require_passcode(p_passcode);
  return true;
end $$;

create function public.save_item(
  p_passcode text, p_id text, p_who text, p_name text, p_slot text,
  p_stop_id text, p_how text, p_optional boolean
) returns text
language plpgsql security definer set search_path = '' as $$
declare v_id text;
begin
  perform private.require_passcode(p_passcode);
  if p_id is null then
    insert into public.items (who, name, slot, stop_id, how, optional)
    values (p_who, trim(p_name), p_slot, p_stop_id, coalesce(trim(p_how), ''), coalesce(p_optional, false))
    returning id into v_id;
  else
    update public.items set who = p_who, name = trim(p_name), slot = p_slot, stop_id = p_stop_id,
      how = coalesce(trim(p_how), ''), optional = coalesce(p_optional, false)
    where id = p_id returning id into v_id;
  end if;
  return v_id;
end $$;

create function public.set_item_got(p_passcode text, p_id text, p_got boolean) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform private.require_passcode(p_passcode);
  update public.items set got = p_got where id = p_id;
end $$;

create function public.remove_item(p_passcode text, p_id text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform private.require_passcode(p_passcode);
  delete from public.items where id = p_id;
end $$;

create function public.add_stop(p_passcode text, p_name text, p_act smallint) returns text
language plpgsql security definer set search_path = '' as $$
declare v_id text;
begin
  perform private.require_passcode(p_passcode);
  insert into public.stops (name, act, sort_order)
  select trim(p_name), p_act, greatest(p_act * 1000, coalesce(max(sort_order), 0)) + 10
  from public.stops where act = p_act
  returning id into v_id;
  return v_id;
end $$;

create function public.update_stop(p_passcode text, p_id text, p_name text, p_detail text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform private.require_passcode(p_passcode);
  update public.stops set name = trim(p_name), detail = coalesce(trim(p_detail), '') where id = p_id;
end $$;

create function public.move_stop(p_passcode text, p_id text, p_sort_order double precision) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform private.require_passcode(p_passcode);
  update public.stops set sort_order = p_sort_order where id = p_id;
end $$;

create function public.set_player(p_passcode text, p_who text, p_name text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform private.require_passcode(p_passcode);
  update public.players set name = trim(p_name) where who = p_who;
end $$;

revoke execute on all functions in schema public from public;
grant execute on all functions in schema public to anon, authenticated;

-- Item priority (added 2026-10-10): each item can be marked essential or nice to have, or left unset.
-- Items already flagged optional were carried over as nice to have; optional is kept in step for older pages.
alter table public.items add column priority text check (priority in ('essential','nice'));
update public.items set priority = 'nice' where optional and priority is null;

create function public.save_item(
  p_passcode text, p_id text, p_who text, p_name text, p_slot text,
  p_stop_id text, p_how text, p_priority text
) returns text
language plpgsql security definer set search_path = '' as $$
declare v_id text; v_pri text := nullif(p_priority, '');
begin
  perform private.require_passcode(p_passcode);
  if p_id is null then
    insert into public.items (who, name, slot, stop_id, how, priority, optional)
    values (p_who, trim(p_name), p_slot, p_stop_id, coalesce(trim(p_how), ''), v_pri, v_pri is not distinct from 'nice')
    returning id into v_id;
  else
    update public.items set who = p_who, name = trim(p_name), slot = p_slot, stop_id = p_stop_id,
      how = coalesce(trim(p_how), ''), priority = v_pri, optional = v_pri is not distinct from 'nice'
    where id = p_id returning id into v_id;
  end if;
  return v_id;
end $$;

create function public.set_item_priority(p_passcode text, p_id text, p_priority text) returns void
language plpgsql security definer set search_path = '' as $$
declare v_pri text := nullif(p_priority, '');
begin
  perform private.require_passcode(p_passcode);
  update public.items set priority = v_pri, optional = v_pri is not distinct from 'nice' where id = p_id;
end $$;

revoke execute on function public.save_item(text, text, text, text, text, text, text, text),
  public.set_item_priority(text, text, text) from public;
grant execute on function public.save_item(text, text, text, text, text, text, text, text),
  public.set_item_priority(text, text, text) to anon, authenticated;
