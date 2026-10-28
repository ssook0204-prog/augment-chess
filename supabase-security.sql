-- ===== 보안 강화 (v0.172) — Supabase 의 SQL Editor 에 통째로 붙여 넣고 Run 하세요 (여러 번 실행해도 안전) =====
-- 먼저 supabase.sql(프로필·랭크·관리자·부관리자)이 실행돼 있어야 해요.
-- 1) 랭크 점수 조작 막기: 한 판에 바뀔 수 있는 점수(이벤트 배수 반영)·판 수·판 사이 시간을 서버가 확인해요.
--    관리자 남용 보상은 하루 500점까지. 관리자(그리고 '랭크 차단' 권한 부관리자)는 남의 점수도 직접 고칠 수 있어요.
-- 2) 닉네임: 꺾쇠·따옴표 같은 위험한 글자, 보이지 않는 글자, 숨긴 '관리자' 사칭(공백·점 넣기 등)을 막아요.
-- 3) 이미지·지갑: 스크립트가 섞인 이미지 데이터와 비정상적으로 큰 지갑 데이터를 막아요.
-- 이미 저장된 예전 데이터는 그대로 둬요(새로 저장할 때부터 검사해요).

-- ---------- 1) 랭크 ----------
alter table public.ranks add column if not exists games_at timestamptz;
alter table public.ranks add column if not exists bonus_d date;
alter table public.ranks add column if not exists bonus_s int not null default 0;

-- 지금 켜져 있는 랭크 이벤트 배수(게임과 같은 규칙: 곱하고 최대 10배)
create or replace function public.rank_mult() returns numeric
  language plpgsql stable security definer set search_path = public as $$
declare j jsonb; e jsonb; m numeric := 1; nowms numeric := extract(epoch from now()) * 1000;
begin
  select json::jsonb into j from public.site_cfg where id = 'main';
  if j is null or jsonb_typeof(j->'events') <> 'array' then return 1; end if;
  for e in select * from jsonb_array_elements(j->'events') loop
    if jsonb_typeof(e) = 'object' and e->>'type' = 'rank'
       and (e->>'from' is null or (e->>'from')::numeric <= nowms)
       and (e->>'to' is null or nowms < (e->>'to')::numeric) then
      m := m * greatest(1, least(10, coalesce((e->>'mult')::numeric, 1)));
    end if;
  end loop;
  return least(m, 10);
exception when others then
  return 10;  -- 설정을 읽지 못하면 정상 게임을 막지 않도록 최대 배수로 봐요
end $$;

create or replace function public.ranks_guard() returns trigger
  language plpgsql security definer set search_path = public as $$
declare g0 int; g1 int; dr int; lim int; today date := (now() at time zone 'Asia/Seoul')::date; bs int;
begin
  -- 이름표: 위험한 글자 빼고 24글자까지
  new.n := left(regexp_replace(coalesce(new.n, ''), '[<>&"''`\\[:cntrl:]\u200b-\u200f\u2028-\u202e\u2060-\u2064\ufeff]', '', 'g'), 24);
  new.w := greatest(coalesce(new.w, 0), 0); new.l := greatest(coalesce(new.l, 0), 0); new.d := greatest(coalesce(new.d, 0), 0);
  new.updated_at := now();
  -- SQL Editor(서버)·관리자·'랭크 차단' 권한 부관리자는 그대로 허용
  if auth.uid() is null or public.has_perm('ban') then return new; end if;
  if new.id is distinct from auth.uid() then raise exception 'rank_not_permitted'; end if;

  if tg_op = 'INSERT' then
    -- 처음 만들 때: 게스트 시절 기록을 가져와도 1200점·50판까지만
    new.r := least(greatest(new.r, 0), 1200);
    new.w := least(new.w, 50); new.l := least(new.l, 50); new.d := least(new.d, 50);
    new.games_at := now(); new.bonus_d := null; new.bonus_s := 0;
    return new;
  end if;

  -- 서버만 쓰는 칸은 못 바꿔요
  new.games_at := old.games_at; new.bonus_d := old.bonus_d; new.bonus_s := old.bonus_s;
  if new.w < old.w or new.l < old.l or new.d < old.d then raise exception 'rank_rejected: 판 수는 줄어들 수 없어요'; end if;
  g0 := old.w + old.l + old.d; g1 := new.w + new.l + new.d; dr := new.r - old.r;

  if g1 > g0 + 1 then raise exception 'rank_rejected: 한 번에 한 판만 기록돼요'; end if;

  if g1 = g0 + 1 then
    -- 한 판 끝: 이긴 판은 점수가 내려가지 않고, 진 판은 올라가지 않아요
    if old.games_at is not null and old.games_at > now() - interval '10 seconds' then
      raise exception 'rank_rejected: 판이 너무 빨리 기록됐어요';
    end if;
    lim := ceil(32 * public.rank_mult()) + 1;
    if abs(dr) > lim then raise exception 'rank_rejected: 한 판에 바뀔 수 있는 점수를 넘었어요'; end if;
    if new.w > old.w and dr < 0 then raise exception 'rank_rejected'; end if;
    if new.l > old.l and dr > 0 then raise exception 'rank_rejected'; end if;
    new.games_at := now();
    return new;
  end if;

  -- 판 수 그대로: 점수가 내려가는 건 허용, 올라가는 건 관리자 남용 보상(하루 500점)만
  if dr > 0 then
    bs := case when old.bonus_d = today then old.bonus_s else 0 end;
    if bs + dr > 500 then raise exception 'rank_rejected: 보상 한도를 넘었어요'; end if;
    new.bonus_d := today; new.bonus_s := bs + dr;
  end if;
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
