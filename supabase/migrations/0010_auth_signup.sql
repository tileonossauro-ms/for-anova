-- =====================================================================
-- 0010_auth_signup.sql — Auto-cadastro de vendedores.
-- Fluxo: pessoa se cadastra (signUp) -> confirma email -> entra como
-- PENDENTE (ativo=false) -> admin libera (ativo=true) e define a região.
-- Enquanto pendente/bloqueado, não vê nada (gate no app + RLS).
-- =====================================================================

-- Novo cadastro entra PENDENTE (ativo=false). Segurança: o site é público,
-- então o admin precisa liberar antes de a pessoa ver preços.
create or replace function fn_novo_usuario()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (id, nome, papel, ativo)
  values (new.id, split_part(coalesce(new.email,'usuario'), '@', 1), 'vendedor', false)
  on conflict (id) do nothing;
  return new;
end $$;

-- helper: o usuário logado é um perfil ATIVO?
create or replace function fn_ativo()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles p where p.id = auth.uid() and p.ativo);
$$;

-- Endurecer leitura: só usuários ATIVOS enxergam catálogo/regras/estoque.
-- (profiles_select continua liberado pro próprio usuário saber que está
--  pendente/bloqueado.)
do $$
declare t text;
begin
  foreach t in array array[
    'regioes','filiais','marcas','categorias','produtos','componentes_preco',
    'config_precificacao','produto_indice_regiao','produto_preco_manual','inventory_balances'
  ] loop
    execute format('drop policy if exists %1$s_read on %1$s;', t);
    execute format('create policy %1$s_read on %1$s for select to authenticated using (fn_ativo());', t);
  end loop;
end $$;

-- fn_usuarios com email e status de confirmação (para o admin gerenciar)
create or replace function fn_usuarios()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  if not is_admin() then raise exception 'apenas admin'; end if;
  select coalesce(jsonb_agg(x order by x->>'ativo', x->>'nome'), '[]'::jsonb) into v from (
    select jsonb_build_object(
      'id', p.id, 'nome', p.nome, 'papel', p.papel, 'ativo', p.ativo,
      'regiao_padrao_id', p.regiao_padrao_id, 'regiao_nome', r.nome,
      'email', u.email,
      'confirmado', (u.email_confirmed_at is not null),
      'vendas', (select count(*) from sales s where s.vendedor_id = p.id),
      'ultima_venda', (select max(s.created_at) from sales s where s.vendedor_id = p.id)
    ) x
    from profiles p
    left join regioes r on r.id = p.regiao_padrao_id
    left join auth.users u on u.id = p.id
  ) t;
  return v;
end $$;
