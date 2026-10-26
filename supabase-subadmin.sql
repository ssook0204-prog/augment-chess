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
    o := case when tg_op = 'UPDATE' then old.json::jsonb else '{}'::jsonb end;
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
