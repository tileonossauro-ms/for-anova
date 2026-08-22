-- =====================================================================
-- 0011_regiao_estoque.sql — Região = estoque. Cada região tem seu próprio
-- estoque. No banco isso é representado por uma FILIAL 1:1 com a região
-- (mantém o motor de estoque/transferências), mas na tela o usuário só
-- vê "região". Também: RPC de catálogo multi-região (preço + estoque).
-- =====================================================================

-- garante uma filial (estoque) para cada região existente
insert into filiais (codigo, nome, regiao_id)
select r.codigo, r.nome, r.id
from regioes r
where not exists (select 1 from filiais f where f.regiao_id = r.id)
on conflict (codigo) do update set regiao_id = excluded.regiao_id;

-- e para toda região nova criada daqui pra frente
create or replace function fn_regiao_cria_filial()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into filiais (codigo, nome, regiao_id)
  values (new.codigo, new.nome, new.id)
  on conflict (codigo) do update set regiao_id = excluded.regiao_id, nome = excluded.nome;
  return new;
end $$;
drop trigger if exists trg_regiao_cria_filial on regioes;
create trigger trg_regiao_cria_filial after insert on regioes
  for each row execute function fn_regiao_cria_filial();

-- helper: filial (estoque) de uma região
create or replace function fn_filial_da_regiao(p_regiao uuid)
returns uuid language sql stable as $$
  select id from filiais where regiao_id = p_regiao order by created_at limit 1;
$$;

-- =====================================================================
-- Catálogo multi-região: para cada produto ativo e cada região pedida,
-- devolve preço final e estoque da região. Formato "longo" (uma linha por
-- produto+região) — o front monta as colunas.
-- =====================================================================
create or replace function fn_catalogo_multi(p_regioes uuid[])
returns table (
  produto_id     uuid,
  descricao      text,
  marca          text,
  categoria      text,
  codigo         text,
  codigo_fabrica text,
  status         status_produto,
  tipo_preco     tipo_preco_produto,
  regiao_id      uuid,
  regiao_nome    text,
  preco          numeric,
  estoque        numeric
)
language sql stable as $$
  select
    p.id, p.descricao, m.nome, c.nome, p.codigo, p.codigo_fabrica, p.status, p.tipo_preco,
    r.id, r.nome,
    (fn_calcular_preco(p.id, r.id) ->> 'preco_final')::numeric,
    coalesce((
      select sum(ib.quantidade) from inventory_balances ib
      join filiais f on f.id = ib.filial_id
      where f.regiao_id = r.id and ib.produto_id = p.id
    ), 0)
  from produtos p
  left join marcas m on m.id = p.marca_id
  left join categorias c on c.id = p.categoria_id
  cross join regioes r
  where p.status = 'ativo'
    and r.id = any(p_regioes)
  order by p.descricao, r.ordem;
$$;
