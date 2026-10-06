-- Cities: pick the city you want to meet people in (Edit profile), shown on Home.
-- Calgary is the only open city for now; Based opens more from The door as it grows.
-- Ouch picks only show people in the same city.

create table if not exists public.cities (
  slug       text primary key,
  name       text not null,
  region     text,
  lat        double precision,
  lng        double precision,
  active     boolean not null default false,
  sort       int not null default 100,
  created_at timestamptz not null default now()
);
alter table public.cities enable row level security;   -- functions only

insert into public.cities (slug, name, region, lat, lng, active, sort)
values ('calgary', 'Calgary', 'Alberta', 51.0447, -114.0719, true, 1)
on conflict (slug) do nothing;

alter table public.profiles add column if not exists city text not null default 'calgary' references public.cities(slug);

-- only open cities can be picked (the profile can't be pointed at one that isn't open)
create or replace function public.tg_city_guard()
returns trigger language plpgsql as $$
begin
  if new.city is distinct from old.city
     and not exists (select 1 from cities where slug = new.city and active) then
    raise exception 'That city isn''t open yet.';
  end if;
  return new;
end $$;
drop trigger if exists profile_city_guard on public.profiles;
create trigger profile_city_guard before update of city on public.profiles
  for each row execute function public.tg_city_guard();

-- open cities, for the pull-down
create or replace function public.get_cities()
returns table (slug text, name text, region text)
language sql stable security definer set search_path = public as $$
  select slug, name, region from cities where active order by sort, name;
$$;

create or replace function public.my_city()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('slug', c.slug, 'name', c.name, 'region', c.region)
  from profiles p join cities c on c.slug = p.city where p.id = auth.uid();
$$;

create or replace function public.set_city(p_city text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from cities where slug = p_city and active) then
    raise exception 'That city isn''t open yet.';
  end if;
  update profiles set city = p_city where id = auth.uid();
  return my_city();
end $$;

-- ---------- admin: add and open cities ----------
create or replace function public.admin_cities()
returns table (slug text, name text, region text, active boolean, members int)
language plpgsql stable security definer set search_path = public as $$
begin
  perform require_admin();
  return query
  select c.slug, c.name, c.region, c.active, (select count(*)::int from profiles p where p.city = c.slug)
  from cities c order by c.active desc, c.sort, c.name;
end $$;

create or replace function public.admin_add_city(p_name text, p_region text default null)
returns text language plpgsql security definer set search_path = public as $$
declare
  v_slug text := trim(both '-' from regexp_replace(lower(trim(p_name)), '[^a-z0-9]+', '-', 'g'));
begin
  perform require_admin();
  if coalesce(v_slug, '') = '' then raise exception 'Give the city a name.'; end if;
  insert into cities (slug, name, region) values (v_slug, trim(p_name), nullif(trim(p_region), ''))
  on conflict (slug) do update set name = excluded.name, region = coalesce(excluded.region, cities.region);
  return v_slug;
end $$;

create or replace function public.admin_set_city_active(p_city text, p_active boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform require_admin();
  if not p_active and exists (select 1 from profiles where city = p_city) then
    raise exception 'Members are in that city. Move them first.';
  end if;
  update cities set active = p_active where slug = p_city;
end $$;

create or replace function public.get_match_batch(p_limit int default 10)
returns table (
  user_id uuid, display_name text, age int, distance_km int,
  shared_topics text[], photo_paths text[]
)
language plpgsql security definer set search_path = public as $$
declare
  me       uuid := auth.uid();
  v        profiles;
  v_tier   text;
  v_des    real;
  v_acted  int;
  v_cap    int := daily_pick_cap(auth.uid());
begin
  select * into v from profiles where id = me;
  if v.id is null or v.status <> 'active' or v.lat is null or not v.dating_on then return; end if;

  v_tier := effective_tier(me);
  if v_tier = 'invisible' then return; end if;

  select count(*) into v_acted from (
    select 1 from likes  where from_user = me and created_at > now() - interval '1 day'
    union all
    select 1 from passes where from_user = me and created_at > now() - interval '1 day') x;
  if v_acted >= v_cap then return; end if;

  select s.desirability into v_des from user_scores s where s.user_id = me;

  create temp table if not exists _batch (
    user_id uuid, display_name text, age int, distance_km int,
    shared_topics text[], photo_paths text[], rn bigint) on commit drop;
  truncate _batch;

  insert into _batch
  with cand as (
    select c.id, c.display_name, c.birthdate,
           haversine_km(v.lat, v.lng, c.lat, c.lng) as km,
           effective_tier(c.id) as tier,
           abs(coalesce(s.desirability, 0.5) - coalesce(v_des, 0.5)) as gap,
           match_features(me, c.id) as f
    from profiles c
    left join user_scores s on s.user_id = c.id
    where c.id <> me
      and c.status = 'active'
      and c.dating_on
      and c.city = v.city                    -- the city you picked
      and c.lat is not null
      and c.gender = any (v.seeking)
      and v.gender = any (c.seeking)
      and not exists (select 1 from likes  l where l.from_user = me and l.to_user = c.id)
      and not exists (select 1 from passes p where p.from_user = me and p.to_user = c.id)
      and not exists (select 1 from matches m where m.user_a = least(me, c.id) and m.user_b = greatest(me, c.id))
      and not exists (select 1 from blocks b where (b.blocker = me and b.blocked = c.id) or (b.blocker = c.id and b.blocked = me))
  ),
  scored as (
    select cand.*,
           distance_block(km) as blk,
           (select coalesce(array_agg(t.name order by t.name), '{}')
              from user_topics a join user_topics b on a.topic_id = b.topic_id and b.user_id = cand.id
              join topics t on t.id = a.topic_id
             where a.user_id = me) as shared
    from cand
    where distance_block(km) is not null
      and tier <> 'invisible'
      and ((v_tier = 'low' and tier in ('low','slipping'))
        or (v_tier <> 'low' and tier in ('healthy','slipping')))
  ),
  w as (select * from my_match_weights(me)),
  ranked as (
    select scored.*,
           row_number() over (order by
             blk,
             case tier when 'healthy' then 0 when 'slipping' then 1 else 2 end,
             -- learned per person: how much they care about interests, temperament, schedule, distance, style.
             -- Inside 10 km interests count double; further out, closeness counts double.
             -( (case when blk = 10 then 2 else 1 end) * w.wi * (f ->> 'interests')::real
              + w.wt * (f ->> 'temperament')::real
              + w.ws * (f ->> 'schedule')::real
              + (case when blk = 10 then 1 else 2 end) * w.wd * (f ->> 'distance')::real
              + w.wy * (f ->> 'style')::real
              - 1.5 * gap)) as rn
    from scored cross join w
  )
  select r.id, r.display_name,
         extract(year from age(r.birthdate))::int,
         greatest(1, round(r.km))::int,
         r.shared,
         (select coalesce(array_agg(ph.storage_path order by ph.position), '{}')
            from photos ph where ph.user_id = r.id and ph.review_status = 'approved'),
         r.rn
  from ranked r
  where r.rn <= least(p_limit, v_cap - v_acted);

  insert into impressions (viewer, shown)
  select me, b.user_id from _batch b
  on conflict do nothing;

  return query
    select b.user_id, b.display_name, b.age, b.distance_km, b.shared_topics, b.photo_paths
    from _batch b order by b.rn;
end $$;

do $$
declare f text;
begin
  foreach f in array array[
    'public.get_cities()', 'public.my_city()', 'public.set_city(text)', 'public.admin_cities()',
    'public.admin_add_city(text,text)', 'public.admin_set_city_active(text,boolean)', 'public.get_match_batch(int)'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
