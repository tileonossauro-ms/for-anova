-- =====================================================================
-- 0009_user_profiles.sql — Perfil automático ao criar login + visão de
-- usuários para o admin. Criar o LOGIN em si (auth) exige service_role e
-- é feito no painel do Supabase; aqui o perfil nasce sozinho e o admin
-- ajusta papel/região/ativo pela tela (seções 15-16).
-- =====================================================================

-- Cria automaticamente um profile quando um usuário de auth é criado.
-- Papel inicial: vendedor. Nome: parte antes do @ do email (editável depois).
create or replace function fn_novo_usuario()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (id, nome, papel, ativo)
  values (new.id, split_part(coalesce(new.email,'usuario'), '@', 1), 'vendedor', true)
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists trg_novo_usuario on auth.users;
create trigger trg_novo_usuario after insert on auth.users
  for each row execute function fn_novo_usuario();

-- Backfill: cria profile para logins que já existem e ainda não têm perfil.
insert into profiles (id, nome, papel, ativo)
select u.id, split_part(coalesce(u.email,'usuario'),'@',1), 'vendedor', true
from auth.users u
left join profiles p on p.id = u.id
where p.id is null
on conflict (id) do nothing;

-- Visão para o admin listar usuários com a região e um resumo de atividade.
create or replace function fn_usuarios()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  if not is_admin() then raise exception 'apenas admin'; end if;
  select coalesce(jsonb_agg(x order by x->>'nome'), '[]'::jsonb) into v from (
    select jsonb_build_object(
      'id', p.id, 'nome', p.nome, 'papel', p.papel, 'ativo', p.ativo,
      'regiao_padrao_id', p.regiao_padrao_id,
      'regiao_nome', r.nome,
      'vendas', (select count(*) from sales s where s.vendedor_id = p.id),
      'ultima_venda', (select max(s.created_at) from sales s where s.vendedor_id = p.id)
    ) x
    from profiles p left join regioes r on r.id = p.regiao_padrao_id
  ) t;
  return v;
end $$;
