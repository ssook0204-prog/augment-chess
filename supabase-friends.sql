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
