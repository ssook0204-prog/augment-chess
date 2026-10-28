-- ===== 보안 강화 (v0.172) — Supabase 의 SQL Editor 에 통째로 붙여 넣고 Run 하세요 (여러 번 실행해도 안전) =====
-- 먼저 supabase.sql(프로필·랭크·관리자·부관리자)이 실행돼 있어야 해요.
-- 1) 랭크 점수는 서버만 바꿔요(양쪽 확인 방식):
--    대국 시작 때 두 사람이 모두 "이 상대와 대국"을 등록하고, 끝나면 각자 결과를 보고해요.
--    결과가 같으면 서버가 두 사람의 실제 점수로 계산해서 바꿔요. 다르면 바꾸지 않고 관리자 검토로 남겨요.
--    한쪽만 보고하고 3분 동안 다른 쪽이 보고하지 않으면(나가 버림) 보고한 결과로 처리해요.
--    같은 상대와는 하루 3판까지만 점수에 반영돼요. 계정끼리만 서버 랭크가 돼요(게스트 제외).
--    관리자(그리고 '랭크 차단' 권한 부관리자)는 점수를 직접 고치거나 남용 보상을 줄 수 있어요.
-- 2) 닉네임: 꺾쇠·따옴표 같은 위험한 글자, 보이지 않는 글자, 숨긴 '관리자' 사칭(공백·점 넣기 등)을 막아요.
-- 3) 이미지·지갑: 스크립트가 섞인 이미지 데이터와 비정상적으로 큰 지갑 데이터를 막아요.
-- 이미 저장된 예전 데이터는 그대로 둬요(새로 저장할 때부터 검사해요).

-- ---------- 1) 랭크 ----------
alter table public.ranks add column if not exists games_at timestamptz;

-- 지금 켜져 있는 랭크 이벤트 배수(게임과 같은 규칙: 곱하고 최대 10배, '오를 때만' 이벤트는 오를 때만)
drop function if exists public.rank_mult();
create or replace function public.rank_mult(pos boolean default true) returns numeric
  language plpgsql stable security definer set search_path = public as $$
declare j jsonb; e jsonb; m numeric := 1; nowms numeric := extract(epoch from now()) * 1000;
begin
  select json::jsonb into j from public.site_cfg where id = 'main';
  if j is null or jsonb_typeof(j->'events') <> 'array' then return 1; end if;
  for e in select * from jsonb_array_elements(j->'events') loop
    if jsonb_typeof(e) = 'object' and e->>'type' = 'rank'
       and (e->>'from' is null or (e->>'from')::numeric <= nowms)
       and (e->>'to' is null or nowms < (e->>'to')::numeric)
       and (pos or coalesce(e->>'up', 'false') not in ('true', '1')) then
      m := m * greatest(1, least(10, coalesce((e->>'mult')::numeric, 1)));
    end if;
  end loop;
  return least(m, 10);
exception when others then
  return 1;
end $$;

create or replace function public.ranks_guard() returns trigger
  language plpgsql security definer set search_path = public as $$
begin
  -- 이름표: 위험한 글자 빼고 24글자까지
  new.n := left(regexp_replace(coalesce(new.n, ''), '[<>&"''`\\[:cntrl:]​-‏ -‮⁠-⁤﻿]', '', 'g'), 24);
  new.updated_at := now();
  -- SQL Editor·서버 계산(rank_report)·관리자·'랭크 차단' 권한 부관리자는 그대로 허용
  if auth.uid() is null or current_setting('ac.rank_srv', true) = '1' or public.has_perm('ban') then return new; end if;
  if new.id is distinct from auth.uid() then raise exception 'rank_not_permitted'; end if;
  if tg_op = 'INSERT' then
    new.r := 1000; new.w := 0; new.l := 0; new.d := 0; new.games_at := null;
    return new;
  end if;
  -- 점수·판 수는 서버만 바꿔요(이름표·시간만 바꿀 수 있어요)
  if new.r is distinct from old.r or new.w is distinct from old.w or new.l is distinct from old.l or new.d is distinct from old.d then
    raise exception 'rank_server_only';
  end if;
  new.games_at := old.games_at;
  return new;
end $$;
drop trigger if exists ranks_guard on public.ranks;
create trigger ranks_guard before insert or update on public.ranks
  for each row execute function public.ranks_guard();

-- 관리자·'랭크 차단' 권한 부관리자는 접속 중이 아닌 사람의 점수도 직접 고칠 수 있어요
drop policy if exists "ranks admin write" on public.ranks;
drop policy if exists "ranks admin insert" on public.ranks;
create policy "ranks admin write" on public.ranks for update
  using (public.has_perm('ban')) with check (public.has_perm('ban'));
create policy "ranks admin insert" on public.ranks for insert
  with check (public.has_perm('ban'));

-- 랭크 대국 기록(양쪽 확인)
create table if not exists public.rank_matches (
  gid text primary key check (char_length(gid) between 6 and 40),
  w uuid not null references public.profiles(id) on delete cascade,
  b uuid not null references public.profiles(id) on delete cascade,
  w_ok boolean not null default false, b_ok boolean not null default false,
  res_w text check (res_w in ('w','b','d')), res_b text check (res_b in ('w','b','d')),
  first_at timestamptz,
  st text not null default 'open' check (st in ('open','done','flag')),
  result text, dw int, db int, note text,
  created_at timestamptz not null default now(), done_at timestamptz,
  check (w <> b)
);
create index if not exists rank_matches_w on public.rank_matches (w, created_at);
create index if not exists rank_matches_b on public.rank_matches (b, created_at);
alter table public.rank_matches enable row level security;
drop policy if exists "rm read" on public.rank_matches;
create policy "rm read" on public.rank_matches for select
  using (auth.uid() = w or auth.uid() = b or public.has_perm('ban'));
-- 쓰기는 아래 함수로만 (표에 직접 쓰는 정책은 없어요)

create or replace function public.rank_start(p_gid text, p_me text, p_opp uuid) returns text
  language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); m public.rank_matches;
begin
  if u is null then raise exception 'no_session'; end if;
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

-- 결과로 두 사람 점수를 계산해 바꿔요(내부용)
create or replace function public.rank_finalize(p_gid text, p_res text) returns void
  language plpgsql security definer set search_path = public as $$
declare m public.rank_matches; rw int; rb int; sw numeric; ew numeric; v_dw int := 0; v_db int := 0;
        today date := (now() at time zone 'Asia/Seoul')::date; n int; nt text := null;
begin
  if coalesce(current_setting('ac.rank_fin', true), '') <> '1' then raise exception 'not_permitted'; end if;
  select * into m from public.rank_matches where gid = p_gid for update;
  if m.st <> 'open' then return; end if;
  select count(*) into n from public.rank_matches
    where st = 'done' and least(w, b) = least(m.w, m.b) and greatest(w, b) = greatest(m.w, m.b)
      and (done_at at time zone 'Asia/Seoul')::date = today and coalesce(note, '') <> 'daily_limit';
  if n >= 3 then
    nt := 'daily_limit';
  else
    select r into rw from public.ranks where id = m.w for update;
    select r into rb from public.ranks where id = m.b for update;
    rw := coalesce(rw, 1000); rb := coalesce(rb, 1000);
    sw := case p_res when 'w' then 1 when 'd' then 0.5 else 0 end;
    ew := 1 / (1 + power(10, (rb - rw) / 400.0));
    v_dw := round(32 * (sw - ew) * public.rank_mult(sw - ew > 0));
    v_db := round(32 * ((1 - sw) - (1 - ew)) * public.rank_mult((1 - sw) - (1 - ew) > 0));
    perform set_config('ac.rank_srv', '1', true);
    update public.ranks set r = greatest(0, least(4000, r + v_dw)),
      w = w + (case when p_res = 'w' then 1 else 0 end), l = l + (case when p_res = 'b' then 1 else 0 end),
      d = d + (case when p_res = 'd' then 1 else 0 end), games_at = now(), t = (extract(epoch from now()) * 1000)::bigint
      where id = m.w;
    update public.ranks set r = greatest(0, least(4000, r + v_db)),
      w = w + (case when p_res = 'b' then 1 else 0 end), l = l + (case when p_res = 'w' then 1 else 0 end),
      d = d + (case when p_res = 'd' then 1 else 0 end), games_at = now(), t = (extract(epoch from now()) * 1000)::bigint
      where id = m.b;
    perform set_config('ac.rank_srv', '', true);
  end if;
  update public.rank_matches set st = 'done', result = p_res, dw = v_dw, db = v_db, note = nt, done_at = now() where gid = p_gid;
end $$;
revoke all on function public.rank_finalize(text, text) from public, anon, authenticated;

-- 내 쪽 결과를 알려줘요. 돌려주는 값: {st:'wait'|'done'|'flag', d:내 점수 변화, r:내 점수, note}
create or replace function public.rank_my(p_gid text) returns jsonb
  language sql stable security definer set search_path = public as $$
  select jsonb_build_object('st', m.st, 'note', m.note, 'result', m.result,
    'd', case when m.w = auth.uid() then m.dw else m.db end,
    'r', (select r from public.ranks where id = auth.uid()))
  from public.rank_matches m where m.gid = p_gid and (m.w = auth.uid() or m.b = auth.uid());
$$;

create or replace function public.rank_report(p_gid text, p_res text, p_n text default null) returns jsonb
  language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); m public.rank_matches; side text;
begin
  if u is null then raise exception 'no_session'; end if;
  if p_res not in ('w','b','d') then raise exception 'bad_result'; end if;
  select * into m from public.rank_matches where gid = p_gid for update;
  if not found or (m.w <> u and m.b <> u) then raise exception 'no_match'; end if;
  if not (m.w_ok and m.b_ok) then raise exception 'not_started'; end if;
  side := case when m.w = u then 'w' else 'b' end;
  if p_n is not null then
    update public.ranks set n = p_n where id = u;  -- 이름표만(점수는 그대로)
  end if;
  if m.st = 'open' then
    if side = 'w' and m.res_w is null then update public.rank_matches set res_w = p_res, first_at = coalesce(first_at, now()) where gid = p_gid; end if;
    if side = 'b' and m.res_b is null then update public.rank_matches set res_b = p_res, first_at = coalesce(first_at, now()) where gid = p_gid; end if;
    select * into m from public.rank_matches where gid = p_gid;
    if m.res_w is not null and m.res_b is not null then
      if m.res_w = m.res_b then perform set_config('ac.rank_fin', '1', true); perform public.rank_finalize(p_gid, m.res_w); perform set_config('ac.rank_fin', '', true);
      else update public.rank_matches set st = 'flag', note = 'mismatch', done_at = now() where gid = p_gid; end if;
    end if;
  end if;
  return public.rank_my(p_gid);
end $$;

-- 한쪽만 보고하고 3분이 지나면 보고한 결과로 처리해요
create or replace function public.rank_settle(p_gid text) returns jsonb
  language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); m public.rank_matches;
begin
  select * into m from public.rank_matches where gid = p_gid for update;
  if not found or (m.w <> u and m.b <> u) then raise exception 'no_match'; end if;
  if m.st = 'open' and m.first_at is not null and m.first_at < now() - interval '3 minutes'
     and (m.res_w is null) <> (m.res_b is null) then
    perform set_config('ac.rank_fin', '1', true); perform public.rank_finalize(p_gid, coalesce(m.res_w, m.res_b)); perform set_config('ac.rank_fin', '', true);
  end if;
  return public.rank_my(p_gid);
end $$;

-- 관리자 남용 보상(관리자·'랭크 차단' 권한 부관리자만, 한 번에 1~500점)
create or replace function public.rank_bonus(p_uid uuid, p_amt int) returns int
  language plpgsql security definer set search_path = public as $$
declare nr int;
begin
  if not public.has_perm('ban') then raise exception 'not_permitted'; end if;
  if p_amt < 1 or p_amt > 500 then raise exception 'bad_amount'; end if;
  perform set_config('ac.rank_srv', '1', true);
  insert into public.ranks(id) values (p_uid) on conflict (id) do nothing;
  update public.ranks set r = least(4000, r + p_amt) where id = p_uid returning r into nr;
  perform set_config('ac.rank_srv', '', true);
  return nr;
end $$;

-- ---------- 2) 닉네임 ----------
alter table public.profiles drop constraint if exists profiles_nick_safe;
alter table public.profiles add constraint profiles_nick_safe check (
  nick !~ '[<>&"''`\\]'
  and nick !~ '[[:cntrl:]\u200b-\u200f\u2028-\u202e\u2060-\u2064\ufeff]'
  and nick = btrim(nick)
) not valid;
alter table public.profiles drop constraint if exists profiles_nick_reserved;
alter table public.profiles add constraint profiles_nick_reserved check (
  regexp_replace(lower(normalize(nick, NFKC)), '[[:space:]\u200b-\u200f\u2060\ufeff._·•|~*+-]', '', 'g')
    !~ '(관리자|운영자|운영진|어드민|admin|moderator)'
) not valid;

-- ---------- 3) 이미지·지갑·소리 ----------
alter table public.user_imgs drop constraint if exists user_imgs_safe;
alter table public.user_imgs add constraint user_imgs_safe check (
  img !~ '[<>`]' and img !~* '(java|vb)script:' and img !~* 'data:text/'
) not valid;
alter table public.wallet drop constraint if exists wallet_size;
alter table public.wallet add constraint wallet_size check (length(json) <= 60000) not valid;
alter table public.user_sounds drop constraint if exists user_sounds_safe;
alter table public.user_sounds add constraint user_sounds_safe check (data !~ '[<>`]') not valid;

-- ---------- 4) 점검: 행 보안(RLS)이 꺼진 public 표가 있으면 아래에 나와요 (없으면 0 rows) ----------
notify pgrst, 'reload schema';
select tablename as "RLS 꺼진 표" from pg_tables where schemaname = 'public' and not rowsecurity;
