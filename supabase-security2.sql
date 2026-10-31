-- ===== 보안 강화 2 (v0.175) — Supabase 의 SQL Editor 에 통째로 붙여 넣고 Run 하세요 (여러 번 실행해도 안전) =====
-- 먼저 supabase.sql 과 supabase-security.sql 이 실행돼 있어야 해요.
-- 1) 닉네임 사칭 막기: 중복 검사용 nick_key 를 브라우저가 보낸 값 대신 서버가 닉네임에서 직접 만들어요.
--    (전에는 nick_key 만 다르게 보내면 남과 똑같은 닉네임을 쓸 수 있었어요. 전각 글자 'ＡＢＣ' 같은 변형도 같은 이름으로 봐요.)
-- 2) 이미지: 프로필·증강 기물 그림은 png·jpeg·webp 그림 데이터만, 기물 그림 묶음은 그 그림들만 담은 JSON 만 받아요.
-- 이미 저장된 예전 데이터는 그대로 둬요(새로 저장할 때부터 검사해요).

-- ---------- 1) 닉네임 ----------
create or replace function public.profiles_key() returns trigger
  language plpgsql set search_path = public as $$
begin
  new.nick := btrim(new.nick);
  new.nick_key := lower(btrim(regexp_replace(normalize(new.nick, NFKC), '[[:space:]]+', ' ', 'g')));
  return new;
end $$;
drop trigger if exists profiles_key on public.profiles;
create trigger profiles_key before insert or update on public.profiles
  for each row execute function public.profiles_key();

-- ---------- 2) 이미지 ----------
create or replace function public.uimg_ok(p_kind text, p_img text) returns boolean
  language plpgsql immutable set search_path = public as $$
declare j jsonb; k text; v jsonb; re text := '^data:image/(webp|png|jpeg);base64,[A-Za-z0-9+/=]+$';
begin
  if p_kind = 'pieces' then
    begin j := p_img::jsonb; exception when others then return false; end;
    if jsonb_typeof(j) <> 'object' then return false; end if;
    for k, v in select * from jsonb_each(j) loop
      if k !~ '^[A-Za-z]{1,2}$' or jsonb_typeof(v) <> 'string' or (v #>> '{}') !~ re then return false; end if;
    end loop;
    return true;
  end if;
  return p_img ~ re;
end $$;
alter table public.user_imgs drop constraint if exists user_imgs_format;
alter table public.user_imgs add constraint user_imgs_format check (public.uimg_ok(kind, img)) not valid;

notify pgrst, 'reload schema';
