-- =====================================================================
-- 0002_pricing_engine.sql — MOTOR DE PRECIFICAÇÃO 100% EDITÁVEL
-- Princípio: NENHUM número/regra fica no código. Tudo é dado que o
-- admin cria/edita/remove. Só a MECÂNICA de aplicar é código fixo.
--
-- Camadas:
--   1) Índice regional      -> regioes.indice_padrao  (+ exceção por produto)
--   2) Componentes de preço  -> impostos, taxas, descontos, acréscimos,
--                               arredondamento — linhas editáveis, com escopo
--   3) Preço manual travado  -> quando existe, o motor NÃO sobrescreve
--   4) Parâmetros globais     -> fator de custo etc. (chave/valor editável)
-- =====================================================================

-- ---------- Parâmetros globais editáveis (chave/valor) ----------
create table if not exists config_precificacao (
  chave      text primary key,          -- ex.: 'fator_custo_padrao'
  valor_num  numeric(14,6),
  valor_txt  text,
  descricao  text,
  updated_at timestamptz not null default now()
);
drop trigger if exists trg_config_updated on config_precificacao;
create trigger trg_config_updated before update on config_precificacao
  for each row execute function set_updated_at();

-- ---------- Exceção de índice por produto+região ----------
-- Ex.: SP_SP normalmente 0.30, mas ESTE produto usa 0.31.
create table if not exists produto_indice_regiao (
  produto_id uuid not null references produtos(id) on delete cascade,
  regiao_id  uuid not null references regioes(id) on delete cascade,
  indice     numeric(8,5) not null,
  observacao text,
  updated_at timestamptz not null default now(),
  primary key (produto_id, regiao_id)
);
drop trigger if exists trg_prodidx_updated on produto_indice_regiao;
create trigger trg_prodidx_updated before update on produto_indice_regiao
  for each row execute function set_updated_at();

-- ---------- Preço manual travado por produto+região ----------
-- Quando ativo, o motor devolve este preço (produtos-exceção / OUTRAS MARCAS).
create table if not exists produto_preco_manual (
  produto_id uuid not null references produtos(id) on delete cascade,
  regiao_id  uuid not null references regioes(id) on delete cascade,
  preco      numeric(14,2) not null,
  ativo      boolean not null default true,
  observacao text,
  updated_at timestamptz not null default now(),
  primary key (produto_id, regiao_id)
);
drop trigger if exists trg_precoman_updated on produto_preco_manual;
create trigger trg_precoman_updated before update on produto_preco_manual
  for each row execute function set_updated_at();

-- =====================================================================
-- COMPONENTES DE PREÇO — o "sem colunas mágicas" (seção 10 do prompt)
-- Cada linha é um passo do cálculo que o admin adiciona/edita/remove.
-- tipo define a MECÂNICA; valor é o número; escopo define ONDE se aplica.
-- Escopo nulo em todos = global. Quanto mais campos de escopo preenchidos,
-- mais específico. Todos os que casam o escopo são aplicados, na 'ordem'.
-- =====================================================================
do $$ begin
  if not exists (select 1 from pg_type where typname='tipo_componente') then
    create type tipo_componente as enum (
      'percentual', 'imposto', 'desconto', 'valor_fixo', 'multiplicador', 'arredondamento'
    );
  end if;
end $$;

create table if not exists componentes_preco (
  id           uuid primary key default gen_random_uuid(),
  nome         text not null,             -- ex.: 'ICMS Antecipa SP', 'Prazo 30/60/90'
  tipo         tipo_componente not null,
  valor        numeric(14,6) not null default 0,
  ordem        int not null default 100,  -- ordem de aplicação no pipeline
  prioridade   int not null default 0,    -- desempate quando 'ordem' empata
  ativo        boolean not null default true,
  -- escopo (null = qualquer):
  regiao_id    uuid references regioes(id)    on delete cascade,
  categoria_id uuid references categorias(id) on delete cascade,
  produto_id   uuid references produtos(id)   on delete cascade,
  observacao   text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
drop trigger if exists trg_comp_updated on componentes_preco;
create trigger trg_comp_updated before update on componentes_preco
  for each row execute function set_updated_at();
create index if not exists idx_comp_escopo on componentes_preco(ativo, regiao_id, categoria_id, produto_id);

-- =====================================================================
-- MECÂNICA (código fixo) — arredondamento configurável
-- valor = múltiplo alvo. Ex.: valor=100 -> arredonda p/ centena;
-- valor=10 -> dezena. (Regra "…990" fica p/ refino após validação.)
-- =====================================================================
create or replace function fn_arredondar(v numeric, multiplo numeric)
returns numeric language plpgsql immutable as $$
begin
  if multiplo is null or multiplo <= 0 then
    return v;
  end if;
  return round(v / multiplo) * multiplo;
end $$;

-- =====================================================================
-- MOTOR: fn_calcular_preco(produto, região)
-- Retorna jsonb com preço final + PASSOS (a explicação "por que R$ X").
-- Data-driven: lê regioes, produto_indice_regiao, componentes_preco,
-- produto_preco_manual e config_precificacao. Zero número chumbado.
-- =====================================================================
-- p_custo_override: se informado, calcula como se o custo fosse esse (prévia
-- de Nova Compra). Chamadas de 2 args continuam válidas (default null).
create or replace function fn_calcular_preco(
  p_produto uuid, p_regiao uuid, p_custo_override numeric default null
)
returns jsonb
language plpgsql stable as $$
declare
  v_prod      produtos%rowtype;
  v_reg       regioes%rowtype;
  v_custo     numeric(14,4);
  v_fator     numeric(14,6);
  v_indice    numeric(8,5);
  v_val       numeric(14,4);
  v_antes     numeric(14,4);
  v_passos    jsonb := '[]'::jsonb;
  v_manual    numeric(14,2);
  c           record;
begin
  select * into v_prod from produtos where id = p_produto;
  if not found then return jsonb_build_object('erro','produto inexistente'); end if;
  select * into v_reg  from regioes  where id = p_regiao;
  if not found then return jsonb_build_object('erro','regiao inexistente'); end if;

  -- (0) custo base: override (prévia) > custo informado > tabela × fator (fallback)
  v_custo := coalesce(p_custo_override, v_prod.custo_atual);
  if v_custo is null or v_custo = 0 then
    select valor_num into v_fator from config_precificacao where chave = 'fator_custo_padrao';
    v_fator := coalesce(v_fator, 0);
    if v_prod.tabela_bruta is not null and v_fator > 0 then
      v_custo := v_prod.tabela_bruta * v_fator;
      v_passos := v_passos || jsonb_build_object(
        'passo','custo (fallback)', 'tipo','fator_custo',
        'valor', v_fator, 'antes', v_prod.tabela_bruta, 'depois', v_custo);
    end if;
  end if;
  v_custo := coalesce(v_custo, 0);
  v_val := v_custo;
  -- passo inicial = custo base (mantém eventual passo de fallback já registrado)
  v_passos := jsonb_build_array(
      jsonb_build_object('passo','custo base','tipo','custo','antes',null,'depois',v_val)
    ) || v_passos;

  -- (1) índice regional (com exceção por produto)
  select indice into v_indice from produto_indice_regiao
    where produto_id = p_produto and regiao_id = p_regiao;
  v_indice := coalesce(v_indice, v_reg.indice_padrao);
  v_antes := v_val;
  v_val := v_val * (1 + v_indice);
  v_passos := v_passos || jsonb_build_object(
    'passo', 'índice ' || v_reg.nome, 'tipo','indice',
    'valor', v_indice, 'antes', v_antes, 'depois', v_val);

  -- (2) componentes que casam o escopo (global/região/categoria/produto), na ordem
  for c in
    select * from componentes_preco
     where ativo
       and (regiao_id    is null or regiao_id    = p_regiao)
       and (categoria_id is null or categoria_id = v_prod.categoria_id)
       and (produto_id   is null or produto_id   = p_produto)
     order by ordem, prioridade, created_at
  loop
    v_antes := v_val;
    v_val := case c.tipo
      when 'percentual'    then v_val * (1 + c.valor)
      when 'imposto'       then v_val * (1 + c.valor)
      when 'desconto'      then v_val * (1 - c.valor)
      when 'valor_fixo'    then v_val + c.valor
      when 'multiplicador' then v_val * c.valor
      when 'arredondamento'then fn_arredondar(v_val, c.valor)
      else v_val end;
    v_passos := v_passos || jsonb_build_object(
      'passo', c.nome, 'tipo', c.tipo, 'valor', c.valor,
      'antes', v_antes, 'depois', v_val);
  end loop;

  -- (3) preço manual travado sobrepõe o cálculo (mas mostramos os dois)
  select preco into v_manual from produto_preco_manual
    where produto_id = p_produto and regiao_id = p_regiao and ativo;

  return jsonb_build_object(
    'produto_id', p_produto,
    'regiao_id',  p_regiao,
    'custo_base', v_custo,
    'indice',     v_indice,
    'preco_calculado', round(v_val, 2),
    'preco_manual',    v_manual,
    'preco_final', coalesce(v_manual, round(v_val, 2)),
    'usou_preco_manual', (v_manual is not null),
    'tipo_preco', v_prod.tipo_preco,
    'passos', v_passos
  );
end $$;

-- Semente mínima de parâmetros (editável depois pelo admin)
insert into config_precificacao (chave, valor_num, descricao) values
  ('fator_custo_padrao', 0.4288, 'Fator sugerido tabela_bruta -> custo (fallback). ~0,4288 na planilha.')
on conflict (chave) do nothing;
