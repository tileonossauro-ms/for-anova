-- =====================================================================
-- 0014_estoque_simples.sql — Escopo reduzido: estoque controla ENTRADA
-- (com justificativa) e SAÍDA (podendo marcar como Venda e atrelar um
-- vendedor). Tudo por REGIÃO (região = estoque; resolve a filial 1:1).
-- =====================================================================

-- vendedor atrelado a uma saída marcada como venda
alter table inventory_movements add column if not exists vendedor_id uuid references profiles(id);

-- saldo de um produto numa região
create or replace function fn_saldo_regiao(p_produto uuid, p_regiao uuid)
returns numeric language sql stable as $$
  select coalesce((
    select sum(ib.quantidade) from inventory_balances ib
    join filiais f on f.id = ib.filial_id
    where f.regiao_id = p_regiao and ib.produto_id = p_produto
  ), 0);
$$;

-- ENTRADA — exige justificativa
create or replace function fn_entrada(p_produto uuid, p_regiao uuid, p_qtd numeric, p_motivo text)
returns void language plpgsql security definer set search_path = public as $$
declare v_filial uuid;
begin
  if not is_admin() then raise exception 'apenas admin'; end if;
  if coalesce(trim(p_motivo),'') = '' then raise exception 'informe a justificativa da entrada'; end if;
  if coalesce(p_qtd,0) <= 0 then raise exception 'quantidade inválida'; end if;
  v_filial := fn_filial_da_regiao(p_regiao);
  if v_filial is null then raise exception 'região sem estoque configurado'; end if;
  insert into inventory_movements (produto_id, filial_id, tipo, quantidade, motivo, referencia_tipo, usuario_id)
  values (p_produto, v_filial, 'entrada', abs(p_qtd), p_motivo, 'entrada', auth.uid());
end $$;

-- SAÍDA — se p_venda, marca como venda e atrela o vendedor; senão, ajuste/baixa
create or replace function fn_saida(
  p_produto uuid, p_regiao uuid, p_qtd numeric, p_motivo text,
  p_venda boolean default false, p_vendedor uuid default null
) returns void language plpgsql security definer set search_path = public as $$
declare v_filial uuid;
begin
  if not is_admin() then raise exception 'apenas admin'; end if;
  if coalesce(p_qtd,0) <= 0 then raise exception 'quantidade inválida'; end if;
  if not p_venda and coalesce(trim(p_motivo),'') = '' then
    raise exception 'informe o motivo da saída'; end if;
  v_filial := fn_filial_da_regiao(p_regiao);
  if v_filial is null then raise exception 'região sem estoque configurado'; end if;
  insert into inventory_movements (produto_id, filial_id, tipo, quantidade, motivo,
          referencia_tipo, usuario_id, vendedor_id)
  values (p_produto, v_filial,
          (case when p_venda then 'venda' else 'ajuste' end)::tipo_movimento,
          -abs(p_qtd),
          nullif(p_motivo,''),
          case when p_venda then 'venda' else 'ajuste' end,
          auth.uid(),
          case when p_venda then p_vendedor end);
end $$;

-- movimentos recentes de uma região (com nome do produto e do vendedor)
create or replace function fn_movimentos(p_regiao uuid, p_limite int default 30)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  if not is_admin() then raise exception 'apenas admin'; end if;
  select coalesce(jsonb_agg(x order by x->>'quando' desc), '[]'::jsonb) into v from (
    select jsonb_build_object(
      'quando', mv.created_at, 'tipo', mv.tipo, 'quantidade', mv.quantidade,
      'motivo', mv.motivo, 'produto', pr.descricao, 'vendedor', vd.nome
    ) x
    from inventory_movements mv
    join filiais f on f.id = mv.filial_id and f.regiao_id = p_regiao
    join produtos pr on pr.id = mv.produto_id
    left join profiles vd on vd.id = mv.vendedor_id
    order by mv.created_at desc
    limit p_limite
  ) t;
  return v;
end $$;
