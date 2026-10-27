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
