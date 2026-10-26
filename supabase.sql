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

-- ===== 골드 조작 방지 (서버가 골드 증가 속도를 제한) — 위 wallet 을 만든 뒤 실행하세요. 실행 안 해도 게임은 돼요 =====
-- 규칙: 마지막 저장 후 20초마다 +100 골드까지만 늘어날 수 있어요(첫 저장은 2000까지).
--       새 물건을 늘리려면 그만큼(최소 300골드)의 골드가 줄었거나 늘어난 몫이 있어야 해요.
alter table public.wallet add column if not exists updated_at timestamptz not null default now();
create or replace function public.wallet_guard() returns trigger language plpgsql as $$
declare jn jsonb; ng int; og int := 0; oc int := 0; nc int; allow int; secs numeric; ex record;
begin
  begin jn := new.json::jsonb; exception when others then raise exception 'bad wallet json'; end;
  ng := greatest(0, floor(coalesce((jn->>'g')::numeric, 0)))::int;
  select count(*) into nc from jsonb_object_keys(coalesce(jn->'own','{}'::jsonb));
  -- upsert(INSERT ... ON CONFLICT)도 먼저 이 트리거를 지나므로, 이미 행이 있는지 직접 찾아봐요
  select json, updated_at into ex from public.wallet where id = new.id;
  if not found then
    allow := 2000;
  else
    og := greatest(0, floor(coalesce((ex.json::jsonb->>'g')::numeric, 0)))::int;
    select count(*) into oc from jsonb_object_keys(coalesce(ex.json::jsonb->'own','{}'::jsonb));
    secs := extract(epoch from (now() - coalesce(ex.updated_at, now() - interval '1 day')));
    allow := 100 * (1 + floor(secs / 20))::int;
  end if;
  if ng > og + allow then ng := og + allow; end if;
  if nc > oc and ng + 300 * (nc - oc) > og + allow then raise exception 'wallet items exceed gold'; end if;
  new.json := jsonb_set(jn, '{g}', to_jsonb(ng))::text;
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists wallet_guard on public.wallet;
create trigger wallet_guard before insert or update on public.wallet
  for each row execute function public.wallet_guard();

-- ===== 내 이미지 (기물 그림·프로필 사진) — 실행하지 않아도 게임은 되고, 이 기능만 안 써져요 =====
-- 상태: auto = 브라우저 자동검사 통과(바로 공개) / pending = 관리자 승인 대기(나만 보임) / ok = 관리자 승인 / ban = 관리자가 숨김·차단
create table if not exists public.user_imgs (
  uid uuid not null references public.profiles(id) on delete cascade,
  kind text not null check (kind in ('pieces','avatar')),
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

-- 새 테이블을 만든 뒤 404가 계속 나면 아래 한 줄을 실행해서 API가 새 테이블을 알게 하세요.
notify pgrst, 'reload schema';
