-- City spots and events: real venues and real upcoming events for Calgary, Edmonton, Vancouver and Toronto.
--  * Spots = places + venues rows, so they show under Spots for members near each city (get_partner_venues
--    only lists venues within 15 km of the member, so each city only sees its own).
--  * Event pins (concert halls, Platform, etc.) are places only, not venues.
--  * Events are real, publicly ticketed events, posted as public plans under the owner account, with the
--    organiser's link in the details. They drop off the feed on their own once they've passed.
--  * Safe to run more than once: places match on osm_id (or name + location), venues on place_id,
--    events on title + start time.
-- Run once in the Supabase SQL editor.

do $$
declare
  v_owner uuid;
  r record;
  v_place uuid;
begin
  select id into v_owner from profiles
   where is_admin and not coalesce(is_test, false)
   order by created_at limit 1;
  if v_owner is null then raise exception 'No owner (admin) profile found.'; end if;

  -- ---------------------------------------------------------------
  -- Places. partner = true makes it a Spot (venues row).
  -- ---------------------------------------------------------------
  create temp table _spots (
    key text primary key, osm_id text, name text, address text,
    lat double precision, lng double precision, partner boolean
  ) on commit drop;

  insert into _spots (key, osm_id, name, address, lat, lng, partner) values
  -- Calgary
  ('yyc_eau_claire',  'node/4838749324',  'Eau Claire Distillery',      '113 Sunset Blvd NW, Turner Valley, AB',            50.673784, -114.279938, true),
  ('yyc_business',    'node/12750849145', 'Business & Pleasure',        '1327 9 Ave SE, Inglewood, Calgary, AB',            51.040332, -114.032787, true),
  ('yyc_gigi',        'node/13129949701', 'Bar Gigi',                   '9 Ave NE, Crescent Heights, Calgary, AB',          51.060789, -114.055336, true),
  ('yyc_betty_lou',   'node/9980944103',  'Betty Lou''s Library',       '908 17 Ave SW, Beltline, Calgary, AB',             51.038043, -114.082201, true),
  ('yyc_platform',    null,               'Platform Innovation Centre', '407 9 Ave SE, Calgary, AB',                        51.044175, -114.055355, false),
  ('yyc_grey_eagle',  'way/1423141173',   'Grey Eagle Event Centre',    '3775 Grey Eagle Dr, Calgary, AB',                  51.007520, -114.145853, false),
  -- Edmonton
  ('yeg_alchemy',     null,               'Alchemy',                    'JW Marriott ICE District, 10360 102 St NW, Edmonton, AB', 53.545764, -113.496168, true),
  ('yeg_bower',       null,               'The Bower',                  '10538 Jasper Ave NW, Edmonton, AB',                53.541047, -113.502169, true),
  ('yeg_aura',        'node/12854757223', 'Aura Cocktail Bar',          '3759 Gateway Blvd NW, Edmonton, AB',               53.472957, -113.491446, true),
  ('yeg_trove',       null,               'Bar Trove',                  '10126 100 St NW, Edmonton, AB',                    53.541886, -113.491036, true),
  ('yeg_dollys',      null,               'Dolly''s Cocktail Bar',      '9902 109 St NW, Edmonton, AB',                     53.537457, -113.508770, true),
  ('yeg_midway',      null,               'Midway Music Hall',          '6107 104 St NW, Edmonton, AB',                     53.498502, -113.496525, false),
  ('yeg_winspear',    'way/221525673',    'Winspear Centre',            '4 Sir Winston Churchill Square, Edmonton, AB',     53.544242, -113.487090, false),
  ('yeg_ortona',      null,               'ArtsHub Ortona',             '9722 102 St NW, Edmonton, AB',                     53.535193, -113.495836, false),
  -- Vancouver
  ('yvr_arcana',      'node/13707307562', 'Arcana Food and Spirits',    '238 Abbott St, Gastown, Vancouver, BC',            49.283151, -123.106410, true),
  ('yvr_smiths',      'node/12641820076', 'Smith''s Irish Pub (The Forge)', '208 Carrall St, Gastown, Vancouver, BC',      49.282920, -123.104123, true),
  ('yvr_laowai',      'node/12765476601', 'Laowai',                     '251 E Georgia St, Chinatown, Vancouver, BC',       49.278708, -123.097977, true),
  ('yvr_key_party',   'node/7647499486',  'Key Party',                  '2305 Main St, Vancouver, BC',                      49.264435, -123.101164, true),
  ('yvr_hellogoodbye',null,               'Hellogoodbye Bar',           '1120 Hamilton St, Yaletown, Vancouver, BC',        49.275463, -123.121328, true),
  ('yvr_alimentaria', 'way/715156944',    'Alimentaria Mexicana',       '1596 Johnston St, Granville Island, Vancouver, BC', 49.271648, -123.134911, false),
  ('yvr_hilton',      'node/7110365109',  'Hilton Vancouver Metrotown', '6083 McKay Ave, Burnaby, BC',                      49.228885, -123.004362, false),
  -- Toronto
  ('yyz_secrette',    null,               'Secrette',                   'Above GEORGE, 111 Queen St E, Toronto, ON',        43.653262,  -79.374182, true),
  ('yyz_bibliotheque',null,               'Bibliothèque',               '225 Richmond St W, Toronto, ON',                   43.649128,  -79.389207, true),
  ('yyz_scream',      null,               'S''cream Speakeasy',         '126 Cumberland St, Yorkville, Toronto, ON',        43.670272,  -79.392102, true),
  ('yyz_cry_baby',    'node/6820739726',  'Cry Baby Gallery',           '1468 Dundas St W, Toronto, ON',                    43.649723,  -79.430930, true),
  ('yyz_serene',      null,               'Bar Serene',                 '656 College St, Little Italy, Toronto, ON',        43.655240,  -79.416400, true),
  ('yyz_reids',       null,               'Reid''s Distillery',         '32 Logan Ave, Toronto, ON',                        43.655200,  -79.340408, true);

  create temp table _map (key text primary key, place_id uuid) on commit drop;

  for r in select * from _spots loop
    v_place := null;
    if r.osm_id is not null then
      select id into v_place from places where osm_id = r.osm_id;
    end if;
    if v_place is null then
      select id into v_place from places
       where lower(name) = lower(r.name) and abs(lat - r.lat) < 0.002 and abs(lng - r.lng) < 0.002
       limit 1;
    end if;
    if v_place is null then
      insert into places (osm_id, name, address, lat, lng, created_by)
      values (r.osm_id, r.name, r.address, r.lat, r.lng, v_owner)
      returning id into v_place;
    end if;
    insert into _map values (r.key, v_place);
    if r.partner then
      insert into venues (place_id) values (v_place) on conflict (place_id) do nothing;
    end if;
  end loop;

  -- ---------------------------------------------------------------
  -- Events (local times)
  -- ---------------------------------------------------------------
  create temp table _events (
    title text, details text, spot text, place_label text,
    starts_at timestamptz, lat double precision, lng double precision
  ) on commit drop;

  insert into _events (title, details, spot, place_label, starts_at, lat, lng) values
  -- Calgary
  ('Tech the Halls',
   'MNP''s holiday celebration for Calgary''s tech community, 5:30–9:30 PM. Space is limited; register by Nov 27. Venue is sent on registration. https://www.mnp.ca/en/insights/directory/tech-the-halls-calgary-2026',
   null, 'Calgary (venue sent on registration)', '2026-12-03 17:30 America/Edmonton', 51.0447, -114.0719),
  ('Tech Talent Tuesdays',
   'Platform Calgary''s free series connecting the city''s tech workforce with employers. Free. https://www.showpass.com/tech-talent-tuesdays-2026-series/',
   'yyc_platform', null, '2026-12-08 16:30 America/Edmonton', null, null),
  ('Community Connect: founders'' networking lunch',
   'Platform Calgary''s monthly networking lunch for the people building Calgary''s tech scene. East Annex. https://platformcalgary.com',
   'yyc_platform', null, '2026-12-10 11:30 America/Edmonton', null, null),
  ('Trooper New Year''s Eve',
   'Ring in 2027 with Trooper at the Grey Eagle Event Centre. 8 PM. $79.94–$110.99 + fees. https://www.todocanada.ca/city/calgary/event/trooper-new-years-eve/',
   'yyc_grey_eagle', null, '2026-12-31 20:00 America/Edmonton', null, null),
  -- Edmonton
  ('The Funk Hunters',
   'The Funk Hunters live at Midway Music Hall. 8 PM. Tickets from $47. https://dailyhive.com/edmonton/concerts-in-edmonton-december-2026',
   'yeg_midway', null, '2026-12-04 20:00 America/Edmonton', null, null),
  ('Handel''s Messiah',
   'Handel''s Messiah at the Winspear Centre. 7:30 PM (also Sat Dec 12). https://seatgeek.com/handels-messiah-tickets/edmonton',
   'yeg_winspear', null, '2026-12-11 19:30 America/Edmonton', null, null),
  ('New Year''s Eve with Pro Coro Canada',
   'An evening of choral music to welcome 2027. 7:30–9:30 PM. $50. https://www.todocanada.ca/city/edmonton/event/new-years-eve-with-pro-coro-canada/',
   'yeg_ortona', null, '2026-12-31 19:30 America/Edmonton', null, null),
  ('Studio 54 NYE Bash',
   'The Cask & Barrel and Lunar''s Studio 54 night to ring in 2027. 8 PM, 18+. Limited tickets. https://www.eventbrite.ca/e/2003556692000',
   null, '10357 Jasper Ave NW, Edmonton', '2026-12-31 20:00 America/Edmonton', 53.540684, -113.498968),
  -- Vancouver
  ('Mezcal Workshop & Taco Tasting',
   'An intimate mezcal workshop and taco tasting with chef Martín Vargas. 6:30–8:30 PM. C$85. https://ma.to/event/mezcal-workshop-taco-tasting-10-dec-2026',
   'yvr_alimentaria', null, '2026-12-10 18:30 America/Vancouver', null, null),
  ('NYE Glitz & Glamour Party',
   'Melo Productions'' New Year''s Eve party at the Hilton Vancouver Metrotown. 6 PM–2 AM. From $125. https://dailyhive.com/vancouver/listed/events/2660/new-year-s-eve-glitz-glamour-party',
   'yvr_hilton', null, '2026-12-31 18:00 America/Vancouver', null, null),
  -- Toronto
  ('Holiday Sundays at Reid''s',
   'Holiday afternoons in Reid''s Distillery lounge, 4–7 PM (also Dec 13 and 20), collecting hygiene products and diapers for local families. https://www.exploretock.com/reidsdistilleryinc/event/617952',
   'yyz_reids', null, '2026-12-06 16:00 America/Toronto', null, null),
  ('Studio 32: NYE at Reid''s Distillery',
   'Reid''s turns into Studio 32 for New Year''s Eve. 9 PM–2 AM. $48. https://www.exploretock.com/reidsdistilleryinc/help/',
   'yyz_reids', null, '2026-12-31 21:00 America/Toronto', null, null);

  insert into events (creator_id, title, details, place_name, starts_at, lat, lng, audience, status, place_id)
  select v_owner, e.title, e.details,
         coalesce(p.name, e.place_label), e.starts_at,
         coalesce(p.lat, e.lat), coalesce(p.lng, e.lng),
         'public', 'active', p.id
  from _events e
  left join _map m on m.key = e.spot
  left join places p on p.id = m.place_id
  where e.starts_at > now()
    and not exists (select 1 from events x where x.title = e.title and x.starts_at = e.starts_at);
end $$;
