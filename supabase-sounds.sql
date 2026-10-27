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
