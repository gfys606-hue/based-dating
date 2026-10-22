-- The public waitlist on based-social.com (pre-testing priority 1, Oct 21 2026).
--  * No account needed: email, city, optional reference code (a member's invite code), 18+.
--  * Open cities come from a picker; anyone elsewhere can still sign up for their city ("tentative" city).
--    When that city opens, its sign-ups are linked to it automatically and get let in through spot drops.
--  * A valid reference code puts you ahead of people without one (then earliest first). The code isn't used up.
--  * The confirmation is just "You're on the list": nobody is ever shown their place in line.
-- Safe to re-run.

alter table public.waitlist add column if not exists ref_code text;
alter table public.waitlist add column if not exists ref_valid boolean not null default false;

-- Cities for the website picker (works signed out)
create or replace function public.waitlist_cities()
returns table (slug text, name text, region text, cap int, members int)
language sql stable security definer set search_path = public as $$
  select c.slug, c.name, c.region, c.member_cap, city_members(c.slug)
  from cities c where c.active order by c.sort, c.name;
$$;

create or replace function public.join_waitlist_site(p_email text, p_city text, p_ref text default null, p_adult boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  e text := lower(btrim(coalesce(p_email, '')));
  v_city text := left(btrim(coalesce(p_city, '')), 80);
  v_slug text;
  v_ref text := nullif(upper(regexp_replace(coalesce(p_ref, ''), '[^A-Za-z0-9]', '', 'g')), '');
  v_valid boolean := false;
begin
  if e !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter a real email.'; end if;
  if char_length(v_city) < 2 then raise exception 'Which city are you in?'; end if;
  if not coalesce(p_adult, false) then raise exception 'Based is 18+ only.'; end if;

  select slug into v_slug from cities
   where active and (slug = lower(v_city) or lower(name) = lower(v_city)) limit 1;

  if v_ref is not null then
    if char_length(v_ref) = 8 then v_ref := left(v_ref, 4) || '-' || right(v_ref, 4); end if;
    v_valid := exists (select 1 from invite_codes where code = v_ref and active);
  end if;

  insert into waitlist (email, city, city_slug, ref_code, ref_valid, vouches, last_vouched_at, is_adult, source)
  values (e, coalesce((select name from cities where slug = v_slug), initcap(v_city)), v_slug, v_ref, v_valid,
          case when v_valid then 1 else 0 end, case when v_valid then now() end, true, 'website')
  on conflict ((lower(email))) do update
     set city      = coalesce(waitlist.city, excluded.city),
         city_slug = coalesce(waitlist.city_slug, excluded.city_slug),
         ref_code  = coalesce(waitlist.ref_code, excluded.ref_code),
         ref_valid = waitlist.ref_valid or excluded.ref_valid,
         vouches   = greatest(waitlist.vouches, excluded.vouches),
         last_vouched_at = coalesce(waitlist.last_vouched_at, excluded.last_vouched_at);
  return jsonb_build_object('ok', true, 'city_open', v_slug is not null, 'ref_valid', v_valid);
end $$;

-- Opening a city links everyone who signed up for it ahead of time
create or replace function public.admin_set_city_active(p_city text, p_active boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform require_admin();
  if not p_active and exists (select 1 from profiles where city = p_city) then
    raise exception 'Members are in that city. Move them first.';
  end if;
  update cities set active = p_active where slug = p_city;
  if p_active then
    update waitlist w set city_slug = c.slug
      from cities c
     where c.slug = p_city and w.city_slug is null
       and lower(btrim(w.city)) in (c.slug, lower(c.name));
  end if;
end $$;

drop function if exists public.admin_waitlist();
create or replace function public.admin_waitlist()
returns table (id bigint, email text, name text, note text, status text, invite_code text, created_at timestamptz,
               city text, vouches int, has_account boolean, ref_code text, ref_valid boolean, city_open boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  perform require_admin();
  return query select w.id, w.email, w.name, w.note, w.status, w.invite_code, w.created_at,
                      coalesce(c.name, w.city), w.vouches, w.user_id is not null, w.ref_code, w.ref_valid,
                      c.slug is not null
               from waitlist w left join cities c on c.slug = w.city_slug
               order by (w.status = 'waiting') desc, (w.vouches > 0) desc, w.vouches desc, w.created_at;
end $$;

-- Tentative cities: where people are asking for Based next (admin)
create or replace function public.admin_city_demand()
returns table (city text, waiting int, with_reference int, first_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  perform require_admin();
  return query
  select initcap(lower(btrim(w.city))), count(*)::int, count(*) filter (where w.ref_valid)::int, min(w.created_at)
  from waitlist w
  where w.city_slug is null and w.status = 'waiting' and coalesce(btrim(w.city), '') <> ''
  group by initcap(lower(btrim(w.city)))
  order by count(*) desc, min(w.created_at);
end $$;

do $$
declare f text;
begin
  foreach f in array array['public.waitlist_cities()', 'public.join_waitlist_site(text,text,text,boolean)'] loop
    execute format('revoke all on function %s from public', f);
    execute format('grant execute on function %s to anon, authenticated', f);
  end loop;
  foreach f in array array['public.admin_set_city_active(text,boolean)', 'public.admin_waitlist()', 'public.admin_city_demand()'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
