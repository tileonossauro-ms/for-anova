-- =====================================================================
-- 0015_grade_precos.sql — Grade de preços do admin: preço CALCULADO
-- (custo × taxa × impostos) de TODOS os produtos, por região. Diferente
-- do catálogo (fn_catalogo_multi), que usa o preço final/manual. Aqui o
-- motor sempre calcula, pra o admin "fazer a conta" de qualquer produto.
-- =====================================================================
create or replace function fn_grade_precos(p_regioes uuid[])
returns table (produto_id uuid, regiao_id uuid, preco_calculado numeric)
language sql stable as $$
  select p.id, r.id, (fn_calcular_preco(p.id, r.id) ->> 'preco_calculado')::numeric
  from produtos p
  cross join regioes r
  where r.id = any(p_regioes)
  order by p.descricao, r.ordem;
$$;
