-- BrewTrivia — Supabase schema
-- Paste the whole file into Supabase → SQL Editor → Run. Safe to run twice.
-- Needs no dashboard toggles: guests play with a device token, accounts use Supabase Auth.

create extension if not exists pgcrypto;

-- ═══ profiles — one row per signed-in account (Google / email) ═══
create table if not exists public.profiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default 'Player' check (char_length(display_name) between 1 and 40),
  created_at   timestamptz not null default now()
);
alter table public.profiles enable row level security;
drop policy if exists profiles_read       on public.profiles;
drop policy if exists profiles_insert_own on public.profiles;
drop policy if exists profiles_update_own on public.profiles;
create policy profiles_read       on public.profiles for select using (true);
create policy profiles_insert_own on public.profiles for insert with check ((select auth.uid()) = id);
create policy profiles_update_own on public.profiles for update using ((select auth.uid()) = id);

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, display_name)
  values (new.id, left(coalesce(
    nullif(new.raw_user_meta_data->>'display_name', ''),
    nullif(new.raw_user_meta_data->>'full_name', ''),
    nullif(new.raw_user_meta_data->>'name', ''),
    'Player'), 40))
  on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users for each row execute function public.handle_new_user();

-- ═══ guests — players who never sign up ═══════════════════════════
-- id  = secret the phone keeps and sends in the x-guest-token header
-- key = public id used in scores and rankings
create table if not exists public.guests (
  id           uuid primary key,
  key          uuid not null unique,
  display_name text not null default 'Player' check (char_length(display_name) between 1 and 40),
  created_at   timestamptz not null default now()
);
alter table public.guests enable row level security;

create or replace function public.guest_token() returns text
language sql stable as $$
  select nullif(nullif(current_setting('request.headers', true), '')::json ->> 'x-guest-token', '')
$$;
create or replace function public.guest_key() returns uuid
language sql stable security definer set search_path = public as $$
  select g.key from public.guests g where g.id::text = public.guest_token() limit 1
$$;

drop policy if exists guests_insert_own on public.guests;
drop policy if exists guests_select_own on public.guests;
drop policy if exists guests_update_own on public.guests;
create policy guests_insert_own on public.guests for insert with check (id::text = public.guest_token());
create policy guests_select_own on public.guests for select using (id::text = public.guest_token());
create policy guests_update_own on public.guests for update
  using (id::text = public.guest_token()) with check (id::text = public.guest_token());

-- ═══ venues — bars, breweries, taprooms (owned by an account OR a guest phone) ═══
create table if not exists public.venues (
  id         uuid primary key default gen_random_uuid(),
  owner_id   uuid references auth.users(id) on delete cascade,
  owner_key  uuid references public.guests(key) on delete cascade,
  name       text not null check (char_length(name) between 1 and 80),
  address    text not null,
  city       text not null default '',
  state      text not null default '' check (char_length(state) <= 2),
  quiz_day   text not null default 'Wednesday',
  start_time text not null default '7:00 PM',
  prize      text not null default '',
  code       text not null,
  tz         text not null default 'America/New_York',
  lat        double precision,
  lng        double precision,
  created_at timestamptz not null default now(),
  check ((owner_id is not null) <> (owner_key is not null))
);
create unique index if not exists venues_one_per_owner on public.venues(owner_id);
create unique index if not exists venues_one_per_guest on public.venues(owner_key);
alter table public.venues enable row level security;

create or replace function public.owns_venue(v uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.venues x where x.id = v
    and ((x.owner_id is not null and x.owner_id = auth.uid())
      or (x.owner_key is not null and x.owner_key = public.guest_key())))
$$;
drop policy if exists venues_read       on public.venues;
drop policy if exists venues_insert_own on public.venues;
drop policy if exists venues_update_own on public.venues;
drop policy if exists venues_delete_own on public.venues;
create policy venues_read       on public.venues for select using (true);
create policy venues_insert_own on public.venues for insert with check (
  (owner_id is not null and owner_id = (select auth.uid()))
  or (owner_key is not null and owner_key = public.guest_key()));
create policy venues_update_own on public.venues for update using (public.owns_venue(id));
create policy venues_delete_own on public.venues for delete using (public.owns_venue(id));

-- ═══ questions — written by the venue ═════════════════════════════
create table if not exists public.questions (
  id         uuid primary key default gen_random_uuid(),
  venue_id   uuid not null references public.venues(id) on delete cascade,
  question   text not null check (char_length(question) between 1 and 500),
  answers    text[] not null check (cardinality(answers) = 4),
  correct    smallint not null check (correct between 0 and 3),
  category   text not null default 'General',
  sort_order int not null default 0,
  created_at timestamptz not null default now()
);
create index if not exists questions_venue_idx on public.questions(venue_id, sort_order, created_at);
alter table public.questions enable row level security;
drop policy if exists questions_read         on public.questions;
drop policy if exists questions_owner_insert on public.questions;
drop policy if exists questions_owner_update on public.questions;
drop policy if exists questions_owner_delete on public.questions;
create policy questions_read on public.questions for select using (true);
create policy questions_owner_insert on public.questions for insert with check (public.owns_venue(venue_id));
create policy questions_owner_update on public.questions for update using (public.owns_venue(venue_id));
create policy questions_owner_delete on public.questions for delete using (public.owns_venue(venue_id));

-- ═══ scores — one row per team per game (account OR guest) ════════
create table if not exists public.scores (
  id        uuid primary key default gen_random_uuid(),
  venue_id  uuid not null references public.venues(id) on delete cascade,
  user_id   uuid references auth.users(id) on delete cascade,
  guest_key uuid references public.guests(key) on delete cascade,
  team_name text not null check (char_length(team_name) between 1 and 40),
  players   smallint not null check (players between 1 and 10),
  score     int not null check (score between 0 and 50000),
  played_at timestamptz not null default now(),
  check ((user_id is not null) <> (guest_key is not null))
);
create index if not exists scores_venue_time_idx on public.scores(venue_id, played_at desc);
create index if not exists scores_user_idx  on public.scores(user_id);
create index if not exists scores_guest_idx on public.scores(guest_key);
alter table public.scores enable row level security;
drop policy if exists scores_read       on public.scores;
drop policy if exists scores_insert_own on public.scores;
create policy scores_read on public.scores for select using (true);
create policy scores_insert_own on public.scores for insert with check (
  (user_id is not null and user_id = (select auth.uid()))
  or (guest_key is not null and guest_key = public.guest_key())
);

-- Live leaderboard over Realtime
do $$ begin
  if not exists (select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'scores') then
    alter publication supabase_realtime add table public.scores;
  end if;
end $$;

-- ═══ Tonight's board for one venue, in the venue's own time zone ════
create or replace function public.venue_board(venue uuid)
returns table (team_name text, players smallint, score int, played_at timestamptz, mine boolean)
language sql stable security definer set search_path = public as $$
  select s.team_name, s.players, s.score, s.played_at,
         (s.user_id is not null and s.user_id = auth.uid())
         or (s.guest_key is not null and s.guest_key = public.guest_key()) as mine
  from public.scores s
  join public.venues ve on ve.id = s.venue_id
  where s.venue_id = venue
    and (s.played_at at time zone ve.tz)::date = (now() at time zone ve.tz)::date
  order by s.score desc, s.played_at asc
  limit 200;
$$;

-- ═══ National ranking — every player, every venue ══════════════════
create or replace function public.ranking(period text default 'all')
returns table (display_name text, points bigint, games bigint, mine boolean)
language sql stable security definer set search_path = public as $$
  select coalesce(p.display_name, g.display_name, 'Player') as display_name,
         sum(s.score)::bigint as points, count(*)::bigint as games,
         bool_or((s.user_id is not null and s.user_id = auth.uid())
              or (s.guest_key is not null and s.guest_key = public.guest_key())) as mine
  from public.scores s
  left join public.profiles p on p.id = s.user_id
  left join public.guests g on g.key = s.guest_key
  where period <> 'week' or s.played_at >= date_trunc('week', now())
  group by coalesce(s.user_id::text, s.guest_key::text), p.display_name, g.display_name
  order by points desc
  limit 100;
$$;

-- ═══ Caller's own totals ═══════════════════════════════════════════
create or replace function public.my_stats()
returns table (points bigint, games bigint)
language sql stable security definer set search_path = public as $$
  select coalesce(sum(s.score), 0)::bigint, count(*)::bigint
  from public.scores s
  where (s.user_id is not null and s.user_id = auth.uid())
     or (s.guest_key is not null and s.guest_key = public.guest_key());
$$;

-- ═══ After signing in on a phone that played as a guest: move the points and venue over ═══
create or replace function public.claim_guest_scores()
returns int language plpgsql security definer set search_path = public as $$
declare n int; k uuid;
begin
  if auth.uid() is null then return 0; end if;
  k := public.guest_key();
  if k is null then return 0; end if;
  update public.scores set user_id = auth.uid(), guest_key = null where guest_key = k;
  get diagnostics n = row_count;
  update public.venues set owner_id = auth.uid(), owner_key = null
    where owner_key = k and not exists (select 1 from public.venues o where o.owner_id = auth.uid());
  update public.profiles p set display_name = g.display_name
    from public.guests g where p.id = auth.uid() and g.key = k and p.display_name = 'Player';
  return n;
end $$;
