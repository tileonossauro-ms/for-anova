-- =====================================================================
-- 0008_dashboard.sql — Resumo para o dashboard do Marcos (admin).
-- Uma chamada retorna vendas, ticket médio, rankings e estoque no período.
-- =====================================================================

create or replace function fn_dashboard(
  p_inicio timestamptz default (now() - interval '30 days'),
  p_fim    timestamptz default now(),
  p_estoque_baixo numeric default 3
) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  if not is_admin() then raise exception 'apenas admin'; end if;

  select jsonb_build_object(
    'periodo', jsonb_build_object('inicio', p_inicio, 'fim', p_fim),

    -- resumo de vendas
    'vendas', (
      select jsonb_build_object(
        'quantidade', count(*),
        'faturamento', coalesce(sum(total),0),
        'ticket_medio', coalesce(avg(total),0)
      ) from sales where created_at between p_inicio and p_fim
    ),

    -- por vendedor
    'por_vendedor', (
      select coalesce(jsonb_agg(x order by x->>'faturamento' desc), '[]'::jsonb) from (
        select jsonb_build_object('nome', coalesce(p.nome,'—'),
               'vendas', count(s.id), 'faturamento', coalesce(sum(s.total),0),
               'ticket_medio', coalesce(avg(s.total),0)) x
        from sales s left join profiles p on p.id = s.vendedor_id
        where s.created_at between p_inicio and p_fim
        group by p.nome
      ) t
    ),

    -- por região
    'por_regiao', (
      select coalesce(jsonb_agg(x order by x->>'faturamento' desc), '[]'::jsonb) from (
        select jsonb_build_object('nome', coalesce(r.nome,'—'),
               'faturamento', coalesce(sum(s.total),0)) x
        from sales s left join regioes r on r.id = s.regiao_id
        where s.created_at between p_inicio and p_fim
        group by r.nome
      ) t
    ),

    -- produtos mais vendidos
    'top_produtos', (
      select coalesce(jsonb_agg(x order by (x->>'quantidade')::numeric desc), '[]'::jsonb) from (
        select jsonb_build_object('descricao', pr.descricao,
               'quantidade', sum(si.quantidade), 'total', sum(si.subtotal)) x
        from sale_items si
        join sales s on s.id = si.sale_id
        join produtos pr on pr.id = si.produto_id
        where s.created_at between p_inicio and p_fim
        group by pr.descricao
        limit 10
      ) t
    ),

    -- estoque
    'estoque', jsonb_build_object(
      'itens_totais', (select coalesce(sum(quantidade),0) from inventory_balances),
      'sem_estoque', (select count(*) from inventory_balances where quantidade <= 0),
      'estoque_baixo', (select count(*) from inventory_balances where quantidade > 0 and quantidade <= p_estoque_baixo)
    ),

    -- operação
    'transfer_pendentes', (select count(*) from transfers where estado = 'enviada')
  ) into v;

  return v;
end $$;
