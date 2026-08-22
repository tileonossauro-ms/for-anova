-- =====================================================================
-- 0005_catalogo.sql — RPC de catálogo: todos os produtos com preço já
-- calculado para uma região, em uma única chamada (rápido no mobile).
-- =====================================================================

create or replace function fn_catalogo(p_regiao uuid)
returns table (
  produto_id   uuid,
  codigo       text,
  descricao    text,
  marca        text,
  categoria    text,
  unidade      text,
  status       status_produto,
  tipo_preco   tipo_preco_produto,
  preco_final  numeric,
  usou_preco_manual boolean
)
language sql stable as $$
  select
    p.id, p.codigo, p.descricao,
    m.nome, c.nome, p.unidade, p.status, p.tipo_preco,
    (fn_calcular_preco(p.id, p_regiao) ->> 'preco_final')::numeric,
    (fn_calcular_preco(p.id, p_regiao) ->> 'usou_preco_manual')::boolean
  from produtos p
  left join marcas m on m.id = p.marca_id
  left join categorias c on c.id = p.categoria_id
  where p.status = 'ativo'
  order by p.descricao;
$$;

-- Explicação de preço de um produto (para a tela "por que R$ X")
create or replace function fn_explicar_preco(p_produto uuid, p_regiao uuid)
returns jsonb language sql stable as $$
  select fn_calcular_preco(p_produto, p_regiao);
$$;
