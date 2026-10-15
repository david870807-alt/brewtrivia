-- BrewTrivia v2.0 — server update (Supabase migration `brewtrivia_v2_server`)
--
-- Purely additive: new columns, new functions, and in-place replacements of existing functions with
-- the same signatures. Builds on the 2026-10-15 00:43 migrations (closest-number trigger, team size
-- capped at 6, active-team instant lock, two-answer scoring, TV final answers) and keeps the v1 app
-- working: v1 keeps calling host_game / game_state, v2 calls host_game2 / game_state2.
--
--  #2  host_game2: the host can open the next question at any time; a double tap is ignored.
--      Instant lock waits only for active teams: answered one of the last two questions or this one,
--      or joined in the last 10 minutes. Host-added paper teams never hold it up.
--  #4  Number questions: the closest answer(s) win, ties all win, the tolerance still counts
--      (also re-graded on the server every time scores are recomputed).
--  #6  Reveal step: with venues.manual_reveal on, a locked question stays hidden on the TV and the
--      phones until host_game2(venue, 'reveal'). Scores never include a question that is still open
--      or waiting for its reveal, so the standings cannot give the answer away.
--  #9  tv_state: the final's reveal lists every team's answer, wager and points.
--  #10 host_game2(venue, 'end') closes the game for everyone after the final standings.
--  #11 venue_results(venue): public results history for a venue.

-- ---------------------------------------------------------------- columns
alter table public.games  add column if not exists revealed_at timestamptz;
alter table public.games  add column if not exists closed_at   timestamptz;
alter table public.venues add column if not exists manual_reveal boolean not null default false;

-- ---------------------------------------------------------------- #2 who counts as active
create or replace function public.all_active_answered(p_venue uuid, p_date date, p_qid uuid)
returns boolean
language sql stable security definer set search_path to 'public'
as $$
  with o as (select x.qid, x.idx from public.venue_question_order(p_venue) x),
       cur as (select o.idx from o where o.qid = p_qid),
       prev as (select o.qid from o, cur where o.idx < cur.idx and o.idx >= cur.idx - 2),
       quiet as (select not exists (select 1 from public.game_answers ga        -- first question, or nobody
                                     where ga.game_date = p_date                -- answered the last two:
                                       and ga.answered_at is not null           -- then every phone team counts
                                       and ga.question_id in (select prev.qid from prev)) as yes),
       active as (
         select s.user_id
           from public.scores s, quiet
          where s.venue_id = p_venue and s.game_date = p_date and s.user_id is not null
            and (    quiet.yes
                  or s.played_at > now() - interval '10 minutes'
                  or exists (select 1 from public.game_answers ga
                              where ga.user_id = s.user_id and ga.game_date = p_date
                                and ga.answered_at is not null
                                and ga.question_id in (select prev.qid from prev))
                  or exists (select 1 from public.game_answers ga
                              where ga.user_id = s.user_id and ga.game_date = p_date
                                and ga.answered_at is not null and ga.question_id = p_qid)))
  select exists (select 1 from active)
     and not exists (select 1 from active t
                      where not exists (select 1 from public.game_answers ga
                                         where ga.user_id = t.user_id and ga.question_id = p_qid
                                           and ga.game_date = p_date and ga.answered_at is not null));
$$;

-- ---------------------------------------------------------------- #4 closest number wins
-- Runs with the caller's rights: called from the security-definer functions below; a direct call by a
-- player changes nothing (row-level security).
create or replace function public.grade_numeric(p_venue uuid, p_date date)
returns void
language plpgsql set search_path to 'public'
as $$
declare g public.games; lk boolean;
begin
  select * into g from public.games x where x.venue_id = p_venue and x.game_date = p_date;
  if not found then return; end if;
  lk := g.status in ('finished','standings')
        or (g.status = 'closing' and g.closes_at is not null and now() >= g.closes_at);
  with qs as (
         select q.id, q.correct_num, q.num_tolerance
           from public.questions q
          where q.venue_id = p_venue and q.qtype = 'num' and q.correct_num is not null
            and (q.id is distinct from g.current_qid or lk)
            and exists (select 1 from public.game_answers ga
                         where ga.question_id = q.id and ga.game_date = p_date and ga.answered_at is not null)),
       best as (
         select ga.question_id, min(abs(ga.pick_num - qs.correct_num)) as dist
           from public.game_answers ga join qs on qs.id = ga.question_id
          where ga.game_date = p_date and ga.answered_at is not null and ga.pick_num is not null
          group by ga.question_id),
       calc as (
         select ga.id,
                (ga.pick_num is not null
                 and abs(ga.pick_num - qs.correct_num) <= greatest(qs.num_tolerance, b.dist)) as ok,
                ga.wager
           from public.game_answers ga
           join qs     on qs.id = ga.question_id
           join best b on b.question_id = ga.question_id
          where ga.game_date = p_date and ga.answered_at is not null)
  update public.game_answers ga
     set points = case when c.ok then c.wager else 0 end,
         is_correct = c.ok
    from calc c
   where ga.id = c.id
     and (ga.points is distinct from (case when c.ok then c.wager else 0 end) or ga.is_correct is distinct from c.ok);
end $$;

-- ---------------------------------------------------------------- #6 no spoilers in the scores
-- The question whose points must not count yet: the current one while it is open, in last call, or
-- locked but still waiting for the host's reveal. NULL when nothing is hidden.
create or replace function public.hidden_qid(p_venue uuid, p_date date)
returns uuid
language sql stable set search_path to 'public'
as $$
  select g.current_qid
    from public.games g join public.venues v on v.id = g.venue_id
   where g.venue_id = p_venue and g.game_date = p_date
     and g.status in ('open','closing')
     and not coalesce(g.status = 'closing' and g.closes_at is not null and now() >= g.closes_at
                      and (not v.manual_reveal or g.revealed_at is not null), false);
$$;

create or replace function public.recompute_scores(venue uuid, d date)
returns void
language plpgsql security definer set search_path to 'public'
as $$
declare hide uuid;
begin
  perform public.grade_numeric(venue, d);
  hide := public.hidden_qid(venue, d);
  update public.scores s
     set score = x.total
    from (select s2.id,
                 greatest(-1000, least(50000, coalesce((select sum(coalesce(ga.override_points, ga.points))::int
                                                          from public.game_answers ga
                                                         where ga.user_id = s2.user_id and ga.venue_id = s2.venue_id
                                                           and ga.game_date = s2.game_date
                                                           and ga.question_id is distinct from hide), 0) + s2.adjustment)) as total
            from public.scores s2
           where s2.venue_id = venue and s2.game_date = d) x
   where s.id = x.id and s.score is distinct from x.total;      -- unchanged rows are skipped (no realtime echo)
end $$;

-- ---------------------------------------------------------------- host actions for the v2 app (#2, #6, #10)
create or replace function public.host_game2(venue uuid, action text, idx integer default null::integer)
returns void
language plpgsql security definer set search_path to 'public'
as $$
declare
  uid uuid := (select auth.uid());
  d   date;
  g   record;
  q   record;
  n   int;
  lk  boolean;
begin
  if uid is null then raise exception 'not_signed_in'; end if;
  if not exists (select 1 from public.venues v where v.id = venue and v.owner_id = uid) then raise exception 'not_host'; end if;
  if action = 'reset' then
    perform public.host_game(venue, 'reset');                    -- same reset as v1
    return;
  end if;
  d := public.venue_today(venue);
  select count(*) into n from public.questions x where x.venue_id = venue;
  if n = 0 then raise exception 'no_questions'; end if;
  insert into public.games (venue_id, game_date) values (venue, d) on conflict (venue_id, game_date) do nothing;
  select * into g from public.games x where x.venue_id = venue and x.game_date = d for update;
  if action = 'start' then return; end if;
  if action = 'end' then                                         -- #10 close the game for everyone
    update public.games x
       set status = 'finished', finished_at = coalesce(x.finished_at, now()),
           closes_at = least(coalesce(x.closes_at, now()), now()), closed_at = coalesce(x.closed_at, now())
     where x.id = g.id;
    perform public.recompute_scores(venue, d);
    return;
  end if;
  if g.status = 'finished' then raise exception 'game_finished'; end if;
  lk := g.status in ('lobby','standings') or (g.status = 'closing' and now() >= g.closes_at);
  if action = 'open' then                                        -- #2 works at any time
    if idx is null or idx < 0 or idx >= n then raise exception 'no_question'; end if;
    if g.current_idx = idx and g.status in ('open','closing') then return; end if;   -- double tap
    select o.qid into q from public.venue_question_order(venue) o where o.idx = host_game2.idx;
    update public.games x
       set status = 'closing', closes_at = least(coalesce(x.closes_at, now()), now())   -- the previous question is over
     where x.id = g.id and x.status in ('open','closing');
    update public.games x
       set status = 'open', current_idx = host_game2.idx, current_qid = q.qid,
           opened_at = now(), closes_at = null, revealed_at = null
     where x.id = g.id;
    perform public.recompute_scores(venue, d);                   -- the previous question counts from now on
  elsif action = 'close' then
    if g.status <> 'open' then raise exception 'not_open'; end if;
    update public.games x set status = 'closing', closes_at = now() + interval '30 seconds' where x.id = g.id;
  elsif action = 'reveal' then                                   -- #6
    if not lk or g.current_qid is null then raise exception 'not_locked'; end if;
    update public.games x set revealed_at = coalesce(x.revealed_at, now()) where x.id = g.id;
    perform public.recompute_scores(venue, d);                   -- the revealed question now counts
  elsif action = 'standings' then
    update public.games x set status = 'standings', closes_at = null where x.id = g.id;
    perform public.recompute_scores(venue, d);
  elsif action = 'finish' then
    update public.games x set status = 'finished', finished_at = now(),
                             closes_at = least(coalesce(x.closes_at, now()), now())
     where x.id = g.id;
    perform public.recompute_scores(venue, d);
  else
    raise exception 'bad_action';
  end if;
end $$;

-- ---------------------------------------------------------------- player + host state (#6, #10)
-- game_state2 = game_state plus revealed / closed / manual_reveal; the v2 app reads this one.
create or replace function public.game_state2(venue uuid)
returns table(status text, idx integer, total integer, has_final boolean, is_final boolean, round_no integer,
              qid uuid, qtype text, qtext text, qanswers text[], qcategory text, final_max smallint,
              opened_at timestamptz, closes_at timestamptz, locked boolean,
              correct smallint, correct_set smallint[], correct_num numeric, num_tolerance numeric,
              my_pick smallint, my_pick_set smallint[], my_pick_num numeric, my_wager smallint, my_points integer,
              my_answered boolean, my_verdict boolean, used_wagers smallint[], answered_count integer, team_count integer,
              my_team text, my_players smallint, my_score integer, server_now timestamptz, is_host boolean,
              revealed boolean, closed boolean, manual_reveal boolean)
language plpgsql security definer set search_path to 'public'
as $$
declare
  uid       uuid := (select auth.uid());
  d         date;
  g         record;
  q         public.questions;
  host      boolean := false;
  mr        boolean := false;
  lk        boolean;
  rv        boolean;
  n         int;
  fin       boolean;
  teams     int;
  t_team    text;
  t_players smallint;
  t_score   int;
  a         record;
  used      smallint[];
begin
  d := public.venue_today(venue);
  select coalesce(v.owner_id = uid, false), coalesce(v.manual_reveal, false) into host, mr
    from public.venues v where v.id = venue;
  host := coalesce(host, false);
  mr   := coalesce(mr, false);
  select count(*) filter (where not x.is_final), bool_or(x.is_final) into n, fin from public.questions x where x.venue_id = venue;
  select count(*) into teams from public.scores s where s.venue_id = venue and s.game_date = d;
  select * into g from public.games x where x.venue_id = venue and x.game_date = d;
  if not found then
    select s.team_name, s.players, s.score into t_team, t_players, t_score
      from public.scores s where s.venue_id = venue and s.game_date = d and s.user_id = uid;
    return query select 'none'::text, null::int, n, coalesce(fin, false), false, null::int,
                        null::uuid, null::text, null::text, null::text[], null::text, null::smallint,
                        null::timestamptz, null::timestamptz, false,
                        null::smallint, null::smallint[], null::numeric, null::numeric,
                        null::smallint, null::smallint[], null::numeric, null::smallint,
                        null::int, false, null::boolean, '{}'::smallint[],
                        0, teams, t_team, t_players, t_score, now(), host,
                        false, false, mr;
    return;
  end if;
  lk := g.status in ('finished','standings') or (g.status = 'closing' and g.closes_at is not null and now() >= g.closes_at);
  rv := lk and (not mr or g.revealed_at is not null or g.status in ('standings','finished'));
  select x.* into q from public.questions x where x.id = g.current_qid;
  if host and lk and g.status <> 'finished' then
    perform public.recompute_scores(venue, d);                 -- also grades number questions
  elsif lk and q.qtype = 'num' then
    perform public.grade_numeric(venue, d);
  end if;
  select s.team_name, s.players, s.score into t_team, t_players, t_score
    from public.scores s where s.venue_id = venue and s.game_date = d and s.user_id = uid;
  select ga.pick, ga.pick_set, ga.pick_num, ga.wager, coalesce(ga.override_points, ga.points) as pts,
         (ga.answered_at is not null) as answered, ga.host_verdict
    into a from public.game_answers ga where ga.user_id = uid and ga.question_id = g.current_qid and ga.game_date = d;
  if q.is_final or g.current_idx is null then
    used := '{}';
  else
    select coalesce(array_agg(ga.wager order by ga.wager), '{}') into used
      from public.game_answers ga
      join public.venue_question_order(venue) o on o.qid = ga.question_id
     where ga.user_id = uid and ga.venue_id = venue and ga.game_date = d and ga.answered_at is not null
       and not o.is_final and o.idx / 5 = g.current_idx / 5 and ga.question_id is distinct from g.current_qid;
  end if;
  return query select g.status, g.current_idx, n, coalesce(fin, false), coalesce(q.is_final, false),
                      case when q.is_final then null else g.current_idx / 5 + 1 end,
                      q.id, q.qtype, q.question, q.answers, q.category, q.final_max,
                      g.opened_at, g.closes_at, lk,
                      case when rv or host then q.correct end,
                      case when rv or host then q.correct_set end,
                      case when rv or host then q.correct_num end,
                      case when rv or host then q.num_tolerance end,
                      a.pick, a.pick_set, a.pick_num, a.wager,
                      case when rv then a.pts end, coalesce(a.answered, false),
                      case when rv then a.host_verdict end, used,
                      (select count(*)::int from public.game_answers ga
                        where ga.question_id = g.current_qid and ga.game_date = d and ga.answered_at is not null),
                      teams, t_team, t_players, t_score, now(), host,
                      rv, g.closed_at is not null, mr;
end $$;

-- The v1 app keeps calling game_state: the same columns as before, the same rules as v2.
create or replace function public.game_state(venue uuid)
returns table(status text, idx integer, total integer, has_final boolean, is_final boolean, round_no integer,
              qid uuid, qtype text, qtext text, qanswers text[], qcategory text, final_max smallint,
              opened_at timestamptz, closes_at timestamptz, locked boolean,
              correct smallint, correct_set smallint[], correct_num numeric, num_tolerance numeric,
              my_pick smallint, my_pick_set smallint[], my_pick_num numeric, my_wager smallint, my_points integer,
              my_answered boolean, my_verdict boolean, used_wagers smallint[], answered_count integer, team_count integer,
              my_team text, my_players smallint, my_score integer, server_now timestamptz, is_host boolean)
language sql security definer set search_path to 'public'
as $$
  select s.status, s.idx, s.total, s.has_final, s.is_final, s.round_no, s.qid, s.qtype, s.qtext, s.qanswers,
         s.qcategory, s.final_max, s.opened_at, s.closes_at, s.locked, s.correct, s.correct_set, s.correct_num,
         s.num_tolerance, s.my_pick, s.my_pick_set, s.my_pick_num, s.my_wager, s.my_points, s.my_answered,
         s.my_verdict, s.used_wagers, s.answered_count, s.team_count, s.my_team, s.my_players, s.my_score,
         s.server_now, s.is_host
    from public.game_state2(venue) s;
$$;

-- ---------------------------------------------------------------- audience TV feed (#4, #6, #8, #9, #10)
-- Keeps the 00:43 fields too (reveal.winners, top-level final_answers with "name").
create or replace function public.tv_state(venue uuid)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare
  v         public.venues;
  g         public.games;
  q         public.questions;
  d         date;
  lk        boolean := false;
  rv        boolean := false;
  n         int := 0;
  fin       boolean := false;
  teams     jsonb := '[]'::jsonb;
  players   int := 0;
  answered  int := 0;
  correct_n int;
  dist      jsonb;
  best      numeric;
  wins      jsonb;
  finals    jsonb;
begin
  select * into v from public.venues x where x.id = tv_state.venue and x.approved;
  if not found then
    return null;
  end if;

  d := public.venue_today(v.id);

  select count(*) filter (where not x.is_final), coalesce(bool_or(x.is_final), false)
    into n, fin
    from public.questions x where x.venue_id = v.id;

  select coalesce(jsonb_agg(jsonb_build_object('name', s.team_name, 'players', s.players, 'score', s.score)
                            order by s.score desc, s.played_at asc), '[]'::jsonb),
         coalesce(sum(s.players), 0)::int
    into teams, players
    from public.scores s where s.venue_id = v.id and s.game_date = d;

  select * into g from public.games x where x.venue_id = v.id and x.game_date = d;
  if found then
    lk := g.status in ('finished', 'standings')
          or (g.status = 'closing' and g.closes_at is not null and now() >= g.closes_at);
    rv := lk and (not v.manual_reveal or g.revealed_at is not null or g.status in ('standings', 'finished'));

    if g.current_qid is not null then
      select * into q from public.questions x where x.id = g.current_qid;

      select count(*)::int into answered
        from public.game_answers ga
       where ga.question_id = g.current_qid and ga.game_date = d and ga.answered_at is not null;

      if rv then
        if q.qtype = 'num' then
          select min(abs(ga.pick_num - q.correct_num)) into best
            from public.game_answers ga
           where ga.question_id = q.id and ga.game_date = d and ga.answered_at is not null and ga.pick_num is not null;
          select (count(*) filter (where coalesce(ga.host_verdict,
                        ga.pick_num is not null and abs(ga.pick_num - q.correct_num) <= greatest(q.num_tolerance, coalesce(best, 0)))))::int,
                 coalesce(jsonb_agg(distinct trim_scale(ga.pick_num))
                          filter (where ga.pick_num is not null
                                    and abs(ga.pick_num - q.correct_num) <= greatest(q.num_tolerance, coalesce(best, 0))), '[]'::jsonb)
            into correct_n, wins
            from public.game_answers ga
           where ga.question_id = q.id and ga.game_date = d and ga.answered_at is not null;
        else
          select (count(*) filter (where coalesce(ga.host_verdict, ga.is_correct)))::int into correct_n
            from public.game_answers ga
           where ga.question_id = g.current_qid and ga.game_date = d and ga.answered_at is not null;

          select coalesce(jsonb_agg(t.cnt order by t.i), '[]'::jsonb) into dist
            from (
              select i,
                     (select count(*) from public.game_answers ga
                       where ga.question_id = g.current_qid and ga.game_date = d and ga.answered_at is not null
                         and (ga.pick = i or i = any(coalesce(ga.pick_set, '{}'::smallint[]))))::int as cnt
                from generate_series(0, coalesce(cardinality(q.answers), 0) - 1) as i
            ) t;
        end if;

        if q.is_final then                                       -- #9 every team's final answer
          select coalesce(jsonb_agg(jsonb_build_object(
                   'team',    s.team_name,
                   'name',    s.team_name,
                   'answer',  case when ga.id is null then null
                                   when q.qtype in ('mc', 'tf') then q.answers[ga.pick + 1]
                                   when q.qtype = 'multi' then (select string_agg(q.answers[i + 1], ' + ' order by i) from unnest(ga.pick_set) as i)
                                   when q.qtype = 'num' then trim_scale(ga.pick_num)::text end,
                   'wager',   ga.wager,
                   'points',  case when ga.id is null then null else coalesce(ga.override_points, ga.points) end,
                   'correct', case when ga.id is null then null else coalesce(ga.host_verdict, ga.is_correct) end,
                   'score',   s.score)
                   order by s.score desc, s.played_at asc), '[]'::jsonb)
            into finals
            from public.scores s
            left join public.game_answers ga
              on ga.user_id = s.user_id and ga.question_id = q.id and ga.game_date = d and ga.answered_at is not null
           where s.venue_id = v.id and s.game_date = d;
        end if;
      end if;
    end if;
  end if;

  return jsonb_build_object(
    'venue', jsonb_build_object('id', v.id, 'name', v.name, 'city', v.city, 'state', v.state, 'code', v.code,
                                'prize', v.prize, 'quiz_day', v.quiz_day, 'start_time', v.start_time),
    'server_now',      now(),
    'status',          coalesce(g.status, 'none'),
    'total',           n,
    'has_final',       fin,
    'rounds',          ceil(n / 5.0)::int,
    'idx',             g.current_idx,
    'is_final',        coalesce(q.is_final, false),
    'round_no',        case when q.id is not null and not q.is_final then g.current_idx / 5 + 1 end,
    'q_in_round',      case when q.id is not null and not q.is_final then g.current_idx % 5 + 1 end,
    'round_size',      case when q.id is not null and not q.is_final then least(5, n - (g.current_idx / 5) * 5) end,
    'opened_at',       g.opened_at,
    'closes_at',       g.closes_at,
    'locked',          lk,
    'revealed',        rv,
    'awaiting_reveal', coalesce(lk and not rv and g.status = 'closing', false),
    'manual_reveal',   v.manual_reveal,
    'closed',          coalesce(g.closed_at is not null, false),
    'question',        case when q.id is not null then jsonb_build_object(
                         'id', q.id, 'type', q.qtype, 'text', q.question,
                         'answers', to_jsonb(coalesce(q.answers, '{}'::text[])),
                         'category', q.category, 'final_max', q.final_max) end,
    'answered',        answered,
    'reveal',          case when rv and q.id is not null then jsonb_build_object(
                         'correct', q.correct, 'correct_set', to_jsonb(q.correct_set),
                         'correct_num', q.correct_num, 'num_tolerance', q.num_tolerance,
                         'correct_count', correct_n, 'dist', dist,
                         'closest', wins, 'winners', wins, 'final_answers', finals) end,
    'final_answers',   finals,
    'team_count',      jsonb_array_length(teams),
    'player_count',    players,
    'teams',           teams
  );
end $$;

-- ---------------------------------------------------------------- #11 results history
create or replace function public.venue_results(venue uuid, max_games integer default 30)
returns jsonb
language sql stable security definer set search_path to 'public'
as $$
  with v as (select * from public.venues x where x.id = venue and x.approved),
       days as (
         select s.game_date, count(*)::int as teams, coalesce(sum(s.players), 0)::int as players
           from public.scores s join v on v.id = s.venue_id
          where s.game_date is not null
          group by s.game_date),
       picked as (
         select dy.*, g.status, g.finished_at
           from days dy
           left join public.games g on g.venue_id = venue and g.game_date = dy.game_date
          where g.status = 'finished' or dy.game_date = public.venue_today(venue)
          order by dy.game_date desc
          limit greatest(1, least(coalesce(max_games, 30), 200)))
  select case when not exists (select 1 from v) then null else jsonb_build_object(
    'venue', (select jsonb_build_object('id', v.id, 'name', v.name, 'city', v.city, 'state', v.state, 'code', v.code,
                                        'quiz_day', v.quiz_day, 'start_time', v.start_time, 'prize', v.prize) from v),
    'today', public.venue_today(venue),
    'games', coalesce((select jsonb_agg(jsonb_build_object(
                 'date',        p.game_date,
                 'status',      coalesce(p.status, 'none'),
                 'finished_at', p.finished_at,
                 'teams',       p.teams,
                 'players',     p.players,
                 'standings',   (select jsonb_agg(jsonb_build_object('team', s.team_name, 'players', s.players, 'score', s.score)
                                                  order by s.score desc, s.played_at asc)
                                   from public.scores s where s.venue_id = venue and s.game_date = p.game_date))
               order by p.game_date desc) from picked p), '[]'::jsonb)) end;
$$;
