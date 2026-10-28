-- 증강 체스 사이트판용 Supabase 설정. Supabase 대시보드 → SQL Editor 에 붙여넣고 Run 하세요.
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  nick text not null check (char_length(nick) between 2 and 12),
  nick_key text not null unique             -- 소문자·공백 정리한 닉네임: 중복 금지
    check (nick_key !~* '(관리자|운영자|운영진|어드민|admin|moderator)'),
  created_at timestamptz not null default now()
);
create table if not exists public.ranks (
  id uuid primary key references public.profiles(id) on delete cascade,
  r int not null default 1000 check (r between 0 and 4000),
  w int not null default 0, l int not null default 0, d int not null default 0,
  n text, t bigint,
  updated_at timestamptz not null default now()
);
alter table public.profiles enable row level security;
alter table public.ranks enable row level security;
drop policy if exists "profiles read" on public.profiles;
drop policy if exists "profiles insert own" on public.profiles;
drop policy if exists "profiles update own" on public.profiles;
drop policy if exists "ranks read" on public.ranks;
drop policy if exists "ranks insert own" on public.ranks;
drop policy if exists "ranks update own" on public.ranks;
create policy "profiles read" on public.profiles for select using (true);
create policy "profiles insert own" on public.profiles for insert with check (auth.uid() = id);
create policy "profiles update own" on public.profiles for update using (auth.uid() = id) with check (auth.uid() = id);
create policy "ranks read" on public.ranks for select using (true);
create policy "ranks insert own" on public.ranks for insert with check (auth.uid() = id);
create policy "ranks update own" on public.ranks for update using (auth.uid() = id) with check (auth.uid() = id);

-- ===== 관리자 기능 (카드·글자 편집 등 설정을 서버에 저장) =====
create table if not exists public.admins (id uuid primary key references auth.users(id) on delete cascade);
create table if not exists public.site_cfg (id text primary key, json text not null, t bigint);
alter table public.admins enable row level security;
alter table public.site_cfg enable row level security;
drop policy if exists "admins read own" on public.admins;
drop policy if exists "cfg read" on public.site_cfg;
drop policy if exists "cfg write admin" on public.site_cfg;
create policy "admins read own" on public.admins for select using (auth.uid() = id);
create policy "cfg read" on public.site_cfg for select using (true);
create policy "cfg write admin" on public.site_cfg for all
  using (exists (select 1 from public.admins a where a.id = auth.uid()))
  with check (exists (select 1 from public.admins a where a.id = auth.uid()));
-- 관리자 등록은 아래처럼 SQL Editor에서만 가능해요. 닉네임을 정한 뒤 실행하세요(닉네임 부분을 내 것으로 바꾸기).
-- insert into public.admins select id from public.profiles where nick = '내닉네임';

-- ===== 선택 사항: 관리자가 접속 중이 아닌 다른 사람의 랭크 점수도 바꾸려면 =====
-- 아래를 직접 실행해야 해요(권한이 바뀌는 부분이라 자동으로 하지 않아요). 안 해도 접속 중인 사람의 점수 조작은 돼요.
-- drop policy if exists "ranks admin write" on public.ranks;
-- create policy "ranks admin write" on public.ranks for all
--   using (exists (select 1 from public.admins a where a.id = auth.uid()))
--   with check (exists (select 1 from public.admins a where a.id = auth.uid()));

-- ===== 골드·상점 (골드와 산 물건을 계정에 저장) — 실행하지 않아도 게임은 되고, 이 기기에만 저장돼요 =====
create table if not exists public.wallet (
  id uuid primary key references public.profiles(id) on delete cascade,
  json text not null, t bigint
);
alter table public.wallet enable row level security;
drop policy if exists "wallet read own" on public.wallet;
drop policy if exists "wallet insert own" on public.wallet;
drop policy if exists "wallet update own" on public.wallet;
create policy "wallet read own" on public.wallet for select using (auth.uid() = id);
create policy "wallet insert own" on public.wallet for insert with check (auth.uid() = id);
create policy "wallet update own" on public.wallet for update using (auth.uid() = id) with check (auth.uid() = id);

-- ===== 골드 조작 방지 강화판 v2 — Supabase 의 SQL Editor 에 통째로 붙여 넣고 Run 하세요 (여러 번 실행해도 안전) =====
-- 먼저 wallet 표가 있어야 해요(supabase.sql 의 골드·상점 부분). 이미 예전 골드 보호를 실행했어도 이걸 다시 실행하면 교체돼요.
--
-- 규칙(서버가 지켜요, 브라우저를 고쳐도 소용없어요):
--  1) 골드는 "토큰 통"으로 늘어나요: 45초마다 +100(= 한 판 승리 값), 통은 최대 5000까지 쌓여요(오래 오프라인으로 한 사람도 괜찮게).
--     저장 요청을 아무리 많이 보내도 통에 든 만큼만 늘어나요. 처음 저장하는 계정은 2000까지 인정해요.
--  2) 물건을 사면 종류별 값(색 테마 300 · 이모지 세트 500 · 테두리 효과 800 · 이름 효과 600 · 움직임 효과 700)만큼 골드가 줄었거나 통에서 쓸 수 있어야 해요.
--     모자라면 새로 늘어난 물건은 취소되고 골드도 허용 한도까지만 인정돼요.
--  3) 물건 이름 모양이 이상하거나 60개를 넘으면 그 항목은 지워요. 장착(eq)은 가진 물건만 인정하고(합성 'A+B'는 둘 다 가져야 해요), 나만의 이름 효과는 정해진 모양만 인정해요.
--  4) 한 번에 저장하는 크기는 20KB까지예요.
--  5) 걸러낸 일은 wallet_flags 표에 남겨요(관리자만 볼 수 있어요). Table Editor 에서 wallet_flags 를 열어 보세요.
--  6) 로그인 없이 Supabase 대시보드에서 직접 고치거나 관리자 계정이 저장하는 건 검사하지 않아요(직접 골드를 줄 수 있게).

alter table public.wallet add column if not exists updated_at timestamptz not null default now();
alter table public.wallet add column if not exists tok numeric not null default 500;

create table if not exists public.wallet_flags (
  id bigint generated always as identity primary key,
  uid uuid not null,
  detail text,
  at timestamptz not null default now()
);
alter table public.wallet_flags enable row level security;
drop policy if exists "wflags admin read" on public.wallet_flags;
drop policy if exists "wflags admin delete" on public.wallet_flags;
create policy "wflags admin read" on public.wallet_flags for select
  using (exists (select 1 from public.admins a where a.id = auth.uid()));
create policy "wflags admin delete" on public.wallet_flags for delete
  using (exists (select 1 from public.admins a where a.id = auth.uid()));

create or replace function public.wallet_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  jn jsonb; ex record; k text; v jsonb;
  ng int; og int := 0; allow int; tk numeric; secs numeric; cost int := 0; net int;
  newown jsonb := '{}'::jsonb; oown jsonb := '{}'::jsonb; neweq jsonb := '{}'::jsonb; n int := 0;
  flagged text := null; first boolean := false;
  nmre text := '^c:[0-9a-f]{6}:[0-9a-f]{6}:[0-2]:[0-2](:[0-5]:[0-2]:[01]:[01]:[0-3]:[0-9a-f]{6}:[0-3]:[0-9a-f]{6}:[0-2])?$';
begin
  if length(coalesce(new.json, '')) > 20000 then raise exception 'wallet too large'; end if;
  begin jn := new.json::jsonb; exception when others then raise exception 'bad wallet json'; end;
  if jsonb_typeof(jn) <> 'object' then raise exception 'bad wallet json'; end if;
  -- 대시보드·서버(로그인 없음)나 관리자의 저장은 검사하지 않아요
  if auth.uid() is null or exists (select 1 from public.admins a where a.id = auth.uid()) then
    return new;
  end if;
  begin ng := greatest(0, floor(coalesce((jn->>'g')::numeric, 0)))::int;
  exception when others then raise exception 'bad wallet gold'; end;
  if ng > 100000000 then ng := 100000000; end if;
  -- 가진 물건: 이름 모양이 맞는 것만, 60개까지
  if jsonb_typeof(jn->'own') = 'object' then
    for k in select jsonb_object_keys(jn->'own') loop
      if k ~ '^(ct|sk|fx|nm|mv):[a-z0-9]{1,16}$' and n < 60 then newown := newown || jsonb_build_object(k, 1); n := n + 1; end if;
    end loop;
  end if;
  -- upsert(INSERT ... ON CONFLICT)도 먼저 이 트리거를 지나므로, 이미 행이 있는지 직접 찾아봐요
  select json, updated_at, tok into ex from public.wallet where id = new.id;
  if not found then
    first := true; allow := 2000; tk := 300;
  else
    begin og := greatest(0, floor(coalesce((ex.json::jsonb->>'g')::numeric, 0)))::int; exception when others then og := 0; end;
    begin
      if jsonb_typeof(ex.json::jsonb->'own') = 'object' then
        for k in select jsonb_object_keys(ex.json::jsonb->'own') loop oown := oown || jsonb_build_object(k, 1); end loop;
      end if;
    exception when others then oown := '{}'::jsonb; end;
    secs := greatest(0, extract(epoch from (now() - coalesce(ex.updated_at, now()))));
    tk := least(5000, ex.tok + 100 * secs / 45.0);
    allow := floor(tk)::int;
  end if;
  -- 새로 생긴 물건의 값
  for k in select jsonb_object_keys(newown) loop
    if not (oown ? k) then
      cost := cost + case split_part(k, ':', 1) when 'ct' then 300 when 'sk' then 500 when 'fx' then 800 when 'nm' then 600 when 'mv' then 700 else 0 end;
    end if;
  end loop;
  net := ng + cost - og;
  if net > allow then
    flagged := format('골드 %s→%s, 새 물건 값 %s, 허용 %s', og, ng, cost, allow);
    if cost > 0 then newown := case when first then '{}'::jsonb else oown end; cost := 0; end if;
    net := ng - og;
    if net > allow then ng := og + allow; net := allow; end if;
  end if;
  if first then tk := 300; else tk := tk - greatest(net, 0); end if;
  -- 장착: 가진 물건만, 나만의 이름 효과는 정해진 모양만
  if jsonb_typeof(jn->'eq') = 'object' then
    for k, v in select * from jsonb_each(jn->'eq') loop
      if k = 'ui' then neweq := neweq || jsonb_build_object(k, v);
      elsif jsonb_typeof(v) = 'string' and length(v #>> '{}') <= 80 then
        if k = 'nm' and (v #>> '{}') ~ nmre then neweq := neweq || jsonb_build_object(k, v);
        elsif k = 'nm' and newown ? ('nm:' || (v #>> '{}')) then neweq := neweq || jsonb_build_object(k, v);
        -- 합성: 'a' 또는 'a+b'(서로 다른 두 개, 둘 다 가진 물건)
        elsif k in ('ct','sk','fx','mv') and (v #>> '{}') ~ '^[a-z0-9]{1,16}(\+[a-z0-9]{1,16})?$'
              and newown ? (k || ':' || split_part(v #>> '{}', '+', 1))
              and (split_part(v #>> '{}', '+', 2) = '' or (split_part(v #>> '{}', '+', 2) <> split_part(v #>> '{}', '+', 1) and newown ? (k || ':' || split_part(v #>> '{}', '+', 2)))) then
          neweq := neweq || jsonb_build_object(k, v);
        end if;
      end if;
    end loop;
  end if;
  if flagged is not null and not exists (select 1 from public.wallet_flags f where f.uid = new.id and f.at > now() - interval '60 seconds') then
    insert into public.wallet_flags(uid, detail) values (new.id, flagged);
  end if;
  new.json := jsonb_set(jsonb_set(jsonb_set(jn, '{g}', to_jsonb(ng)), '{own}', newown), '{eq}', neweq)::text;
  new.tok := tk;
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists wallet_guard on public.wallet;
create trigger wallet_guard before insert or update on public.wallet
  for each row execute function public.wallet_guard();
notify pgrst, 'reload schema';

-- ===== 내 이미지 (기물 그림·프로필 사진) — 실행하지 않아도 게임은 되고, 이 기능만 안 써져요 =====
-- 상태: auto = 브라우저 자동검사 통과(바로 공개) / pending = 관리자 승인 대기(나만 보임) / ok = 관리자 승인 / ban = 관리자가 숨김·차단
create table if not exists public.user_imgs (
  uid uuid not null references public.profiles(id) on delete cascade,
  kind text not null check (kind ~ '^(pieces|avatar|pc:[0-9a-f]{1,6})$'),
  img text not null check (length(img) <= 90000),
  st text not null default 'pending' check (st in ('pending','auto','ok','ban')),
  why text,
  updated_at timestamptz not null default now(),
  primary key (uid, kind)
);
alter table public.user_imgs enable row level security;
drop policy if exists "uimg read" on public.user_imgs;
drop policy if exists "uimg insert own" on public.user_imgs;
drop policy if exists "uimg update own" on public.user_imgs;
drop policy if exists "uimg delete own" on public.user_imgs;
drop policy if exists "uimg admin" on public.user_imgs;
create policy "uimg read" on public.user_imgs for select
  using (st in ('ok','auto') or auth.uid() = uid or exists (select 1 from public.admins a where a.id = auth.uid()));
create policy "uimg insert own" on public.user_imgs for insert
  with check (auth.uid() = uid and st in ('pending','auto'));
create policy "uimg update own" on public.user_imgs for update
  using (auth.uid() = uid and st <> 'ban') with check (auth.uid() = uid and st in ('pending','auto'));
create policy "uimg delete own" on public.user_imgs for delete
  using (auth.uid() = uid and st <> 'ban');
create policy "uimg admin" on public.user_imgs for all
  using (exists (select 1 from public.admins a where a.id = auth.uid()))
  with check (exists (select 1 from public.admins a where a.id = auth.uid()));

-- ===== 증강 기물 그림 추가분 (위 내 이미지를 이미 실행한 경우 이것만 실행) =====
alter table public.user_imgs drop constraint if exists user_imgs_kind_check;
alter table public.user_imgs add constraint user_imgs_kind_check check (kind ~ '^(pieces|avatar|pc:[0-9a-f]{1,6})$');
create or replace function public.user_imgs_cap() returns trigger language plpgsql as $$
begin
  if tg_op = 'INSERT' and (select count(*) from public.user_imgs where uid = new.uid) >= 42 then
    raise exception 'too many images';
  end if;
  return new;
end $$;
drop trigger if exists user_imgs_cap on public.user_imgs;
create trigger user_imgs_cap before insert on public.user_imgs for each row execute function public.user_imgs_cap();

-- 새 테이블을 만든 뒤 404가 계속 나면 아래 한 줄을 실행해서 API가 새 테이블을 알게 하세요.
notify pgrst, 'reload schema';

-- ===== 친구 시스템 — Supabase 의 SQL Editor 에 통째로 붙여 넣고 Run 하세요 (여러 번 실행해도 안전) =====
-- 먼저 profiles 표가 있어야 해요(supabase.sql 맨 위). 실행하지 않아도 게임은 되고, 친구 기능만 안 써져요.
-- 규칙: a 가 b 에게 요청(pending) → b 가 수락하면 ok. 둘 중 누구든 삭제할 수 있어요. 한 사람당 친구·요청은 100개까지예요.
create table if not exists public.friends (
  a uuid not null references public.profiles(id) on delete cascade,
  b uuid not null references public.profiles(id) on delete cascade,
  st text not null default 'pending' check (st in ('pending','ok')),
  created_at timestamptz not null default now(),
  primary key (a, b),
  check (a <> b)
);
create unique index if not exists friends_pair on public.friends (least(a, b), greatest(a, b));
alter table public.friends enable row level security;
drop policy if exists "friends read" on public.friends;
drop policy if exists "friends request" on public.friends;
drop policy if exists "friends accept" on public.friends;
drop policy if exists "friends delete" on public.friends;
create policy "friends read" on public.friends for select using (auth.uid() = a or auth.uid() = b);
create policy "friends request" on public.friends for insert with check (auth.uid() = a and st = 'pending');
create policy "friends accept" on public.friends for update using (auth.uid() = b) with check (auth.uid() = b and st = 'ok');
create policy "friends delete" on public.friends for delete using (auth.uid() = a or auth.uid() = b);
create or replace function public.friends_cap() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if (select count(*) from public.friends where a = new.a or b = new.a) >= 100 then raise exception 'friend limit'; end if;
  if (select count(*) from public.friends where a = new.b or b = new.b) >= 100 then raise exception 'friend limit (other)'; end if;
  return new;
end $$;
drop trigger if exists friends_cap on public.friends;
create trigger friends_cap before insert on public.friends for each row execute function public.friends_cap();
notify pgrst, 'reload schema';

-- ===== 부관리자 (v0.168) =====
-- 관리자가 게임 안에서 다른 사람을 부관리자로 임명하고, 권한을 골라 줘요.
--   imgs  = 이미지 검토(승인·차단·삭제)     event = 공지·이벤트 올리기·지우기     ban = 랭크전 차단·해제
-- 부관리자는 위 권한 밖의 설정(카드·기물·AI 설정·점수 등)을 서버에서 바꿀 수 없어요.
create table if not exists public.sub_admins (
  id uuid primary key references auth.users(id) on delete cascade,
  nick text,
  perms text[] not null default '{}',
  added_at timestamptz not null default now()
);
alter table public.sub_admins enable row level security;
drop policy if exists "sub read" on public.sub_admins;
drop policy if exists "sub admin write" on public.sub_admins;
create policy "sub read" on public.sub_admins for select
  using (auth.uid() = id or exists (select 1 from public.admins a where a.id = auth.uid()));
create policy "sub admin write" on public.sub_admins for all
  using (exists (select 1 from public.admins a where a.id = auth.uid()))
  with check (exists (select 1 from public.admins a where a.id = auth.uid()));

create or replace function public.has_perm(p text) returns boolean
  language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admins a where a.id = auth.uid())
      or exists (select 1 from public.sub_admins s where s.id = auth.uid() and p = any(s.perms));
$$;

-- 이미지 검토
drop policy if exists "uimg sub" on public.user_imgs;
create policy "uimg sub" on public.user_imgs for all
  using (public.has_perm('imgs')) with check (public.has_perm('imgs'));

-- 서버 설정: 부관리자는 자기 권한에 해당하는 항목(공지·이벤트=notice/events, 랭크전 차단=ban)만 바꿀 수 있어요.
drop policy if exists "cfg write sub" on public.site_cfg;
create policy "cfg write sub" on public.site_cfg for all
  using (public.has_perm('event') or public.has_perm('ban'))
  with check (public.has_perm('event') or public.has_perm('ban'));

create or replace function public.site_cfg_guard() returns trigger
  language plpgsql security definer set search_path = public as $$
declare o jsonb; n jsonb; k text; al text[] := '{}'; p text[];
begin
  if auth.uid() is null or exists (select 1 from public.admins a where a.id = auth.uid()) then
    if tg_op = 'DELETE' then return old; end if; return new;
  end if;
  select perms into p from public.sub_admins where id = auth.uid();
  if p is null then raise exception 'not_permitted'; end if;
  if tg_op = 'DELETE' or new.id <> 'main' then raise exception 'not_permitted'; end if;
  if 'event' = any(p) then al := al || array['notice','events']; end if;
  if 'ban' = any(p) then al := al || array['ban']; end if;
  begin
    n := new.json::jsonb;
    if tg_op = 'UPDATE' then o := old.json::jsonb;
    else
      -- upsert(INSERT ... ON CONFLICT)도 먼저 이 트리거를 지나므로, 이미 있는 행과 비교해요
      select json::jsonb into o from public.site_cfg where id = new.id;
      o := coalesce(o, '{}'::jsonb);
    end if;
  exception when others then raise exception 'bad_json'; end;
  if jsonb_typeof(n) <> 'object' or jsonb_typeof(o) <> 'object' then raise exception 'bad_json'; end if;
  for k in select jsonb_object_keys(o || n) loop
    if (o -> k) is distinct from (n -> k) and not (k = any(al)) then
      raise exception 'not_permitted: %', k;
    end if;
  end loop;
  return new;
end $$;
drop trigger if exists site_cfg_guard on public.site_cfg;
create trigger site_cfg_guard before insert or update or delete on public.site_cfg
  for each row execute function public.site_cfg_guard();

-- ===== 소리 연동 (v0.170) — 로그인한 계정의 소리 설정과 내 소리 파일을 기기끼리 맞춰요 =====
-- slot: cfg = 소리 설정(켜기·볼륨·효과음별 켜기), mv/cap/click/win/lose/card = 내 소리 파일(빈 data = 지움)
create table if not exists public.user_sounds (
  uid uuid not null references auth.users(id) on delete cascade,
  slot text not null check (slot in ('cfg','mv','cap','click','win','lose','card')),
  data text not null default '' check (length(data) <= 2900000),
  name text check (name is null or length(name) <= 60),
  t bigint not null default 0,
  updated_at timestamptz not null default now(),
  primary key (uid, slot)
);
alter table public.user_sounds enable row level security;
drop policy if exists "snd own" on public.user_sounds;
create policy "snd own" on public.user_sounds for all
  using (auth.uid() = uid) with check (auth.uid() = uid);
notify pgrst, 'reload schema';

-- ===== 보안 강화 (v0.172): supabase-security.sql 과 같은 내용 =====
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
  new.n := left(regexp_replace(coalesce(new.n, ''), '[<>&"''`\\[:cntrl:]\u200b-\u200f\u2028-\u202e\u2060-\u2064\ufeff]', '', 'g'), 24);
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
