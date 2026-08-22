-- =====================================================================
-- 0012_custo_tabela.sql — Fluxo da planilha para chegar ao custo:
--   TABELA BRUTA × % desconto (MULTIPLDESCON)  =  CUSTO
-- Guarda o % por produto e gera o custo (com histórico). O custo também
-- pode ser informado direto (nota fiscal) — os dois caminhos coexistem.
-- Também: coluna 'travado' para proteger linhas na edição em massa.
-- =====================================================================

alter table produtos add column if not exists multiplicador_desconto numeric(8,5);
alter table produtos add column if not exists travado boolean not null default false;

-- backfill: reconstrói o % a partir do custo/tabela já importados
update produtos
set multiplicador_desconto = round(custo_atual / tabela_bruta, 5)
where multiplicador_desconto is null
  and tabela_bruta is not null and tabela_bruta > 0
  and custo_atual is not null and custo_atual > 0;

-- define o custo a partir de tabela × %  (gera o custo e registra histórico)
create or replace function fn_definir_custo(
  p_produto uuid, p_tabela numeric, p_mult numeric
) returns numeric
language plpgsql security definer set search_path = public as $$
declare v_ant numeric(14,2); v_custo numeric(14,2);
begin
  if not is_admin() then raise exception 'apenas admin'; end if;
  v_custo := round(coalesce(p_tabela,0) * coalesce(p_mult,0), 2);
  select custo_atual into v_ant from produtos where id = p_produto;
  update produtos
    set tabela_bruta = p_tabela, multiplicador_desconto = p_mult, custo_atual = v_custo
    where id = p_produto;
  insert into cost_history (produto_id, custo_anterior, custo_novo, origem, usuario_id)
  values (p_produto, v_ant, v_custo, 'tabela x desconto', auth.uid());
  return v_custo;
end $$;
