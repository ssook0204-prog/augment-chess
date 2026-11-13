-- ===== 보안 강화 3 (v0.176) — 봇·해킹 감지와 방어. Supabase 의 SQL Editor 에 통째로 붙여 넣고 Run 하세요 (여러 번 실행해도 안전) =====
-- 먼저 supabase.sql, supabase-security.sql, supabase-security2.sql 이 실행돼 있어야 해요.
-- 1) sec_events: 브라우저가 감지한 봇·해킹 신호를 모아요. 자기 기록만 쓸 수 있고(시간당 30개까지), 관리자와 '랭크 차단' 권한 부관리자만 읽어요.
-- 2) rank_flag: 랭크전에서 상대가 규칙에 맞지 않는 수를 보냈다고 감지되면 그 판을 무효로 해요(누구도 점수를 못 얻어요).
-- 3) 랭크전 차단(관리자 화면의 '차단')을 서버에서도 막아요: 차단된 계정은 랭크전 시작·결과 보고가 거부돼요.

-- ---------- 1) 감지 기록 ----------
create table if not exists public.sec_events (
  id bigserial primary key,
  uid uuid references auth.users(id) on delete cascade,
  nick text,
  kind text not null check (kind ~ '^[a-z_]{2,24}$'),
  score int check (score between 0 and 100),
  detail text check (char_length(detail) <= 300),
  gid text check (char_length(gid) <= 40),
  created_at timestamptz not null default now()
);
create index if not exists sec_events_t on public.sec_events (created_at desc);
create index if not exists sec_events_u on public.sec_events (uid, created_at);
alter table public.sec_events enable row level security;
drop policy if exists "sec ins own" on public.sec_events;
create policy "sec ins own" on public.sec_events for insert with check (auth.uid() is not null and uid = auth.uid());
drop policy if exists "sec read staff" on public.sec_events;
create policy "sec read staff" on public.sec_events for select using (public.has_perm('ban'));
drop policy if exists "sec del staff" on public.sec_events;
create policy "sec del staff" on public.sec_events for delete using (public.has_perm('ban'));

-- 누가 썼는지·닉네임은 서버가 채우고, 한 사람이 시간당 30개 넘게 쓰면 조용히 버려요
create or replace function public.sec_events_fill() returns trigger
  language plpgsql security definer set search_path = public as $$
begin
  if current_setting('ac.sec_srv', true) = '1' then return new; end if;
  new.uid := auth.uid();
  if new.uid is null then raise exception 'no_session'; end if;
  if (select count(*) from public.sec_events where uid = new.uid and created_at > now() - interval '1 hour') >= 30 then
    return null;
  end if;
  new.nick := (select nick from public.profiles where id = new.uid);
  new.created_at := now();
  return new;
end $$;
drop trigger if exists sec_events_fill on public.sec_events;
create trigger sec_events_fill before insert on public.sec_events
  for each row execute function public.sec_events_fill();

-- ---------- 3) 서버에서도 랭크전 차단 ----------
create or replace function public.rank_banned(p_uid uuid) returns boolean
  language sql stable security definer set search_path = public as $$
  select coalesce((select (json::jsonb -> 'ban') ? p_uid::text from public.site_cfg where id = 'main'), false)
    and not exists (select 1 from public.admins where id = p_uid);
$$;

create or replace function public.rank_start(p_gid text, p_me text, p_opp uuid) returns text
  language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); m public.rank_matches;
begin
  if u is null then raise exception 'no_session'; end if;
  if public.rank_banned(u) then raise exception 'banned'; end if;
  if p_me not in ('w','b') or p_opp is null or p_opp = u then raise exception 'bad_match'; end if;
  if not exists (select 1 from public.profiles where id = p_opp) then raise exception 'bad_match'; end if;
  if (select count(*) from public.rank_matches where (w = u or b = u) and created_at > now() - interval '1 hour') >= 40 then
    raise exception 'too_many_matches';
  end if;
  perform set_config('ac.rank_srv', '1', true);
  insert into public.ranks(id) values (u), (p_opp) on conflict (id) do nothing;
  perform set_config('ac.rank_srv', '', true);
  insert into public.rank_matches(gid, w, b)
    values (p_gid, case when p_me = 'w' then u else p_opp end, case when p_me = 'w' then p_opp else u end)
    on conflict (gid) do nothing;
  select * into m from public.rank_matches where gid = p_gid for update;
  if m.st <> 'open' or m.created_at < now() - interval '3 hours' then raise exception 'match_closed'; end if;
  if (p_me = 'w' and (m.w <> u or m.b <> p_opp)) or (p_me = 'b' and (m.b <> u or m.w <> p_opp)) then
    raise exception 'match_mismatch';
  end if;
  if p_me = 'w' then update public.rank_matches set w_ok = true where gid = p_gid;
  else update public.rank_matches set b_ok = true where gid = p_gid; end if;
  select * into m from public.rank_matches where gid = p_gid;
  return case when m.w_ok and m.b_ok then 'ok' else 'wait' end;
end $$;

-- 차단된 사람이 결과를 보고하면 거부해요(상대가 보고한 결과로 3분 뒤 정리돼요)
create or replace function public.rank_report_ban() returns trigger
  language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and public.rank_banned(auth.uid())
     and ((new.res_w is distinct from old.res_w and old.w = auth.uid()) or (new.res_b is distinct from old.res_b and old.b = auth.uid())) then
    raise exception 'banned';
  end if;
  return new;
end $$;
drop trigger if exists rank_report_ban on public.rank_matches;
create trigger rank_report_ban before update on public.rank_matches
  for each row execute function public.rank_report_ban();

-- ---------- 2) 부정한 수가 감지된 판은 무효 ----------
create or replace function public.rank_flag(p_gid text, p_why text) returns jsonb
  language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); m public.rank_matches; v_why text := left(regexp_replace(coalesce(p_why, ''), '[^a-z_]', '', 'g'), 24);
begin
  if u is null then raise exception 'no_session'; end if;
  select * into m from public.rank_matches where gid = p_gid for update;
  if not found or (m.w <> u and m.b <> u) then raise exception 'no_match'; end if;
  if m.st = 'open' then
    update public.rank_matches set st = 'flag', note = 'cheat:' || coalesce(nullif(v_why, ''), 'move'), done_at = now() where gid = p_gid;
    perform set_config('ac.sec_srv', '1', true);
    insert into public.sec_events(uid, nick, kind, score, detail, gid)
      values (case when m.w = u then m.b else m.w end,
              (select nick from public.profiles where id = case when m.w = u then m.b else m.w end),
              'opp_cheat', 100, '상대가 감지: ' || coalesce(nullif(v_why, ''), 'move'), p_gid);
    perform set_config('ac.sec_srv', '', true);
  end if;
  return public.rank_my(p_gid);
end $$;

notify pgrst, 'reload schema';
