-- APLICAR_TUDO.sql — cole tudo no SQL Editor e RUN. Idempotente.


-- >>>>>>>>>> 0001_core.sql <<<<<<<<<<

-- =====================================================================
-- 0001_core.sql — Fundação: perfis, papéis, regiões, filiais, marcas,
-- categorias e produtos. (Fase 1 do plano)
-- Tudo em snake_case, IDs uuid, timestamps padronizados.
-- =====================================================================

create extension if not exists "pgcrypto";
create extension if not exists pg_trgm;

-- ---------- helpers de timestamp ----------
create or replace function set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end $$;

-- =====================================================================
-- PERFIS E PAPÉIS
-- profiles estende auth.users (1:1). O papel controla permissão (RLS).
-- =====================================================================
do $$ begin
  if not exists (select 1 from pg_type where typname='papel_usuario') then
    create type papel_usuario as enum ('admin', 'vendedor');
  end if;
end $$;

create table if not exists profiles (
  id            uuid primary key references auth.users(id) on delete cascade,
  nome          text not null,
  papel         papel_usuario not null default 'vendedor',
  regiao_padrao_id uuid,                       -- FK adicionada após criar regioes
  ativo         boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
drop trigger if exists trg_profiles_updated on profiles;
create trigger trg_profiles_updated before update on profiles
  for each row execute function set_updated_at();

-- Função auxiliar: o usuário logado é admin?  (usada em toda RLS)
create or replace function is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from profiles p where p.id = auth.uid() and p.papel = 'admin' and p.ativo
  );
$$;

-- =====================================================================
-- REGIÕES (comerciais — determinam PREÇO)  ≠  FILIAIS (estoque físico)
-- indice_padrao é EDITÁVEL: é o índice base da região (ex.: 0.45 = +45%).
-- =====================================================================
create table if not exists regioes (
  id            uuid primary key default gen_random_uuid(),
  codigo        text not null unique,          -- ex.: MS_DDOS
  nome          text not null,                 -- ex.: MS Dourados
  indice_padrao numeric(8,5) not null default 0,   -- ex.: 0.45  (EDITÁVEL)
  ativo         boolean not null default true,
  ordem         int not null default 0,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
drop trigger if exists trg_regioes_updated on regioes;
create trigger trg_regioes_updated before update on regioes
  for each row execute function set_updated_at();

alter table profiles drop constraint if exists fk_profiles_regiao;
alter table profiles
  add constraint fk_profiles_regiao
  foreign key (regiao_padrao_id) references regioes(id) on delete set null;

-- =====================================================================
-- FILIAIS (locais de estoque físico)
-- =====================================================================
create table if not exists filiais (
  id         uuid primary key default gen_random_uuid(),
  codigo     text not null unique,             -- ex.: DD, JD, MJ
  nome       text not null,
  regiao_id  uuid references regioes(id) on delete set null,  -- relação opcional
  ativo      boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
drop trigger if exists trg_filiais_updated on filiais;
create trigger trg_filiais_updated before update on filiais
  for each row execute function set_updated_at();

-- =====================================================================
-- MARCAS e CATEGORIAS (separadas — na planilha vinham misturadas)
-- =====================================================================
create table if not exists marcas (
  id     uuid primary key default gen_random_uuid(),
  nome   text not null unique,
  ativo  boolean not null default true
);
create table if not exists categorias (
  id     uuid primary key default gen_random_uuid(),
  nome   text not null unique,
  ativo  boolean not null default true
);

-- =====================================================================
-- PRODUTOS — entidade central
-- tipo_preco: 'motor' calcula pelas regras; 'manual' usa preço travado;
--             'especial' = regra própria (não sobrescrever na importação).
-- =====================================================================
do $$ begin
  if not exists (select 1 from pg_type where typname='status_produto') then
    create type status_produto as enum ('ativo', 'inativo', 'descontinuado');
  end if;
  if not exists (select 1 from pg_type where typname='tipo_preco_produto') then
    create type tipo_preco_produto as enum ('motor', 'manual', 'especial');
  end if;
end $$;

create table if not exists produtos (
  id             uuid primary key default gen_random_uuid(),
  -- codigo (RG) NÃO é único: na planilha há códigos repetidos e '0'/'NT'
  -- (usados sem código). Cada linha vira um produto; duplicatas são
  -- sinalizadas para revisão, nunca fundidas silenciosamente.
  codigo         text,                          -- RG / código interno (pode faltar)
  codigo_fabrica text,
  descricao      text not null,
  marca_id       uuid references marcas(id) on delete set null,
  categoria_id   uuid references categorias(id) on delete set null,
  unidade        text not null default 'UN',
  custo_atual    numeric(14,2),                -- informado da nota fiscal
  tabela_bruta   numeric(14,2),                -- referência (fallback p/ sugestão)
  status         status_produto not null default 'ativo',
  tipo_preco     tipo_preco_produto not null default 'motor',
  observacoes    text,
  origem_import  text,                         -- rastro da migração (bloco/flags)
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
drop trigger if exists trg_produtos_updated on produtos;
create trigger trg_produtos_updated before update on produtos
  for each row execute function set_updated_at();

create index if not exists idx_produtos_categoria on produtos(categoria_id);
create index if not exists idx_produtos_marca on produtos(marca_id);
create index if not exists idx_produtos_status on produtos(status);
-- busca rápida por descrição/código (catálogo do vendedor)
create index if not exists idx_produtos_descricao_trgm on produtos using gin (descricao gin_trgm_ops);


-- >>>>>>>>>> 0002_pricing_engine.sql <<<<<<<<<<

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
-- Remove a versão antiga de 2 args (de bancos já aplicados) para não haver
-- ambiguidade de sobrecarga com a versão de 3 args abaixo.
drop function if exists fn_calcular_preco(uuid, uuid);
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


-- >>>>>>>>>> 0003_seed.sql <<<<<<<<<<

-- 0003_seed.sql — 248 produtos reais (cada linha = 1 produto; duplicatas sinalizadas, não fundidas).

insert into regioes (codigo,nome,indice_padrao,ordem) values
  ('MS_DDOS','MS Dourados',0.45,10),
  ('MS_ANDREI','MS Andréi',0.42,20),
  ('VENDA_DIRETA_MS','Venda Direta MS',0,30),
  ('SP_SP','SP → SP',0.3,40),
  ('SP_OUTROS','SP → Outros',0.34,50),
  ('SP_RJ_MG_SUL','SP/RJ/MG/Sul',0.38,60),
  ('DOURADOS_MS','Dourados/MS (outras marcas)',0,70),
  ('SP_MONTAGEM','NF SP p/ SP c/ montagem',0,80),
  ('OUTROS_ES','NF SP p/ Outros Estados',0,90),
  ('MG_RJ_SUL','NF SP p/ MG/RJ/Sul',0,100)
on conflict (codigo) do nothing;

insert into marcas (nome) values
  ('PICCIN'),
  ('ALMEIDA')
on conflict (nome) do nothing;

insert into categorias (nome) values
  ('USADOS'),
  ('TRATOR'),
  ('MENTA'),
  ('PULV "CIMAG"'),
  ('PULVERIZADOR'),
  ('COMPOSTADOR'),
  ('ROÇADEIRA'),
  ('PERFURADOR'),
  ('BROCA 9'),
  ('BROCA 12'),
  ('BROCA 18'),
  ('GUINCHO BAG'),
  ('GUINCHO-800'),
  ('GUINCHO 3 PO'),
  ('PLATAFORMA'),
  ('PLAININHA'),
  ('PATROLINHA'),
  ('PATROLA'),
  ('CONCHINHA'),
  ('CONCHA PD'),
  ('CONCHA PCA'),
  ('SAB BAG'),
  ('ROLO FACA'),
  ('SCRAPER'),
  ('SUBSOLADOR'),
  ('ARADO AIVECA'),
  ('GRANELEIRA'),
  ('ADUBADEIRA'),
  ('CALCAREADEIRA'),
  ('TERRACEADOR'),
  ('NIVELADORA'),
  ('ARADORA 230'),
  ('INTERMEDIÁRIA'),
  ('INTERMEDIARIA'),
  ('PESADA'),
  ('SUPER PESADA'),
  ('EXTRA PESADA'),
  ('PLANTADEIRA')
on conflict (nome) do nothing;

do $$
declare v_prod uuid; v_reg uuid;
begin
  -- idempotente: só popula produtos se a tabela estiver vazia
  -- (evita duplicar os 248 se o deploy reaplicar a migration).
  if (select count(*) from produtos) > 0 then return; end if;
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53643',null,'CALCAREADEIRA MASTER 7.500 PNEUS 11L15 E EST 40 MM PRECISA',(select id from marcas where nome='PICCIN'),null,null,null,'manual','A_OUTRAS_MARCAS|SEM_CUSTO_TABELA|PRECO_MANUAL|BLOCO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='SP_MONTAGEM';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,38900);
  select id into v_reg from regioes where codigo='OUTROS_ES';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,39900);
  select id into v_reg from regioes where codigo='MG_RJ_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,40900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53710','1384947','GUINCHO BAG 2.000 BITOLA REGULÁVEL PN 11L15" (SAIU DE LINHA)',(select id from marcas where nome='ALMEIDA'),null,14100,null,'manual','A_OUTRAS_MARCAS|PRECO_MANUAL|BLOCO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='SP_MONTAGEM';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,19900);
  select id into v_reg from regioes where codigo='OUTROS_ES';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,20900);
  select id into v_reg from regioes where codigo='MG_RJ_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,21900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53924',null,'ROÇADEIRA 3 PONTO ROAL 1400 TRASM DIRETA',(select id from marcas where nome='ALMEIDA'),null,6750,null,'manual','A_OUTRAS_MARCAS|PRECO_MANUAL|BLOCO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='SP_MONTAGEM';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,10500);
  select id into v_reg from regioes where codigo='OUTROS_ES';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,11400);
  select id into v_reg from regioes where codigo='MG_RJ_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,11800);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53758',null,'ROÇADEIRA 3 PONTO ROAL 1600 TRASM DIRETA',(select id from marcas where nome='ALMEIDA'),null,7500,null,'manual','A_OUTRAS_MARCAS|PRECO_MANUAL|BLOCO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='SP_MONTAGEM';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,10900);
  select id into v_reg from regioes where codigo='OUTROS_ES';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,11500);
  select id into v_reg from regioes where codigo='MG_RJ_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,11900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53836',null,'ROÇADEIRA 3 PONTO ROAL 1800 TRASM DIRETA',(select id from marcas where nome='ALMEIDA'),null,8175,null,'manual','A_OUTRAS_MARCAS|PRECO_MANUAL|BLOCO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='SP_MONTAGEM';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,11900);
  select id into v_reg from regioes where codigo='OUTROS_ES';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,12400);
  select id into v_reg from regioes where codigo='MG_RJ_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,12900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53901',null,'ROÇADEIRA 3 PONTO ROCAL 1600 TRASM CORREIAS',(select id from marcas where nome='ALMEIDA'),null,9450,null,'manual','A_OUTRAS_MARCAS|PRECO_MANUAL|BLOCO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='SP_MONTAGEM';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,13500);
  select id into v_reg from regioes where codigo='OUTROS_ES';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,13900);
  select id into v_reg from regioes where codigo='MG_RJ_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,14500);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53851',null,'ROÇADEIRA 3 PONTO ROCAL 1800 TRANSM CORREIAS',(select id from marcas where nome='ALMEIDA'),null,10012,null,'manual','A_OUTRAS_MARCAS|PRECO_MANUAL|BLOCO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='SP_MONTAGEM';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,14300);
  select id into v_reg from regioes where codigo='OUTROS_ES';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,14900);
  select id into v_reg from regioes where codigo='MG_RJ_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,15600);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53858',null,'ROÇADEIRA ARRASTO ROACAL 1800 COM RODAS FERRO GRANDES',(select id from marcas where nome='ALMEIDA'),null,13050,null,'manual','A_OUTRAS_MARCAS|PRECO_MANUAL|BLOCO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='SP_MONTAGEM';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,18900);
  select id into v_reg from regioes where codigo='OUTROS_ES';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,19900);
  select id into v_reg from regioes where codigo='MG_RJ_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,20900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53950',null,'ROÇADEIRA ARRASTO ROACAL DUPLA 3400 RODAS FERRO GRANDES',(select id from marcas where nome='ALMEIDA'),null,21225,null,'manual','A_OUTRAS_MARCAS|PRECO_MANUAL|BLOCO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='SP_MONTAGEM';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,29900);
  select id into v_reg from regioes where codigo='OUTROS_ES';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,30900);
  select id into v_reg from regioes where codigo='MG_RJ_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,31900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('54045','1397662','CALC TECLANCER 3.0 EST 500 2 PN 750X16"',(select id from marcas where nome='ALMEIDA'),null,16400,null,'manual','A_OUTRAS_MARCAS|PRECO_MANUAL|BLOCO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='SP_MONTAGEM';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,22900);
  select id into v_reg from regioes where codigo='OUTROS_ES';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,23900);
  select id into v_reg from regioes where codigo='MG_RJ_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,24900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53660','1384981','CALC TECLANCER 6.0 EST 500 4 PN 750X16"',(select id from marcas where nome='ALMEIDA'),null,22000,null,'manual','A_OUTRAS_MARCAS|PRECO_MANUAL|BLOCO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='SP_MONTAGEM';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,30500);
  select id into v_reg from regioes where codigo='OUTROS_ES';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,31900);
  select id into v_reg from regioes where codigo='MG_RJ_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,32900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53734','1384785','CALC PRO TECLANCER 3.0 EST LARGA 800 MM 2 PN 750X16"',(select id from marcas where nome='ALMEIDA'),null,17800,null,'manual','A_OUTRAS_MARCAS|PRECO_MANUAL|BLOCO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='SP_MONTAGEM';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,24900);
  select id into v_reg from regioes where codigo='OUTROS_ES';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,25900);
  select id into v_reg from regioes where codigo='MG_RJ_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,26900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53853','1387045','CALC PRO TECLANCER 6.0 EST LARGA 800 MM 4 PN 750X16"',(select id from marcas where nome='ALMEIDA'),null,23600,null,'manual','A_OUTRAS_MARCAS|PRECO_MANUAL|BLOCO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='SP_MONTAGEM';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,33500);
  select id into v_reg from regioes where codigo='OUTROS_ES';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,34900);
  select id into v_reg from regioes where codigo='MG_RJ_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,36500);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53706','1384983','CALC PRO TECLANCER 8.0 EST LARGA 800 MM 4 PN 11L15" (LARGO)',(select id from marcas where nome='ALMEIDA'),null,26300,null,'manual','A_OUTRAS_MARCAS|PRECO_MANUAL|BLOCO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='SP_MONTAGEM';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,38500);
  select id into v_reg from regioes where codigo='OUTROS_ES';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,39900);
  select id into v_reg from regioes where codigo='MG_RJ_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,41500);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('54042',null,'CALC PRO TECLANCER 10.0 BIT FIXA CD EST 800 MM PN 12.4X24"',(select id from marcas where nome='ALMEIDA'),null,41900,null,'manual','A_OUTRAS_MARCAS|PRECO_MANUAL|BLOCO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='SP_MONTAGEM';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,59900);
  select id into v_reg from regioes where codigo='OUTROS_ES';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,62500);
  select id into v_reg from regioes where codigo='MG_RJ_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,64900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('54057',null,'DIAMOND 8.0 "INOX" BIT REG CD PN 11L15" EST 800/500 2 JG DISC',(select id from marcas where nome='ALMEIDA'),null,41508,null,'manual','A_OUTRAS_MARCAS|PRECO_MANUAL|BLOCO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='SP_MONTAGEM';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,56900);
  select id into v_reg from regioes where codigo='OUTROS_ES';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,58900);
  select id into v_reg from regioes where codigo='MG_RJ_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,60900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53900',null,'DIAMOND 10.0 CHAPA BIT REG CD PN 24"EST 800/500 2 JG DISCOS',(select id from marcas where nome='ALMEIDA'),null,48896,null,'manual','A_OUTRAS_MARCAS|PRECO_MANUAL|BLOCO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='SP_MONTAGEM';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,66900);
  select id into v_reg from regioes where codigo='OUTROS_ES';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,69900);
  select id into v_reg from regioes where codigo='MG_RJ_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,72500);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('54043',null,'DIAMOND 10.0 "INOX" 10.0 BIT REG CD PN 24" EST 800/500 2 JG DISCOS',(select id from marcas where nome='ALMEIDA'),null,60896,null,'manual','A_OUTRAS_MARCAS|PRECO_MANUAL|BLOCO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='SP_MONTAGEM';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,82900);
  select id into v_reg from regioes where codigo='OUTROS_ES';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,86900);
  select id into v_reg from regioes where codigo='MG_RJ_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,89900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('54058',null,'DIAMOND 12.0 CHAPA BIT REG CD PN 24" EST 800/500 2 JG DISCOS',(select id from marcas where nome='ALMEIDA'),null,61000,null,'manual','A_OUTRAS_MARCAS|PRECO_MANUAL|BLOCO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='SP_MONTAGEM';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,83900);
  select id into v_reg from regioes where codigo='OUTROS_ES';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,87900);
  select id into v_reg from regioes where codigo='MG_RJ_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,91900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('54001',null,'DIAMOND 12.0 "INOX" BIT REG TX FIXA CD 4 PN 24" 2 JG DISCOS',(select id from marcas where nome='ALMEIDA'),null,81000,null,'manual','A_OUTRAS_MARCAS|PRECO_MANUAL|BLOCO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='SP_MONTAGEM';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,106900);
  select id into v_reg from regioes where codigo='OUTROS_ES';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,110900);
  select id into v_reg from regioes where codigo='MG_RJ_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,113900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53733',null,'BLACK 12.0 INOX BIT REG TX VARIA HIDR 4 PN 24" 2 JG - TELA + ANTENA',(select id from marcas where nome='ALMEIDA'),null,124000,null,'manual','A_OUTRAS_MARCAS|PRECO_MANUAL|BLOCO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='SP_MONTAGEM';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,164900);
  select id into v_reg from regioes where codigo='OUTROS_ES';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,169900);
  select id into v_reg from regioes where codigo='MG_RJ_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,173900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53846','1388929','CARRETA BASCMAX CARGOR 5.0 ROD DUPLO C/ 4 PN 750X16"',(select id from marcas where nome='ALMEIDA'),null,14900,null,'manual','A_OUTRAS_MARCAS|PRECO_MANUAL|BLOCO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='SP_MONTAGEM';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,23900);
  select id into v_reg from regioes where codigo='OUTROS_ES';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,24900);
  select id into v_reg from regioes where codigo='MG_RJ_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,25900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53906','1389904','CARRETA BASC MAX CARGOR 5.0 RODADO *TANDEM* C/ 4 PN 750X16"',(select id from marcas where nome='ALMEIDA'),null,17500,null,'manual','A_OUTRAS_MARCAS|PRECO_MANUAL|BLOCO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='SP_MONTAGEM';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,26500);
  select id into v_reg from regioes where codigo='OUTROS_ES';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,27500);
  select id into v_reg from regioes where codigo='MG_RJ_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,28500);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53670','1384986','CARRETA BASC MAX CARGOR 6.0 RODADO DUPLO C/ 4 PN 750X16"',(select id from marcas where nome='ALMEIDA'),null,16900,null,'manual','A_OUTRAS_MARCAS|PRECO_MANUAL|BLOCO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='SP_MONTAGEM';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,26500);
  select id into v_reg from regioes where codigo='OUTROS_ES';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,27500);
  select id into v_reg from regioes where codigo='MG_RJ_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,28500);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53837','1389908','CARRETA BASC MAX CARGOR 6.0 RODADO TANDEM C/ 4 PN 750X16"',(select id from marcas where nome='ALMEIDA'),null,18800,null,'manual','A_OUTRAS_MARCAS|PRECO_MANUAL|BLOCO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='SP_MONTAGEM';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,27900);
  select id into v_reg from regioes where codigo='OUTROS_ES';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,28900);
  select id into v_reg from regioes where codigo='MG_RJ_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,29900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('54047','1397961','CARRETA BASC FORRAG 8.0 ROD TANDEM C/ 4 PN 11L15"',(select id from marcas where nome='ALMEIDA'),null,22500,null,'manual','A_OUTRAS_MARCAS|PRECO_MANUAL|BLOCO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='SP_MONTAGEM';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,30900);
  select id into v_reg from regioes where codigo='OUTROS_ES';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,32500);
  select id into v_reg from regioes where codigo='MG_RJ_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,33500);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53844','1385946','CARRETA BASC FORRAG 10.0 ROD TANDEM C/ 4 PN 400/60"',(select id from marcas where nome='ALMEIDA'),null,27700,null,'manual','A_OUTRAS_MARCAS|PRECO_MANUAL|BLOCO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='SP_MONTAGEM';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,39900);
  select id into v_reg from regioes where codigo='OUTROS_ES';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,41500);
  select id into v_reg from regioes where codigo='MG_RJ_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,42900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('54063',null,'CJ CARREGAD SPEED 1200 JÁ C/ CONCHA  + CHASSI  *SEM JOYSTICK *',(select id from marcas where nome='ALMEIDA'),null,15750,null,'manual','A_OUTRAS_MARCAS|PRECO_MANUAL|BLOCO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='SP_MONTAGEM';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,25900);
  select id into v_reg from regioes where codigo='OUTROS_ES';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,26900);
  select id into v_reg from regioes where codigo='MG_RJ_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,27900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('54017',null,'CJ CARREGAD SPEED 1200 JÁ C/ CONCHA  + CHASSI  *COM JOYSTICK*',(select id from marcas where nome='ALMEIDA'),null,17925,null,'manual','A_OUTRAS_MARCAS|PRECO_MANUAL|BLOCO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='SP_MONTAGEM';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,27900);
  select id into v_reg from regioes where codigo='OUTROS_ES';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,28900);
  select id into v_reg from regioes where codigo='MG_RJ_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,29900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('54133',null,'GUINCHO PEGA BAG PARA SPEED 1.200 TODOS TRATORES',(select id from marcas where nome='ALMEIDA'),null,2100,null,'manual','A_OUTRAS_MARCAS|PRECO_MANUAL|BLOCO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='SP_MONTAGEM';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,3200);
  select id into v_reg from regioes where codigo='OUTROS_ES';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,3400);
  select id into v_reg from regioes where codigo='MG_RJ_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,3600);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('54114',null,'LAMINA DE 2.150 MM PARA SPEED 1.200',(select id from marcas where nome='ALMEIDA'),null,2100,null,'manual','A_OUTRAS_MARCAS|PRECO_MANUAL|BLOCO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='SP_MONTAGEM';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,3300);
  select id into v_reg from regioes where codigo='OUTROS_ES';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,3500);
  select id into v_reg from regioes where codigo='MG_RJ_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,3700);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53841',null,'CJ PLAINA DIANT  PDAL 100 JÁ COM CHASSI + LAMINA 2,40 M S/ JOY',(select id from marcas where nome='ALMEIDA'),null,16477,null,'manual','A_OUTRAS_MARCAS|PRECO_MANUAL|BLOCO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='SP_MONTAGEM';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,25900);
  select id into v_reg from regioes where codigo='OUTROS_ES';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,26900);
  select id into v_reg from regioes where codigo='MG_RJ_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,27900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('54088',null,'CJ PLAINA DIANT  PDAL 1.000 JÁ COM CHASSI + LAMINA 2,60 M S/ JOY',(select id from marcas where nome='ALMEIDA'),null,18732,null,'manual','A_OUTRAS_MARCAS|PRECO_MANUAL|BLOCO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='SP_MONTAGEM';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,27900);
  select id into v_reg from regioes where codigo='OUTROS_ES';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,29300);
  select id into v_reg from regioes where codigo='MG_RJ_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,30700);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('54197',null,'CJ PLAINA DIANT  PDAL 1.100 JÁ COM CHASSI + LAMINA 2,60 M S/ JOY',(select id from marcas where nome='ALMEIDA'),null,22875,null,'manual','A_OUTRAS_MARCAS|PRECO_MANUAL|BLOCO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='SP_MONTAGEM';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,31900);
  select id into v_reg from regioes where codigo='OUTROS_ES';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,32900);
  select id into v_reg from regioes where codigo='MG_RJ_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,34200);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('54134',null,'CONCHA 1200 MM COM PISTÃO PARA PDAL 100',(select id from marcas where nome='ALMEIDA'),null,6450,null,'manual','A_OUTRAS_MARCAS|PRECO_MANUAL|BLOCO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='SP_MONTAGEM';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,9300);
  select id into v_reg from regioes where codigo='OUTROS_ES';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,9700);
  select id into v_reg from regioes where codigo='MG_RJ_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,10000);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('54135',null,'CONCHA 1700 MM COM PISTÃO PARA PDAL 1.000/1.100',(select id from marcas where nome='ALMEIDA'),null,7200,null,'manual','A_OUTRAS_MARCAS|PRECO_MANUAL|BLOCO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='SP_MONTAGEM';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,10500);
  select id into v_reg from regioes where codigo='OUTROS_ES';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,10900);
  select id into v_reg from regioes where codigo='MG_RJ_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,11400);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53676','1384916','GRADE ARAD CONTR REM 14X26"X6,00 235 MM PN 750X16" 80 CV',(select id from marcas where nome='ALMEIDA'),null,17800,26390,'manual','A_OUTRAS_MARCAS|PRECO_MANUAL|BLOCO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='SP_MONTAGEM';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,25500);
  select id into v_reg from regioes where codigo='OUTROS_ES';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,26500);
  select id into v_reg from regioes where codigo='MG_RJ_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,27500);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53677','1381942','GRADE ARAD CONTR REM 16X26"X6,00 235 MM PN 750X16" 90 CV',(select id from marcas where nome='ALMEIDA'),null,19200,28790,'manual','A_OUTRAS_MARCAS|PRECO_MANUAL|BLOCO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='SP_MONTAGEM';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,27500);
  select id into v_reg from regioes where codigo='OUTROS_ES';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,28900);
  select id into v_reg from regioes where codigo='MG_RJ_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,29900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53678','1381949','GRADE ARAD CONTR REM 18X26"X6,00 235 MM PN 750X16" 110 CV',(select id from marcas where nome='ALMEIDA'),null,20800,30659,'manual','A_OUTRAS_MARCAS|PRECO_MANUAL|BLOCO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='SP_MONTAGEM';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,28900);
  select id into v_reg from regioes where codigo='OUTROS_ES';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,29900);
  select id into v_reg from regioes where codigo='MG_RJ_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,30900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53617','1376719','GRADE INTER CONTR REM 14X28"X6,00 270 MM PN 750X16" 100 CV',(select id from marcas where nome='ALMEIDA'),null,18700,27569,'manual','A_OUTRAS_MARCAS|PRECO_MANUAL|BLOCO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='SP_MONTAGEM';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,26900);
  select id into v_reg from regioes where codigo='OUTROS_ES';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,27900);
  select id into v_reg from regioes where codigo='MG_RJ_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,28900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53679','1381951','GRADE INTER CONTR REM 16X28"X6,00 270 MM PN 750X16" 110 CV',(select id from marcas where nome='ALMEIDA'),null,20600,30767,'manual','A_OUTRAS_MARCAS|PRECO_MANUAL|BLOCO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='SP_MONTAGEM';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,29500);
  select id into v_reg from regioes where codigo='OUTROS_ES';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,30500);
  select id into v_reg from regioes where codigo='MG_RJ_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,31500);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53680','1381953','GRADE INTER CONTR REM 18X28"X6,00 270 MM PN 750X16" 120 CV',(select id from marcas where nome='ALMEIDA'),null,21400,32245,'manual','A_OUTRAS_MARCAS|PRECO_MANUAL|BLOCO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='SP_MONTAGEM';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,31900);
  select id into v_reg from regioes where codigo='OUTROS_ES';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,32900);
  select id into v_reg from regioes where codigo='MG_RJ_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,33900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53681','1381956','GRADE INTER CONTR REM 20X28"X6,00 270 MM PN 750X16" 125 CV',(select id from marcas where nome='ALMEIDA'),null,23900,36322,'manual','A_OUTRAS_MARCAS|PRECO_MANUAL|BLOCO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='SP_MONTAGEM';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,33900);
  select id into v_reg from regioes where codigo='OUTROS_ES';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,35200);
  select id into v_reg from regioes where codigo='MG_RJ_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,36900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53662','1376726','GRADE INTER CONTR REM 24X28"X6,00 270 MM PN 750X16" 160 CV',(select id from marcas where nome='ALMEIDA'),null,26700,40665,'manual','A_OUTRAS_MARCAS|PRECO_MANUAL|BLOCO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='SP_MONTAGEM';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,36900);
  select id into v_reg from regioes where codigo='OUTROS_ES';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,38500);
  select id into v_reg from regioes where codigo='MG_RJ_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,39900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53682','1381962','GRADE INTER CONTR REM 28X28"X6,00 270 MM PN 750X16" 180 CV',(select id from marcas where nome='ALMEIDA'),null,28900,42381,'manual','A_OUTRAS_MARCAS|PRECO_MANUAL|BLOCO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='SP_MONTAGEM';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,40900);
  select id into v_reg from regioes where codigo='OUTROS_ES';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,42500);
  select id into v_reg from regioes where codigo='MG_RJ_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,44200);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('54071','1399682','GRADE NIV CONTR REM FIXA 28X20"X3,50 175 MM PN 750X16" 75 CV',(select id from marcas where nome='ALMEIDA'),null,17800,23240,'manual','A_OUTRAS_MARCAS|PRECO_MANUAL|BLOCO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='SP_MONTAGEM';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,25500);
  select id into v_reg from regioes where codigo='OUTROS_ES';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,26500);
  select id into v_reg from regioes where codigo='MG_RJ_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,27500);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('54072','1399685','GRADE NIV CONTR REM FIXA 32X20"X3,50 175 MM PN 750X16" 80 CV',(select id from marcas where nome='ALMEIDA'),null,18600,25250,'manual','A_OUTRAS_MARCAS|PRECO_MANUAL|BLOCO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='SP_MONTAGEM';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,26500);
  select id into v_reg from regioes where codigo='OUTROS_ES';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,27500);
  select id into v_reg from regioes where codigo='MG_RJ_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,28500);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53674','1380241','GRADE NIV CONTR REM FIXA 36X20"X3,50 175 MM PN 750X16" 90 CV',(select id from marcas where nome='ALMEIDA'),null,19500,28657,'manual','A_OUTRAS_MARCAS|PRECO_MANUAL|BLOCO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='SP_MONTAGEM';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,27500);
  select id into v_reg from regioes where codigo='OUTROS_ES';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,28500);
  select id into v_reg from regioes where codigo='MG_RJ_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,29500);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53675','1381938','GRADE NIV CONTR REM FIXA 42X20"X3,50 175 MM PN 750X16" 100 CV',(select id from marcas where nome='ALMEIDA'),null,22400,32943,'manual','A_OUTRAS_MARCAS|PRECO_MANUAL|BLOCO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='SP_MONTAGEM';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,30900);
  select id into v_reg from regioes where codigo='OUTROS_ES';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,31900);
  select id into v_reg from regioes where codigo='MG_RJ_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,32900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53771','1384995','GRADE NIV CONT REM FIXA 32X22"X4,00 195 MM PN 750X16" 90 CV',(select id from marcas where nome='ALMEIDA'),null,20100,29586,'manual','A_OUTRAS_MARCAS|PRECO_MANUAL|BLOCO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='SP_MONTAGEM';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,29500);
  select id into v_reg from regioes where codigo='OUTROS_ES';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,30500);
  select id into v_reg from regioes where codigo='MG_RJ_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,31500);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53618','1384998','GRADE NIV CONT REM FIXA 36X22"X4,00 195 MM PN 750X16" 100 CV',(select id from marcas where nome='ALMEIDA'),null,21800,33794,'manual','A_OUTRAS_MARCAS|PRECO_MANUAL|BLOCO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='SP_MONTAGEM';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,30500);
  select id into v_reg from regioes where codigo='OUTROS_ES';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,31500);
  select id into v_reg from regioes where codigo='MG_RJ_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,32500);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53683','1381963','GRADE NIV CONT REM FIXA 44X22"X4,00 195 MM PN 750X16" 125 CV',(select id from marcas where nome='ALMEIDA'),null,25500,39647,'manual','A_OUTRAS_MARCAS|PRECO_MANUAL|BLOCO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='SP_MONTAGEM';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,35500);
  select id into v_reg from regioes where codigo='OUTROS_ES';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,36500);
  select id into v_reg from regioes where codigo='MG_RJ_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,37500);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53684','1381964','GRADE NIV CONT REM FIXA 48X22"X4,00 195 MM PN 750X16" 140 CV',(select id from marcas where nome='ALMEIDA'),null,28900,43730,'manual','A_OUTRAS_MARCAS|PRECO_MANUAL|BLOCO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='SP_MONTAGEM';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,39500);
  select id into v_reg from regioes where codigo='OUTROS_ES';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,41000);
  select id into v_reg from regioes where codigo='MG_RJ_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,42500);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('52247',null,'GRADE CIVEMASA GVPF 22X36¨450 MM 4 RODAS 2017',null,(select id from categorias where nome='USADOS'),0,0,'manual','B1_MS|SEM_CUSTO_TABELA|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,103990);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,103990);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,1);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values (null,null,'CHURRUMEIRA MEPEL 15 TON COMPLETA 400/60 SEM USO (CLIENTE)',null,(select id from categorias where nome='USADOS'),0,0,'manual','B1_MS|SEM_CUSTO_TABELA|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,79990);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,1);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('52647',null,'GRADE TATU 16X34"X 360 MM - REFORMADA DISCOS NOVOS',null,(select id from categorias where nome='USADOS'),0,0,'manual','B1_MS|SEM_CUSTO_TABELA|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,57990);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,1);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('52402',null,'GRADE BALDAN PESADA 14X34" ANO 2019 4 PNEUS SEMINOVA',null,(select id from categorias where nome='USADOS'),0,0,'manual','B1_MS|SEM_CUSTO_TABELA|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,44990);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,1);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('52457',null,'GRADE TATU PESADA 18X32" X 360 MM PNEUS 400/60 2019 SEMINOVA',null,(select id from categorias where nome='USADOS'),0,0,'motor','B1_MS|SEM_CUSTO_TABELA') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,65990);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='VENDA_DIRETA_MS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,1);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values (null,null,'TRATOR VALTRA A 124 ANO 2018 C/ 2400 HS (DE CLIENTE)',null,(select id from categorias where nome='TRATOR'),0,0,'manual','B1_MS|SEM_CUSTO_TABELA|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,219900);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,1);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53856','USADOS','26 - TERRACEADOR TATU 22X26" - TODOS DISCOS NOVOS',null,(select id from categorias where nome='USADOS'),0,null,'motor','B1_MS|SEM_CUSTO_TABELA') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,27900);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53625','USADOS','22 - TERRACEADOR TATU 16X26" (MUITO CONSERVADO)',null,(select id from categorias where nome='USADOS'),0,null,'motor','B1_MS|SEM_CUSTO_TABELA') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,25900);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('54201','USADOS','34 - CALCARTEADEIRA TATU DCA 5.500',null,(select id from categorias where nome='USADOS'),0,null,'manual','B1_MS|SEM_CUSTO_TABELA|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,18900);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('54200','USADOS','33 - GRADE PESADA TATU 14X32" COM PISTÃO (SEM REFORMA)',null,(select id from categorias where nome='USADOS'),0,null,'manual','B1_MS|SEM_CUSTO_TABELA|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,26900);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53859','USADOS','27 - GRADE INTERM BALDAN 18X28" ANO 2012 (ESTA RIO VERDE/MS)',null,(select id from categorias where nome='USADOS'),0,null,'motor','B1_MS|SEM_CUSTO_TABELA') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,24900);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('USADOS','USADOS','32A - SÓ UMA DAS PLANTADEIRAS 15X50 AVULSA DO CJ ABAIXO',null,(select id from categorias where nome='USADOS'),0,null,'manual','B1_MS|SEM_CUSTO_TABELA|PRECO_MANUAL|COD_DUPLICADO') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,185000);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('USADOS','USADOS','32 - CJ 2 PLANT TATU ULTRAFLEX 15X50 TITANIUM + TANDEM (CLIENTE)',null,(select id from categorias where nome='USADOS'),0,null,'motor','B1_MS|SEM_CUSTO_TABELA|COD_DUPLICADO') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,369000);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values (null,null,'FORRAGEIRA 1.2S S/ RODA E S/ CAMBÃO TELESCOPICO',null,(select id from categorias where nome='MENTA'),null,null,'manual','B1_MS|SEM_CUSTO_TABELA|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values (null,null,'FORRAGEIRA 1.2S FORT COM RODA',null,(select id from categorias where nome='MENTA'),61200,null,'manual','B1_MS|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values (null,null,'FORRAGEIRA 1.2S PREMIUM',null,(select id from categorias where nome='MENTA'),106500,null,'manual','B1_MS|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('54108',null,'VAGÃO MISTURADOR GIROMIX 6.O DUO C/ CHUPIM',null,(select id from categorias where nome='MENTA'),130000,null,'manual','B1_MS|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53918',null,'CIMAG PEC 600 COM BOMBA 3 PISTÕES E REABASTECEDOR',null,(select id from categorias where nome='PULV "CIMAG"'),8600,null,'manual','B1_MS|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,13990);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,12700);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,11900);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,12300);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,12700);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53919',null,'CIMAG PEC CROSS 2.000 COM 2 RODAS 24"',null,(select id from categorias where nome='PULV "CIMAG"'),29000,null,'manual','B1_MS|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,44990);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,42500);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,39500);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,41000);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,42500);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values (null,null,'CIMAG PEC CROSS 2.000 COM 4 RODAS TANDEM 14.4X24" (COMPRAR)',null,(select id from categorias where nome='PULV "CIMAG"'),34500,null,'manual','B1_MS|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,49990);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,49900);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,46900);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,48900);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,49900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53884',null,'CIMAG PEC 2.000 COM 4 RODAS TANDEM 16"',null,(select id from categorias where nome='PULV "CIMAG"'),28500,null,'manual','B1_MS|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,44490);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,41900);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,38900);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,40500);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,41900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('52017','119040025','PEK 600 TATU "PESADO" - 3 PONTO - 600 LITROS - BBA 75 L/MIN',null,(select id from categorias where nome='PULVERIZADOR'),null,null,'manual','B1_MS|SEM_CUSTO_TABELA|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,14990);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,13990);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53736','119040036','PEK 600 TATU "LEVE" - 3 PONTO - 600 LITROS - BBA 75 L/MIN',null,(select id from categorias where nome='PULVERIZADOR'),9353.15172,22187,'motor','B1_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,13900);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('52445','119040012','FALKI 600 - PULV 3 PONTOS - 600 LITROS E BARRAS 12 METROS',null,(select id from categorias where nome='PULVERIZADOR'),14949.360719999999,35462,'motor','B1_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,22590);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,21500);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,19900);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,21500);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('54165','120270077','CRO 2.0 (PEQUENO) SEM SULCADOR SEM KIT PULVERIZAÇÃO',null,(select id from categorias where nome='COMPOSTADOR'),35629.829639999996,84519,'manual','B1_MS|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,55990);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,54900);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,52900);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,54900);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,56900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('51341','120270075','CRO 2.0 (PEQUENO) COM SULCADOR SEM KIT PULVERIZAÇÃO',null,(select id from categorias where nome='COMPOSTADOR'),38919.26232,92322,'manual','B1_MS|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,60990);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,58900);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,55900);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,57900);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,59900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('54166','120270074','CRO 2.0 (PEQUENO) COM SULCADOR E COM KITS PULVER (COMPLETO)',null,(select id from categorias where nome='COMPOSTADOR'),60820.568999999996,144275,'manual','B1_MS|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,95990);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,89900);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,85900);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,88900);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,91900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('38384','120270072','CRO 4.0 CIVEMASA COM SULCADOR E COM KITS PULVERIZ (COMPLETO)',null,(select id from categorias where nome='COMPOSTADOR'),108797.46948,258083,'manual','B1_MS|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,169990);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,166900);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,153900);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,160900);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,172300);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('54085','120270042','CRO 4.0 CIVEMASA COM SULCADOR E SEM KITS PULVERIZAÇÃO',null,(select id from categorias where nome='COMPOSTADOR'),89310.85848,211858,'motor','B1_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,130990);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,128900);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,118900);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,128900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('54064','120270046','CRO 4.0 CIVEMASA SEM SULCADOR E SEM KITS PULVERIZAÇÃO',null,(select id from categorias where nome='COMPOSTADOR'),84328.01928,200038,'motor','B1_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,127990);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,123900);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,113900);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,123900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('50737','104010009','HID RC2 1500 TRANSMISSÃO "DIRETA" - 70 cv',null,(select id from categorias where nome='ROÇADEIRA'),11382.119999999999,27000,'manual','B1_MS|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,16500);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,15900);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,14900);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,15500);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,15900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('49058','104100032','HID RC2 1700 TRANSMISSÃO "DIRETA" - 80 cv',null,(select id from categorias where nome='ROÇADEIRA'),11831.0814,28065,'manual','B1_MS|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,17500);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,16900);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,15700);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,16300);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,16900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53911','104150007','HID 1300 KAPINA CLASSIC (MAIS LEVE) "DIRETA" - 60 CV',null,(select id from categorias where nome='ROÇADEIRA'),10162.546919999999,24107,'manual','B1_MS|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,14800);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,14400);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,13500);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,14000);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,14400);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53694','104150010','HID 1500 KAPINA CLASSIC (MAIS LEVE) "DIRETA" - 70 CV',null,(select id from categorias where nome='ROÇADEIRA'),10636,25393,'manual','B1_MS|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,15700);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,15200);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,14300);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,14800);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,15200);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53860','104150013','HID 1700 KAPINA CLASSIC (MAIS LEVE) "DIRETA" - 80 CV',null,(select id from categorias where nome='ROÇADEIRA'),11277,26296,'manual','B1_MS|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,16500);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,15900);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,14700);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,15350);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,15900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('51124','104010049','HID RO2  1500 TRANSMISSÃO "POR CORREIAS" - 70cv',null,(select id from categorias where nome='ROÇADEIRA'),13280,30984,'manual','B1_MS|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,19590);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,18700);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,17300);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,17900);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,18700);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('35409','104100049','HID RO2 1700 TRANSMISSÃO  "POR CORREIAS" - 80 cv',null,(select id from categorias where nome='ROÇADEIRA'),13690,31929,'motor','B1_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,19990);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,17900);
  select id into v_reg from regioes where codigo='SP_SP';
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,18500);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,19200);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('52223','104040045','HID RO2 2601 DUPLA C/ RODA GUIA 4 FACAS DESENTRADAS 90 cv',null,(select id from categorias where nome='ROÇADEIRA'),19340,45101,'manual','B1_MS|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,28300);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,27200);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,25300);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,26200);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,26700);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('37709','104040007','HID RO2 3101 DUPLA DESCENTRADA 4 FACAS - 100 cv',null,(select id from categorias where nome='ROÇADEIRA'),20660,48195,'motor','B1_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,29990);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,29300);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,26900);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,27900);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,29300);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('52974','104090022','ARRASTO SIMPLES ROAT 1700 (PEQUENA) A CARDAN - 70 cv',null,(select id from categorias where nome='ROÇADEIRA'),18170,42389,'manual','B1_MS|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,26500);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,25800);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,23900);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,24800);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,25800);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('40992','104090017','ARRASTO DUPLA ROAT 3400 ""SEM PNEUS"" - 90 cv',null,(select id from categorias where nome='ROÇADEIRA'),25410,59290,'manual','B1_MS|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,36990);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,35900);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,33900);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,34500);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,35500);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('52686','104090019','ARRASTO DUPLA ROAT 3400 TL COM  PNEUS DE TRANSPORTE',null,(select id from categorias where nome='ROÇADEIRA'),32470,75767,'manual','B1_MS|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,47500);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,45900);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,42500);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,44200);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,45900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('38035','105010027','PERF DE SOLO  **SEM BROCAS**  ( ESCOLHER AS BROCAS E SOMAR )',null,(select id from categorias where nome='PERFURADOR'),4840,11279,'manual','B1_MS|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,6500);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values (null,null,'BROCA DE 9" -   SOMAR AO PERFURADOR',null,(select id from categorias where nome='BROCA 9'),0,0,'motor','B1_MS|SEM_CUSTO_TABELA') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,1150);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values (null,null,'BROCA DE 12" - SOMAR AO PERFURADOR',null,(select id from categorias where nome='BROCA 12'),0,0,'motor','B1_MS|SEM_CUSTO_TABELA') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,1290);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values (null,null,'BROCA DE 18" - SOMAR AO PERFURADOR',null,(select id from categorias where nome='BROCA 18'),0,0,'motor','B1_MS|SEM_CUSTO_TABELA') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,1490);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('49061','407010053','TATU GATG 2000 BITOLA FIXA',null,(select id from categorias where nome='GUINCHO BAG'),20120,46924,'manual','B1_MS|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,24990);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,23900);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,22900);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,23500);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,23700);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('35678','407010050','CIVEMASA GCAG 2000  BITOLA REGUL',null,(select id from categorias where nome='GUINCHO BAG'),21350,49785,'manual','B1_MS|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,25990);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('35688','407010002','GAT 800 - GUINCHO 3 PONTO - 800 KG - SIMPLES',null,(select id from categorias where nome='GUINCHO-800'),1585,3759,'manual','B1_MS|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,2650);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('50483','407010001','GAT 1000 GUINCHO 3 PONTO C/ PISTÃO HIDRÁULICO',null,(select id from categorias where nome='GUINCHO 3 PO'),5940,13850,'manual','B1_MS|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,5990);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('52231','402010001','PLATAFORMA TRAZEIRA 500 KG 3 PONTO - SEM TAMPAS',null,(select id from categorias where nome='PLATAFORMA'),1830,4250,'manual','B1_MS|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,3290);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('37804','106060057','PLAINA TRAZEIRA 3 PONTO - PTL 2300 - 70 CV',null,(select id from categorias where nome='PLAININHA'),5220,11240,'motor','B1_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.40000);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('38805','106060001','LTA 3000 (PEQUENA) MECÂNICA COM PNEUS 600X16"',null,(select id from categorias where nome='PATROLINHA'),20110,46895,'manual','B1_MS|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,29990);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,28900);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,26900);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,27500);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,27900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('35687','106060006','LTA 5000 REVERSÃO MECANICA PNEUS 24" - 100 CV',null,(select id from categorias where nome='PATROLA'),29530,68861,'manual','B1_MS|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,42990);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,40700);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,38900);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,39900);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,40900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('47267','106060040','LTA 5000 REVERSÃO HIDRÁULICA C/ VALVULA REVERSORA MANUAL',null,(select id from categorias where nome='PATROLA'),33320,77708,'manual','B1_MS|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,48990);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,45700);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,43900);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,44900);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,45900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('106060048','106060048','LTA 5000 REVERSÃO HIDRÁULICA C/ VALVULA ELETRICA VEH',null,(select id from categorias where nome='PATROLA'),34540,80545,'motor','B1_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,49990);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('52212','106060031','LTA 5000 REVERSÃO HIDRÁULICA - COMANDO TRIPLO - 3 VCR',null,(select id from categorias where nome='PATROLA'),32740,76364,'manual','B1_MS|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,47990);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,46900);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,42900);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,43900);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,45500);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('106060044','106060044','LTA 5000 "S PESADA" PNEUS 26" - COMANDO TRIPLO - 120 CV',null,(select id from categorias where nome='PATROLA'),55120,128552,'motor','B1_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('40756','106060049','LTA 5.000 “S” PESADA PNEUS 26” COM VALVULA VEH - 120 CV',null,(select id from categorias where nome='PATROLA'),56920,132750,'motor','B1_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('52103','107030006','PAT-H 320 CONCHA TRAZEIRA 3 PONTO C/ PISTÃO',null,(select id from categorias where nome='CONCHINHA'),null,null,'manual','B1_MS|SEM_CUSTO_TABELA|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,6990);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('51383','107020258','CONCHA PAH AVULSA 1200 MM C/ VÁLV PD PLAINA DIANT (*NA TRC*)',null,(select id from categorias where nome='CONCHA PD'),6490,15135,'manual','B1_MS|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,10500);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,9900);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,8900);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,9300);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,9700);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('52209','511046453','CONCHA PAC AVULSA 1700 MM P/ CONJ PCA  C/ ENGATE PINO ANTIGO',null,(select id from categorias where nome='CONCHA PCA'),4170,9718,'manual','B1_MS|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,8200);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53823','531044018','CONCHA PAC AVULSA 1700 MM P/ CONJ PCA  C/ ENGATE RÁPIDO',null,(select id from categorias where nome='CONCHA PCA'),3340,7788,'manual','B1_MS|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,7900);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('52676','501048045','CONCHA PAC AVULSA 1900 MM P/ CONJ PCA  C/ ENGATE PINO ANTIGO',null,(select id from categorias where nome='CONCHA PCA'),5290,12315,'manual','B1_MS|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,8900);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53248','521045475','SUPORTE PARA BAG DO CONJ  PCA C/ "ENGATE RÁPIDO + NOVO"',null,(select id from categorias where nome='SAB BAG'),4155,9689,'manual','B1_MS|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,6990);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('54061','531042232','SUPORTE PARA BAG DO CONJ  PCA C/ "ENGATE PINO  + ANTIGO"',null,(select id from categorias where nome='SAB BAG'),4229,9860,'manual','B1_MS|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,7190);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('52918','102590004','ROLO FACA CICLUS 3000  COM 1 ROLO DE FACAS',null,(select id from categorias where nome='ROLO FACA'),42520,99168,'motor','B1_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('102590001','102590001','ROLO FACA CICLUS 7000 COM 3 ROLOS DE FACAS',null,(select id from categorias where nome='ROLO FACA'),136520,318432,'motor','B1_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('52309','102590002','ROLO FACA CICLUS 9000  COM 3 ROLOS DE FACAS',null,(select id from categorias where nome='ROLO FACA'),153500,358018,'motor','B1_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,221900);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,199900);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,209900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('35445','113010018','RASPADOR "SCRAPER" 3.0 C/ PNEUS NOVOS - 110 CV',null,(select id from categorias where nome='SCRAPER'),32900,76719,'motor','B1_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('35990','120370221','SUBSOL 9 H STAC-L 450 COMPL - 180 cv',null,(select id from categorias where nome='SUBSOLADOR'),58460,136354,'motor','B1_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('52006','101100091','AIVECAS FIXO AAH 4 HASTES C/ RODA GUIA - 105- 120 CV',null,(select id from categorias where nome='ARADO AIVECA'),12260,28592,'motor','B1_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('42099','120630003','ARADO AIVECAS AACRM 5 HASTES REVERS 180 CV',null,(select id from categorias where nome='ARADO AIVECA'),null,null,'motor','B1_MS|SEM_CUSTO_TABELA') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,47990);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('51018','115010032','TCA 10.500  MULTIUSO COM 2 PNEUS 30"                     *LIQUIDAÇÃO FN*',null,(select id from categorias where nome='GRANELEIRA'),79383.0555,176211,'motor','B1_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.40000);
  select id into v_reg from regioes where codigo='SP_SP';
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.35000);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('41985','109090145','DCA 1200-LA LONGO ALCANÇE  - 3 PONTO AC CABO',null,(select id from categorias where nome='ADUBADEIRA'),null,null,'manual','B1_MS|SEM_CUSTO_TABELA|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,15990);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53628','109120039','ATRIUM 1.250 DUPLO LONGO ALCANÇE C/ ACIONAM HIDRÁULICO',null,(select id from categorias where nome='ADUBADEIRA'),null,null,'manual','B1_MS|SEM_CUSTO_TABELA|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,18990);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('52387','109120045','ATRIUM 1.500 DUPLO LONGO ALCANÇE C/ ACIONAM HIDRÁULICO',null,(select id from categorias where nome='ADUBADEIRA'),15698,36608,'manual','B1_MS|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,22990);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,22300);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,20700);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,21300);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,22300);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('51942','109090053','DCA2 2.500 CARDAN 1 EIXO PNEUS 750X16" EST 500',null,(select id from categorias where nome='CALCAREADEIRA'),23860,55647,'motor','B1_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('35656','109090023','DCA2  5.500 CARDAN PNEUS 11L15 EST 500 - 80 CV',null,(select id from categorias where nome='CALCAREADEIRA'),30103,71409,'motor','B1_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,41900);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('35773','109090019','DCA2 7.500 CARDAN PNEUS  11L15 EST 500 - 80 CV',null,(select id from categorias where nome='CALCAREADEIRA'),33090,77172,'motor','B1_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,45300);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('50697','109090047','DCCO (LARGA) 7.500 CARDAN PNEUS 11L15 EST 800 - 90 CV',null,(select id from categorias where nome='CALCAREADEIRA'),36110,84222,'motor','B1_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('52219','109090412','DCA  6.000 "INOX" HIDRÁULICA EST 500 PN 11L15 80 CV',null,(select id from categorias where nome='CALCAREADEIRA'),34590,80656,'motor','B1_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,50990);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,49900);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,45900);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,46900);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,47900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('51092','109090445','DCA  8.000 "INOX" ACION CARDAN EST 500 PN 11L15 - 90 CV',null,(select id from categorias where nome='CALCAREADEIRA'),38560,89924,'manual','B1_MS|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,56990);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,53700);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,50900);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,51900);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,53900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('51096','109090458','DCA  8.000 "INOX" HIDRÁULICA EST 500 PN 11L15 - 90 CV',null,(select id from categorias where nome='CALCAREADEIRA'),41190,96067,'motor','B1_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,60590);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,58900);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,54900);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,55900);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,57900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53667','109090478','DCCO (LARGA) 8.000 "INOX" CARDAN EST 800 PN 11L15 - 90 CV',null,(select id from categorias where nome='CALCAREADEIRA'),42103,98181,'manual','B1_MS|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,62990);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,59900);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,55900);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,56900);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,59500);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('51122','109090367','DCCO (LARGA) 8.000 "INOX" HIDRÁULICA EST 800 PN 11L15 - 90 CV',null,(select id from categorias where nome='CALCAREADEIRA'),44670,104185,'motor','B1_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('50694','109090215','DCA2 10.500 HIDRÁULICA PNEUS 24" EST 500 - 110 CV',null,(select id from categorias where nome='CALCAREADEIRA'),57890,134779,'motor','B1_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('50738','109090049','DCA2 10.500 CARDAN PNEUS 24" EST 500 - 110 CV',null,(select id from categorias where nome='CALCAREADEIRA'),54830,127869,'motor','B1_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('42028','109090331','DCCO (LARGA) 10.500 HIDRÁUL PNEUS 24” EST 800 PN 400/60 - 110 CV',null,(select id from categorias where nome='CALCAREADEIRA'),58830,137195,'motor','B1_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('51097','109090457','DCA 11.000 "INOX" CARDAN EST 500 - 110 CV',null,(select id from categorias where nome='CALCAREADEIRA'),58940,137469,'motor','B1_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,81000);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('51093','109090490','DCA 11.000 "INOX" HIDRÁULICA EST 500 - 110 CV',null,(select id from categorias where nome='CALCAREADEIRA'),62070,144743,'motor','B1_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('51113','109090498','DCCO (LARGA) 11.000 "INOX" HIDRÁULICA  EST 800 - 110 CV',null,(select id from categorias where nome='CALCAREADEIRA'),65200,152054,'motor','B1_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53144','109090682','DCA 11.000 "INOX" ACIO HIDR EST TRAV ""BITOLA REGULÁVEL 3,30 M""',null,(select id from categorias where nome='CALCAREADEIRA'),77840,181551,'motor','B1_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('51130','109090694','DCA 12T "TATU" ISOBUS SEM TELA - BIT 3,30 M   (TELA CONSULTAR)',null,(select id from categorias where nome='CALCAREADEIRA'),189650,442351,'manual','B1_MS|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,274900);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,269900);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,248900);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,254900);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,261900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('49741','121740061','DCA 15T "CIVEMASA" ISOBUS SEM TELA - BIT 3,30  (TELA CONSULTAR)',null,(select id from categorias where nome='CALCAREADEIRA'),203480,474594,'motor','B1_MS|') returning id into v_prod;
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('51316','109090520','DCA 15 T TATU "TAXA VARIÁVEL  COMP COM TELA       *LQ REFATURAM*',null,(select id from categorias where nome='CALCAREADEIRA'),239170,514240,'manual','B1_MS|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,329750);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,311900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('35770','120810009','TCL 16X26 – 110 CV',null,(select id from categorias where nome='TERRACEADOR'),39032,91018,'motor','B2_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('35771','120810010','TCL 18X26 – 125 CV',null,(select id from categorias where nome='TERRACEADOR'),41806,97490,'motor','B2_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('37229','120810012','TCL 20X26 - 140 CV',null,(select id from categorias where nome='TERRACEADOR'),45494,106087,'motor','B2_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('37707','120810007','TCL 22X26 - 150 CV',null,(select id from categorias where nome='TERRACEADOR'),46737,108989,'motor','B2_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('37759','120810013','TCL 24X26 - 160 cv',null,(select id from categorias where nome='TERRACEADOR'),48283,112592,'motor','B2_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('37978','120140058','TC 30 E 30X26 - 190 CV  (TERRAÇO EMBUTIDO)',null,(select id from categorias where nome='TERRACEADOR'),131725,307173,'manual','B2_MS|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,192990);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,188900);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,173900);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,178900);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,183900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('50480','120140062','TC2 30X28 - 210 CV',null,(select id from categorias where nome='TERRACEADOR'),132262,308425,'motor','B2_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,193990);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,189900);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,174900);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,179900);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,184900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('36113','120140063','TC2 34X28 – 230 CV',null,(select id from categorias where nome='TERRACEADOR'),135548,316087,'motor','B2_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,197990);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,193900);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,178900);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,183900);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,189900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('41299','120140059','TC2 40X28X6,00 MM  – 320 CV - ABERTURA HIDRAULICA',null,(select id from categorias where nome='TERRACEADOR'),162993,380089,'motor','B2_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,238990);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,233900);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,214900);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,219900);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,227900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('44687','120140064','TC2 48X28X6,00 MM  – 370 CV - ABERTURA HIDRÁULICA',null,(select id from categorias where nome='TERRACEADOR'),185183,431832,'motor','B2_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,269990);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,263900);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,243900);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,249900);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,256900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('52007','102130549','GNL 28X20 - 170 MM "DM" SEM PNEUS – 70 CV',null,(select id from categorias where nome='NIVELADORA'),12580,29319,'motor','B2_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,18990);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,18300);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,16900);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,17500);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,17900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('51679','102130558','GNL 32X20 - 170 MM "DM" SEM PNEUS',null,(select id from categorias where nome='NIVELADORA'),14570,33697,'manual','B2_MS|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,19990);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,20900);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,19500);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,19900);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,20500);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('51123','102130560','GNL 32X22 - 170 MM "DM" SEM PNEUS  - 75 CV',null,(select id from categorias where nome='NIVELADORA'),15040,35071,'manual','B2_MS|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,21990);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,21500);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,19900);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,20500);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,20900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('49658','102130563','GNL 36X20 - 170 MM "GRAXA" SEM PNEUS S/ PISTÃO – 80 CV',null,(select id from categorias where nome='NIVELADORA'),15461.16,34320,'motor','B2_MS||COD_DUPLICADO') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('49658','102130564','GNL 36X20 - 170 MM "DM" SEM PNEUS – 80 CV',null,(select id from categorias where nome='NIVELADORA'),15440,36006,'manual','B2_MS|PRECO_MANUAL|COD_DUPLICADO') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,22500);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,21900);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,20500);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,20900);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,21500);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53511','102130573','GNL 36X20 - 170 MM "DM" SEM PNEUS  **COM PISTÃO ABERT**',null,(select id from categorias where nome='NIVELADORA'),17640,41126,'manual','B2_MS|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,25990);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,24900);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,23500);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,23900);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,24500);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53515','102130567','GNL 36X22 - 170 MM "DM" SEM PNEUS - 80 CV',null,(select id from categorias where nome='NIVELADORA'),16050,37424,'manual','B2_MS|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,23590);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,22900);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,21500);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,21900);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,22500);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('102130635','102130635','GNL 36X22  - 170 MM "DM" SEM PNEUS - 80 CV **COM PISTÃO ABERT**',null,(select id from categorias where nome='NIVELADORA'),18080,42170,'manual','B2_MS|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,26990);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,25900);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,23900);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,24500);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,24900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('51649','102490003','GNCR-S 36X22 - CONTROLE REMOTO FIXA  - MT DMO 175 MM - 90 CV',null,(select id from categorias where nome='NIVELADORA'),31490,73428,'motor','B2_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53577','102490004','GNCR-S 40X22 - CONTROLE REMOTO FIXA - MT DMO 175 MM - 110 CV',null,(select id from categorias where nome='NIVELADORA'),35240,82193,'motor','B2_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('35454','102130569','GNL 42X20 - 170 MM  "DM" DISCOS MISTOS  – 90 CV',null,(select id from categorias where nome='NIVELADORA'),17510,40833,'manual','B2_MS|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,25500);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,24900);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,22900);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,23500);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,24500);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('35899','102490005','GNCR-S 44X22 - CONTROLE REMOTO FIXA - MT DMO 175 MM - 125 CV',null,(select id from categorias where nome='NIVELADORA'),36410,84903,'motor','B2_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('38450','102120237','GNM 44X22 - INTEIRIÇA DM 195 MM C/ PNEUS C/ PISTÃO - 110 CV',null,(select id from categorias where nome='NIVELADORA'),34040,79379,'motor','B2_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('54087','102110281','GN 44X22"X4,50 MM DR DM C/ PISTÃO ABERTURA - S/ PN - 195 MM',null,(select id from categorias where nome='NIVELADORA'),26320,62434,'manual','B2_MS|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,39590);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,37900);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,34900);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,36500);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,37500);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53862','102110440','GN 44X20 - ESPAÇ 195 MM MT DM S/ PISTÃO S/ PNEUS',null,(select id from categorias where nome='NIVELADORA'),24625,57425,'motor','B2_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53861','102110238','GN 48X20 - ESPAÇ 195 MM DR DM S/ PISTÃO S/ PNEUS',null,(select id from categorias where nome='NIVELADORA'),25505,59481,'motor','B2_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('38451','102120193','GNM 48X22X3,50MT DM  - INTEIRIÇA 195 C/ PNEUS C/ PISTÃO – 125 CV',null,(select id from categorias where nome='NIVELADORA'),33463,80571,'manual','B2_MS|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,48990);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,47900);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,43900);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,44900);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,46500);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53582','102330246','GNFM 48X22 - 195 MM PANT DM C/ PISTÃO E PNEUS',null,(select id from categorias where nome='NIVELADORA'),39673,92516,'motor','B2_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('36440','120660091','GDFM 52X22 - 195 MM DM PANT C/ PNEUS C/ PISTÃO - 140 CV',null,(select id from categorias where nome='NIVELADORA'),43260,100879,'motor','B2_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53326','102120199','GNM 52X22X3,50 MT DM - INTEIRIÇA 195 C/ PNEUS C/ PISTÃO – 130 CV',null,(select id from categorias where nome='NIVELADORA'),34676,82257,'manual','B2_MS|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,50990);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,49500);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,46900);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,46900);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,48500);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('35798','102490007','GNCR-S 52X22 - CONTROLE REMOTO FIXA - MT DMO 175 MM - 150 CV',null,(select id from categorias where nome='NIVELADORA'),40010,93393,'motor','B2_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('37784','120660070','GDFM 56X22 - 195 MM DM MT PANT C/ PNEUS C/ PISTÃO - 150 CV',null,(select id from categorias where nome='NIVELADORA'),43810,102177,'motor','B2_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('102490008','102490008','GNCR-S 56X22 - CONTROLE REMOTO FIXA - MT DMO 175 MM - 180 CV',null,(select id from categorias where nome='NIVELADORA'),46519,108477,'motor','B2_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,67990);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,65900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('37169','120450029','GDCDH 56X22 - CONT REM "ARTICULADA" DMO - 180 CV',null,(select id from categorias where nome='NIVELADORA'),54380,126825,'motor','B2_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('38361','120660077','GDFM 60X22 - 195 MM DM DR PANT C/ PNEUS C/PISTÃO - 160 CV',null,(select id from categorias where nome='NIVELADORA'),45392,105858,'motor','B2_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('47972','1218000133','GDFH 64X22 - 195 MM DM DR PANT C/ PNEUS  C/ PISTÃO - 170 CV',null,(select id from categorias where nome='NIVELADORA'),63790,148780,'motor','B2_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53330','120900164','GDMC 68X24 - INTEIRIÇA C/ PNEUS PISTÃO',null,(select id from categorias where nome='NIVELADORA'),60630,142035,'motor','B2_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('50083','121800080','GDFH 72X22 - 195 MM DMO MT PANT C/ PNEU HID C/ PA 180 CV',null,(select id from categorias where nome='NIVELADORA'),65920,153741,'motor','B2_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,90800);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('51521','121800078','GDFH 72X24 - 195 MM DMO TODOS DISCOS RECORT PA 190 CV',null,(select id from categorias where nome='NIVELADORA'),67830,158191,'motor','B2_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('45759','121800106','GDFH 84X22 - 195 MM DMO PANT MT C/ PNEU HID C/ PA 220 CV',null,(select id from categorias where nome='NIVELADORA'),75110,175183,'motor','B2_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('51614','121800105','GDFH 84X24 - 195 MM DMO PANT MT C/ PNEU HID C/ PA - 230 CV',null,(select id from categorias where nome='NIVELADORA'),77710,181250,'motor','B2_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,107100);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53228','121800159','GDFH 108X24 - 195 MM DMO PANT C/ PNEUS HID C/ PA - 280 A 320',null,(select id from categorias where nome='NIVELADORA'),106360,248075,'motor','B2_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('42759','120090089','SNC-P 108X22 -  CONTR REMOTO ARTICULADA - 300 CV',null,(select id from categorias where nome='NIVELADORA'),161430,376488,'motor','B2_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('40871','102440190','ATCRL 14X26”X6,00 - 230 MM DM 1.1/2" PN 600X16” – 85 CV',null,(select id from categorias where nome='ARADORA 230'),24070,56135,'motor','B2_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,1.03308);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,33900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53735','102440495','ATCRL 14X26”X6,00 - 230 MM CM (A GRAXA) 1.1/2" PN 600X16” 85 CV',null,(select id from categorias where nome='ARADORA 230'),23720,55319,'motor','B2_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53442','102440672','ATCRL 16X26"X6,00 - 230 MM DMO 1.1/2'' PN 600X16" - 90 CV',null,(select id from categorias where nome='ARADORA 230'),26590,62003,'motor','B2_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53336','102440673','ATCRL 18X26"X6,00 - 230 MM DMO 1.1/2" PN 750X16 - 105 CV',null,(select id from categorias where nome='ARADORA 230'),28990,67612,'motor','B2_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('35809','102260116','GAICR PESADA 14X28”X6,00 - 270 MM PNEUS 600X16” – 95 CV',null,(select id from categorias where nome='INTERMEDIÁRIA'),26990,62946,'motor','B2_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53438','102260869','GAICRL 14X28"X6,00 - 270 MM PNEUS 600X16 - 90 CV',null,(select id from categorias where nome='INTERMEDIÁRIA'),25436,60337,'manual','B2_MS|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,37990);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,36300);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,33400);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,34200);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,36800);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('35411','102260500','GAICRL 16X28”X6,00 - 270 MM PNEUS 600X16 – 100-110 CV',null,(select id from categorias where nome='INTERMEDIÁRIA'),29259,69406,'motor','B2_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,43590);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,41900);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,38500);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,39500);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,42400);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('35412','102260502','GAICRL 18X28”X6,00 - 270 MM PNEUS 750X16” – 110-120 CV',null,(select id from categorias where nome='INTERMEDIÁRIA'),32020,75956,'motor','B2_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('35446','102260518','GAICRL 20X28"X6,00 - 270 MM PNEUS 750X16" 120-130 CV',null,(select id from categorias where nome='INTERMEDIÁRIA'),33290,77641,'motor','B2_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,48940);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('39897','102260545','GAICRL 22X28"X6,00 - 270 MM PNEUS 750X16" 140-150 CV',null,(select id from categorias where nome='INTERMEDIARIA'),34490,80431,'motor','B2_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('35853','102260689','GAICRL 24X28”X6,00 - 270 MM PNEUS 750x16" – 150-160 CV',null,(select id from categorias where nome='INTERMEDIÁRIA'),35630,83094,'motor','B2_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,49900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('35435','102260121','GAICR 28X28”X6,00 - 270 MM DM PN 750 x 16" – 180 CV',null,(select id from categorias where nome='INTERMEDIÁRIA'),40683,96506,'motor','B2_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('41872','102262406','GAICR 30X28"X6,00 - 270 MM PNEUS 750X16" - 200 CV',null,(select id from categorias where nome='INTERMEDIÁRIA'),45100,105183,'motor','B2_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('51369','102460309','GAICR 300 - 30X30"X7,50 - 300 MM 4 PNEUS - 220 CV',null,(select id from categorias where nome='INTERMEDIARIA'),60140,140274,'motor','B2_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('37758','121140176','SIC 32X28"X 6,00 - 270 MM DM - PNEUS 400/60 230 CV',null,(select id from categorias where nome='INTERMEDIÁRIA'),68902,156441,'motor','B2_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('36481','121140167','SIC 36X28"X 7,50 - 270 MM - 1.5/8 DMO PNEUS 400/60 - 250 CV',null,(select id from categorias where nome='INTERMEDIARIA'),74230,173122,'motor','B2_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('121140119','121140119','SIC 40X28"X 7,50 MM - 1.5/8" DM PN 400/60',null,(select id from categorias where nome='INTERMEDIARIA'),79588,179819,'motor','B2_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('41886','120070096','SAC 48X30"X 7,50 MM - 270 MM C/ PNEUS 400/60 - 300 CV',null,(select id from categorias where nome='INTERMEDIARIA'),103690,241818,'motor','B2_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('50744','102060433','GAPCR 12X32” 340 MM DMO CONT REM 11L15 - 125 CV - TATU',null,(select id from categorias where nome='PESADA'),47292,110281,'motor','B3_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('35768','102060444','GAPCR 14X32" 340 MM DMO CONT REM 11L15 - 150 CV - TATU',null,(select id from categorias where nome='PESADA'),50417,117567,'manual','B3_MS|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,72990);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,70900);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,65900);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,66900);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,68900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('51202','102060443','GAPCR 14X34" 340 MM DMO CONT REM 11L15 - 160 CV - TATU',null,(select id from categorias where nome='PESADA'),51650,120453,'motor','B3_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('35772','102060458','GAPCR 16X32” 340 MM DMO CONT REM 11L15 - 180 CV - TATU',null,(select id from categorias where nome='PESADA'),55288,128928,'manual','B3_MS|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,79990);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,77900);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,71900);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,73900);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,75900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('50775','102060452','GAPCR 16X34" 340 MM DMO CONT REM 11L15 - 190 CV - TATU',null,(select id from categorias where nome='PESADA'),56586,131955,'motor','B3_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,81990);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,79900);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,73900);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,74900);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,77500);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('50288','120150033','SGAC 16X34” 360 MM DM CONT REM PN 11L15 - 200 CV - CIVEMASA',null,(select id from categorias where nome='PESADA'),61270,142893,'motor','B3_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,88590);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,86900);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,79900);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,81900);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,83900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('52479','102060469','GAPCR 18X34" 340 MM DMO CONT REM  ROD DUPLO - 200 - TATU',null,(select id from categorias where nome='PESADA'),63532,148151,'manual','B3_MS|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,91900);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,89900);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,81900);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,84900);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,87900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('36103','120150041','SGAC 18X34” 360 MM DM 11L15 – 220 CV - CIVEMASA',null,(select id from categorias where nome='PESADA'),64560,150055,'motor','B3_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,87990);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,90900);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,83900);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,85900);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,88900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('49067','102060616','GAPCR 18X34” 360 MM DMO  11L15 – 220 CV - TATU',null,(select id from categorias where nome='PESADA'),67220,156768,'motor','B3_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,87990);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,94900);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,87500);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,89500);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,92900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53417','102050233','GAPM 20X32" 340 MM DMO ARRASTO C/ PISTÃO - 190 CV',null,(select id from categorias where nome='PESADA'),50790,118454,'manual','B3_MS|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,69990);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('49633','102060412','GAPCR 20X34” 340 MM DMO - ROD DUPLA – 230  CV  - TATU',null,(select id from categorias where nome='PESADA'),79453,185277,'motor','B3_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,114990);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,111900);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,102900);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,104900);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,107900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('39947','120040052','GVMF 20X34” 360 MM CH TRIPLO DM PN 400/60 - 250 CV - CIVEMASA',null,(select id from categorias where nome='PESADA'),90225,210396,'motor','B3_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('39961','120040051','GVMF 22X34" 360 MM CH TRIPLO DM PN 400/60 - 270 CV   (MATÃO)',null,(select id from categorias where nome='PESADA'),92600,215955,'motor','B3_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('49101','102060400','GAPCR 24X34”X9,00 MM 340 MM DMO - ROD DUPLO - 260 CV - TATU',null,(select id from categorias where nome='PESADA'),84180,196301,'motor','B3_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53321','102060464','GAPCR 28X34"X9,00 MM 340 MM DMO - ROD DUPLO - 290 CV - TATU',null,(select id from categorias where nome='PESADA'),91494,213356,'motor','B3_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53580','102060611','GAPCR 28X34"X9,00 MM 340 MM DMO - PN 400/60 - 290 CV - TATU',null,(select id from categorias where nome='PESADA'),105850,246862,'motor','B3_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,139900);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,149900);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('40224','120040050','GVMF 28X34”X9,00 MM  360 MM DM CH TRIPLO - 400/60  – CIVEMASA',null,(select id from categorias where nome='PESADA'),105860,246909,'motor','B3_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('44714','102090590','GASPCR TATU 12X36"X12,00 440 MM DMO PN 900X20 - 200 CV',null,(select id from categorias where nome='SUPER PESADA'),75385,175791,'manual','B3_MS|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,108990);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,106900);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,98500);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,100900);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,103900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('44680','102090594','GASPCR TATU 14X36”X12,00 440 MM DMO PN 900X20 - 225 CV',null,(select id from categorias where nome='SUPER PESADA'),79760,185996,'motor','B3_MS||COD_DUPLICADO') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,114990);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,112900);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,103900);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,105900);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,109900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('43632','102090581','GASPCR TATU 16X36”X12,00 440 MM DMO PN 900X20 - 250 CV',null,(select id from categorias where nome='SUPER PESADA'),91083,212401,'manual','B3_MS|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,131990);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,128900);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,118900);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,121900);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,124900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('44677','102090554','GASPCR TATU 18X36"X12,00 440 MM DMO PN 900X20 - 270 CV',null,(select id from categorias where nome='SUPER PESADA'),94832,221141,'manual','B3_MS|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,136990);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,133900);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,123900);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,126500);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,129900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('49068','102090560','GASPCR TATU 20X36"X12,00 440 MM DMO PN 900X20 - 290 CV',null,(select id from categorias where nome='SUPER PESADA'),98730,230232,'motor','B3_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,142990);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,139900);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,128900);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,131900);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,135900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('39012','102090575','GASPCR TATU 22X36"X12,00 440 MM DMO PN 900X20 - 320 CV',null,(select id from categorias where nome='SUPER PESADA'),102449,238902,'motor','B3_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,147990);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,140500);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,133900);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,136900);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,140900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('42753','120020136','GVPF 22X36"X12,00 MM DMO 450 MM 4 PN 750X16 - 320',null,(select id from categorias where nome='SUPER PESADA'),118420,276199,'motor','B3_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('53003','120020253','GVPF 22X38"X12,00 MM DMO 450 MM PN 400/60 - 330 CV',null,(select id from categorias where nome='SUPER PESADA'),119292,278179,'motor','B3_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('50942','120020227','GVPF 24X36"X12 MM 450 DMO MM PN 900X20" - 370 CV',null,(select id from categorias where nome='SUPER PESADA'),137130,319832,'motor','B3_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('50943','120020232','GVPF 26X36"X12 MM 450 DMO MM PN 900X20" 400 CV',null,(select id from categorias where nome='SUPER PESADA'),139400,325121,'motor','B3_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('51216','120020237','GVPF 26X38"X12 MM 450 DMO MM PN ALTA FLUT 400',null,(select id from categorias where nome='SUPER PESADA'),149360,348345,'motor','B3_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('51354','121510219','CIVEMASA GASPCRC EHD 12X42”X12,00 DMO 2.3/4" 507 MM - 290 CV',null,(select id from categorias where nome='EXTRA PESADA'),115850,270149,'motor','B3_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,167990);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,164900);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,151900);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,155900);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,159900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('44595','102090383','TATU  GASPCR EHD 14X42"X12,00 DMO 2.3/4"',null,(select id from categorias where nome='EXTRA PESADA'),116650,271995,'manual','B3_MS|PRECO_MANUAL|COD_DUPLICADO') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,168990);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,158000);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,150900);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,154900);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,158900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('44595','121510223','CIVEMASA GASPCRC EHD 14X42"X12,00 DMO 2.3/4',null,(select id from categorias where nome='EXTRA PESADA'),116650,271995,'manual','B3_MS|PRECO_MANUAL|COD_DUPLICADO') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,169990);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,159000);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,151900);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,155900);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,159900);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('44576','121510249','CIVEMASA GASPCRC EHD 16X42”X12,00 DMO 2.3/4"',null,(select id from categorias where nome='EXTRA PESADA'),155350,362302,'motor','B3_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('44371','121510263','CIVEMASA GASPCRC EHD 18X42"X12,00 DMO 2.3/4" 507 MM - 450 CV',null,(select id from categorias where nome='EXTRA PESADA'),160170,373568,'motor','B3_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('44680','121510260','CIVEMASA GASPCRC EHD 20X42"X12,00 DMO 2.3/4" 507 MM - 500 CV',null,(select id from categorias where nome='EXTRA PESADA'),163900,382254,'motor','B3_MS||COD_DUPLICADO') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('49595','121510255','CIVEMASA GASPCRC EHD 22X42”X12,00 DMO 2.3/4" 507 MM - 500 CV',null,(select id from categorias where nome='EXTRA PESADA'),175600,409542,'motor','B3_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  select id into v_reg from regioes where codigo='MS_ANDREI';
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.31000);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('49601','111260594','PST TRIO FLEX 17X45 TITANIUM (DA PARA FAZER 15X50) 11/2025',null,(select id from categorias where nome='PLANTADEIRA'),929827,398615,'manual','B3_MS|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='VENDA_DIRETA_MS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,449000);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_OUTROS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  select id into v_reg from regioes where codigo='SP_RJ_MG_SUL';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,0);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('49045','111181026','ULTRAFLEX 15X500 DC20+CSU+MH+CI+SPCRR+SIG           *LIQUIDAÇÃO*',null,(select id from categorias where nome='PLANTADEIRA'),0,668776,'manual','B3_MS|PRECO_MANUAL') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_DDOS';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,349990);
  select id into v_reg from regioes where codigo='SP_SP';
  insert into produto_preco_manual (produto_id,regiao_id,preco) values (v_prod,v_reg,1);
  insert into produtos (codigo,codigo_fabrica,descricao,marca_id,categoria_id,custo_atual,tabela_bruta,tipo_preco,origem_import)
    values ('49640','111260569','PST TRIO 15X500 TITANIUM COMPLETA S/ PM 400     *DEMONSTRAÇÃO*',null,(select id from categorias where nome='PLANTADEIRA'),384000,844256,'motor','B3_MS|') returning id into v_prod;
  select id into v_reg from regioes where codigo='MS_ANDREI';
  insert into produto_indice_regiao (produto_id,regiao_id,indice) values (v_prod,v_reg,0.30000);
end $$;


-- >>>>>>>>>> 0004_audit_rls.sql <<<<<<<<<<

-- =====================================================================
-- 0004_audit_rls.sql — Auditoria (quem/quando/o que mudou) + RLS
-- Fecha a Fase 1. Segurança no banco, nunca só no frontend (seção 30).
-- =====================================================================

-- ---------------------------------------------------------------------
-- AUDITORIA: log genérico de alterações em entidades sensíveis
-- ---------------------------------------------------------------------
create table if not exists audit_logs (
  id           bigint generated always as identity primary key,
  usuario_id   uuid,                       -- auth.uid() no momento
  acao         text not null,              -- INSERT | UPDATE | DELETE
  entidade     text not null,              -- nome da tabela
  registro_id  text,                       -- id do registro afetado
  valor_anterior jsonb,
  valor_novo     jsonb,
  created_at   timestamptz not null default now()
);
create index if not exists idx_audit_entidade on audit_logs(entidade, created_at desc);
create index if not exists idx_audit_usuario  on audit_logs(usuario_id, created_at desc);

create or replace function fn_audit()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_id text;
begin
  v_id := coalesce( (to_jsonb(coalesce(new,old))->>'id'), null );
  insert into audit_logs (usuario_id, acao, entidade, registro_id, valor_anterior, valor_novo)
  values (
    auth.uid(), tg_op, tg_table_name, v_id,
    case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) end,
    case when tg_op in ('UPDATE','INSERT') then to_jsonb(new) end
  );
  return coalesce(new, old);
end $$;

-- anexa auditoria às tabelas críticas
do $$
declare t text;
begin
  foreach t in array array[
    'produtos','regioes','filiais','componentes_preco',
    'produto_indice_regiao','produto_preco_manual','config_precificacao','profiles'
  ] loop
    execute format('drop trigger if exists trg_audit_%1$s on %1$s;', t);
    execute format('create trigger trg_audit_%1$s after insert or update or delete on %1$s
                    for each row execute function fn_audit();', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- RLS — Row Level Security
-- Regra geral: LEITURA para qualquer usuário autenticado (catálogo);
-- ESCRITA apenas para admin. profiles tem regra própria.
-- (Migrations rodam como owner e ignoram RLS — o seed continua válido.)
-- ---------------------------------------------------------------------
alter table profiles                enable row level security;
alter table regioes                 enable row level security;
alter table filiais                 enable row level security;
alter table marcas                  enable row level security;
alter table categorias              enable row level security;
alter table produtos                enable row level security;
alter table componentes_preco       enable row level security;
alter table config_precificacao     enable row level security;
alter table produto_indice_regiao   enable row level security;
alter table produto_preco_manual    enable row level security;
alter table audit_logs              enable row level security;

-- profiles: cada um lê o próprio; admin lê todos; admin gerencia todos
drop policy if exists profiles_select on profiles;
create policy profiles_select on profiles for select to authenticated
  using (id = auth.uid() or is_admin());
drop policy if exists profiles_update_self on profiles;
create policy profiles_update_self on profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());
drop policy if exists profiles_admin_all on profiles;
create policy profiles_admin_all on profiles for all to authenticated
  using (is_admin()) with check (is_admin());

-- helper macro via DO: leitura p/ autenticado + escrita p/ admin
do $$
declare t text;
begin
  foreach t in array array[
    'regioes','filiais','marcas','categorias','produtos','componentes_preco',
    'config_precificacao','produto_indice_regiao','produto_preco_manual'
  ] loop
    execute format('drop policy if exists %1$s_read on %1$s;', t);
    execute format('create policy %1$s_read on %1$s for select to authenticated using (true);', t);
    execute format('drop policy if exists %1$s_write on %1$s;', t);
    execute format('create policy %1$s_write on %1$s for all to authenticated using (is_admin()) with check (is_admin());', t);
  end loop;
end $$;

-- audit_logs: só admin lê; ninguém edita via API (só o trigger, que é definer)
drop policy if exists audit_admin_read on audit_logs;
create policy audit_admin_read on audit_logs for select to authenticated using (is_admin());


-- >>>>>>>>>> 0005_catalogo.sql <<<<<<<<<<

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


-- >>>>>>>>>> 0006_compras_preview.sql <<<<<<<<<<

-- =====================================================================
-- 0006_compras_preview.sql — Histórico de custo e aplicação de nova
-- compra (atualiza custos em lote). A prévia de preço usa o parâmetro
-- p_custo_override de fn_calcular_preco, já definido em 0002.
-- =====================================================================

-- ---------- Histórico de custo (rastro de cada mudança) ----------
create table if not exists cost_history (
  id             bigint generated always as identity primary key,
  produto_id     uuid not null references produtos(id) on delete cascade,
  custo_anterior numeric(14,2),
  custo_novo     numeric(14,2),
  origem         text,                       -- 'compra', 'ajuste manual', etc.
  usuario_id     uuid,
  created_at     timestamptz not null default now()
);
create index if not exists idx_cost_history_prod on cost_history(produto_id, created_at desc);
alter table cost_history enable row level security;
drop policy if exists cost_history_read on cost_history;
create policy cost_history_read on cost_history for select to authenticated using (is_admin());

-- =====================================================================
-- fn_aplicar_compra: atualiza o custo de vários produtos numa transação.
-- p_itens = jsonb: [{"produto_id":"...","custo":12345.67}, ...]
-- Registra cost_history. A auditoria de produtos dispara automaticamente.
-- =====================================================================
create or replace function fn_aplicar_compra(p_itens jsonb, p_origem text default 'compra')
returns integer
language plpgsql security definer set search_path = public as $$
declare it jsonb; v_ant numeric(14,2); v_novo numeric(14,2); n int := 0;
begin
  if not is_admin() then raise exception 'apenas admin pode aplicar compra'; end if;
  for it in select * from jsonb_array_elements(p_itens) loop
    v_novo := (it->>'custo')::numeric;
    select custo_atual into v_ant from produtos where id = (it->>'produto_id')::uuid;
    update produtos set custo_atual = v_novo where id = (it->>'produto_id')::uuid;
    insert into cost_history (produto_id, custo_anterior, custo_novo, origem, usuario_id)
    values ((it->>'produto_id')::uuid, v_ant, v_novo, p_origem, auth.uid());
    n := n + 1;
  end loop;
  return n;
end $$;


-- >>>>>>>>>> 0007_estoque_vendas.sql <<<<<<<<<<

-- =====================================================================
-- 0007_estoque_vendas.sql — Estoque (saldo + movimentos), Vendas (com
-- baixa automática) e Transferências entre filiais. Tudo em transações.
-- Fonte da verdade = inventory_movements; inventory_balances é o saldo
-- materializado, mantido por trigger (seção 29).
-- =====================================================================

-- ---------- tipos ----------
do $$ begin
  if not exists (select 1 from pg_type where typname='tipo_movimento') then
    create type tipo_movimento as enum
      ('entrada','venda','ajuste','transferencia_saida','transferencia_entrada');
  end if;
  if not exists (select 1 from pg_type where typname='estado_transferencia') then
    create type estado_transferencia as enum
      ('rascunho','em_montagem','enviada','recebida','cancelada');
  end if;
end $$;

-- ---------- saldo materializado ----------
create table if not exists inventory_balances (
  produto_id uuid not null references produtos(id) on delete cascade,
  filial_id  uuid not null references filiais(id)  on delete cascade,
  quantidade numeric(14,3) not null default 0,
  updated_at timestamptz not null default now(),
  primary key (produto_id, filial_id)
);

-- ---------- log de movimentos (assinado: negativo = saída) ----------
create table if not exists inventory_movements (
  id             bigint generated always as identity primary key,
  produto_id     uuid not null references produtos(id) on delete cascade,
  filial_id      uuid not null references filiais(id)  on delete cascade,
  tipo           tipo_movimento not null,
  quantidade     numeric(14,3) not null,       -- assinado
  motivo         text,
  referencia_tipo text,                         -- 'venda' | 'transferencia' | 'ajuste' | 'entrada'
  referencia_id  text,
  usuario_id     uuid,
  created_at     timestamptz not null default now()
);
create index if not exists idx_mov_prod_filial on inventory_movements(produto_id, filial_id, created_at desc);

-- trigger que mantém o saldo materializado
create or replace function fn_aplicar_movimento()
returns trigger language plpgsql as $$
begin
  insert into inventory_balances (produto_id, filial_id, quantidade)
  values (new.produto_id, new.filial_id, new.quantidade)
  on conflict (produto_id, filial_id)
    do update set quantidade = inventory_balances.quantidade + new.quantidade,
                  updated_at = now();
  return new;
end $$;
drop trigger if exists trg_aplicar_movimento on inventory_movements;
create trigger trg_aplicar_movimento after insert on inventory_movements
  for each row execute function fn_aplicar_movimento();

-- =====================================================================
-- VENDAS
-- =====================================================================
create table if not exists sales (
  id          uuid primary key default gen_random_uuid(),
  vendedor_id uuid references profiles(id),
  regiao_id   uuid references regioes(id),
  filial_id   uuid references filiais(id),
  cliente     text,
  observacao  text,
  total       numeric(14,2) not null default 0,
  created_at  timestamptz not null default now()
);
create index if not exists idx_sales_vendedor on sales(vendedor_id, created_at desc);
create index if not exists idx_sales_data on sales(created_at desc);

create table if not exists sale_items (
  id             uuid primary key default gen_random_uuid(),
  sale_id        uuid not null references sales(id) on delete cascade,
  produto_id     uuid not null references produtos(id),
  quantidade     numeric(14,3) not null,
  preco_unitario numeric(14,2) not null,
  subtotal       numeric(14,2) not null
);
create index if not exists idx_sale_items_sale on sale_items(sale_id);

-- registrar venda: cria venda + itens + baixa de estoque, numa transação.
-- A VENDA é a origem da saída de estoque (seção 20) — nada de "ajuste".
create or replace function fn_registrar_venda(
  p_regiao uuid, p_filial uuid, p_cliente text, p_obs text, p_itens jsonb
) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_sale uuid; it jsonb; v_sub numeric(14,2); v_total numeric(14,2) := 0;
begin
  if auth.uid() is null then raise exception 'precisa estar logado'; end if;
  if p_filial is null then raise exception 'informe a filial de saída do estoque'; end if;

  insert into sales (vendedor_id, regiao_id, filial_id, cliente, observacao, total)
  values (auth.uid(), p_regiao, p_filial, nullif(p_cliente,''), nullif(p_obs,''), 0)
  returning id into v_sale;

  for it in select * from jsonb_array_elements(p_itens) loop
    v_sub := round((it->>'quantidade')::numeric * (it->>'preco')::numeric, 2);
    insert into sale_items (sale_id, produto_id, quantidade, preco_unitario, subtotal)
    values (v_sale, (it->>'produto_id')::uuid, (it->>'quantidade')::numeric,
            (it->>'preco')::numeric, v_sub);
    insert into inventory_movements (produto_id, filial_id, tipo, quantidade,
            referencia_tipo, referencia_id, usuario_id)
    values ((it->>'produto_id')::uuid, p_filial, 'venda',
            -1 * (it->>'quantidade')::numeric, 'venda', v_sale::text, auth.uid());
    v_total := v_total + v_sub;
  end loop;

  update sales set total = v_total where id = v_sale;
  return v_sale;
end $$;

-- =====================================================================
-- AJUSTE DE ESTOQUE (só corrige — inventário, perda, avaria). Admin.
-- Define o saldo para a quantidade contada; grava o movimento da diferença.
-- =====================================================================
create or replace function fn_ajustar_estoque(
  p_produto uuid, p_filial uuid, p_quantidade_contada numeric, p_motivo text
) returns numeric
language plpgsql security definer set search_path = public as $$
declare v_atual numeric(14,3); v_delta numeric(14,3);
begin
  if not is_admin() then raise exception 'apenas admin pode ajustar estoque'; end if;
  select quantidade into v_atual from inventory_balances
    where produto_id=p_produto and filial_id=p_filial;
  v_atual := coalesce(v_atual, 0);
  v_delta := p_quantidade_contada - v_atual;
  if v_delta = 0 then return v_atual; end if;
  insert into inventory_movements (produto_id, filial_id, tipo, quantidade,
          motivo, referencia_tipo, usuario_id)
  values (p_produto, p_filial, 'ajuste', v_delta, nullif(p_motivo,''), 'ajuste', auth.uid());
  return p_quantidade_contada;
end $$;

-- Entrada simples de estoque (ex.: recebimento de compra). Admin.
create or replace function fn_entrada_estoque(
  p_produto uuid, p_filial uuid, p_quantidade numeric, p_motivo text
) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'apenas admin'; end if;
  insert into inventory_movements (produto_id, filial_id, tipo, quantidade, motivo, referencia_tipo, usuario_id)
  values (p_produto, p_filial, 'entrada', abs(p_quantidade), nullif(p_motivo,''), 'entrada', auth.uid());
end $$;

-- =====================================================================
-- TRANSFERÊNCIAS entre filiais
-- Estoque sai da origem no ENVIO e entra no destino no RECEBIMENTO
-- (evita contar duas vezes). Transações.
-- =====================================================================
create table if not exists transfers (
  id            uuid primary key default gen_random_uuid(),
  origem_id     uuid not null references filiais(id),
  destino_id    uuid not null references filiais(id),
  estado        estado_transferencia not null default 'rascunho',
  observacao    text,
  criado_por    uuid references profiles(id),
  enviado_por   uuid references profiles(id),
  recebido_por  uuid references profiles(id),
  created_at    timestamptz not null default now(),
  enviado_em    timestamptz,
  recebido_em   timestamptz
);
create table if not exists transfer_items (
  id          uuid primary key default gen_random_uuid(),
  transfer_id uuid not null references transfers(id) on delete cascade,
  produto_id  uuid not null references produtos(id),
  quantidade  numeric(14,3) not null
);
create index if not exists idx_transfer_items on transfer_items(transfer_id);

create or replace function fn_enviar_transferencia(p_transfer uuid)
returns void language plpgsql security definer set search_path = public as $$
declare t transfers%rowtype; it record;
begin
  if not is_admin() then raise exception 'apenas admin'; end if;
  select * into t from transfers where id = p_transfer for update;
  if not found then raise exception 'transferência inexistente'; end if;
  if t.estado not in ('rascunho','em_montagem') then
    raise exception 'transferência já enviada/recebida/cancelada'; end if;
  for it in select * from transfer_items where transfer_id = p_transfer loop
    insert into inventory_movements (produto_id, filial_id, tipo, quantidade,
            referencia_tipo, referencia_id, usuario_id)
    values (it.produto_id, t.origem_id, 'transferencia_saida', -1*it.quantidade,
            'transferencia', p_transfer::text, auth.uid());
  end loop;
  update transfers set estado='enviada', enviado_por=auth.uid(), enviado_em=now()
    where id = p_transfer;
end $$;

create or replace function fn_receber_transferencia(p_transfer uuid)
returns void language plpgsql security definer set search_path = public as $$
declare t transfers%rowtype; it record;
begin
  if not is_admin() then raise exception 'apenas admin'; end if;
  select * into t from transfers where id = p_transfer for update;
  if not found then raise exception 'transferência inexistente'; end if;
  if t.estado <> 'enviada' then raise exception 'só recebe transferência enviada'; end if;
  for it in select * from transfer_items where transfer_id = p_transfer loop
    insert into inventory_movements (produto_id, filial_id, tipo, quantidade,
            referencia_tipo, referencia_id, usuario_id)
    values (it.produto_id, t.destino_id, 'transferencia_entrada', it.quantidade,
            'transferencia', p_transfer::text, auth.uid());
  end loop;
  update transfers set estado='recebida', recebido_por=auth.uid(), recebido_em=now()
    where id = p_transfer;
end $$;

-- =====================================================================
-- RLS
-- =====================================================================
alter table inventory_balances  enable row level security;
alter table inventory_movements enable row level security;
alter table sales               enable row level security;
alter table sale_items          enable row level security;
alter table transfers           enable row level security;
alter table transfer_items      enable row level security;

-- saldo: qualquer autenticado lê (catálogo mostra disponibilidade)
drop policy if exists inv_bal_read on inventory_balances;
create policy inv_bal_read on inventory_balances for select to authenticated using (true);
drop policy if exists inv_bal_admin on inventory_balances;
create policy inv_bal_admin on inventory_balances for all to authenticated using (is_admin()) with check (is_admin());

-- movimentos: só admin lê o log (vendedor não precisa)
drop policy if exists inv_mov_read on inventory_movements;
create policy inv_mov_read on inventory_movements for select to authenticated using (is_admin());

-- vendas: vendedor vê as próprias; admin vê todas
drop policy if exists sales_read on sales;
create policy sales_read on sales for select to authenticated
  using (vendedor_id = auth.uid() or is_admin());
drop policy if exists sale_items_read on sale_items;
create policy sale_items_read on sale_items for select to authenticated
  using (exists (select 1 from sales s where s.id = sale_id
                 and (s.vendedor_id = auth.uid() or is_admin())));

-- transferências: só admin
drop policy if exists transfers_admin on transfers;
create policy transfers_admin on transfers for all to authenticated using (is_admin()) with check (is_admin());
drop policy if exists transfer_items_admin on transfer_items;
create policy transfer_items_admin on transfer_items for all to authenticated using (is_admin()) with check (is_admin());

-- filiais iniciais (edite/adicione depois)
insert into filiais (codigo, nome) values
  ('DD','Dourados / MS'), ('SP','São Paulo / SP')
on conflict (codigo) do nothing;


-- >>>>>>>>>> 0008_dashboard.sql <<<<<<<<<<

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


-- >>>>>>>>>> 0009_user_profiles.sql <<<<<<<<<<

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


-- >>>>>>>>>> 0010_auth_signup.sql <<<<<<<<<<

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


-- >>>>>>>>>> 0011_regiao_estoque.sql <<<<<<<<<<

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


-- >>>>>>>>>> 0012_custo_tabela.sql <<<<<<<<<<

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


-- >>>>>>>>>> 0013_formas_pagamento.sql <<<<<<<<<<

-- =====================================================================
-- 0013_formas_pagamento.sql — Desconto/acréscimo por tipo de pagamento
-- (Pix, à vista, cartão, boleto parcelado…) + nomes de região iguais à
-- planilha. O ajuste é um % com sinal: negativo = desconto, positivo =
-- acréscimo. Aplicado sobre o preço final da região.
-- =====================================================================

-- nomes de região exatamente como na planilha
update regioes set nome = 'Venda Direta MS' where codigo = 'VENDA_DIRETA_MS';
update regioes set nome = 'MS DDOS'          where codigo = 'MS_DDOS';
update regioes set nome = 'MS Andréi'        where codigo = 'MS_ANDREI';
update regioes set nome = 'SP-SP'            where codigo = 'SP_SP';
update regioes set nome = 'SP Outros'        where codigo = 'SP_OUTROS';
update regioes set nome = 'SP-RJ/MG/Sul'     where codigo = 'SP_RJ_MG_SUL';

create table if not exists formas_pagamento (
  id     uuid primary key default gen_random_uuid(),
  nome   text not null,
  ajuste numeric(8,5) not null default 0,   -- +0.04 = +4% (acréscimo) · -0.03 = -3% (desconto)
  ordem  int not null default 100,
  ativo  boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
drop trigger if exists trg_formas_updated on formas_pagamento;
create trigger trg_formas_updated before update on formas_pagamento
  for each row execute function set_updated_at();

alter table formas_pagamento enable row level security;
drop policy if exists formas_read on formas_pagamento;
create policy formas_read on formas_pagamento for select to authenticated using (fn_ativo());
drop policy if exists formas_write on formas_pagamento;
create policy formas_write on formas_pagamento for all to authenticated using (is_admin()) with check (is_admin());

-- tipos pré-cadastrados (o admin ajusta os % depois) — só se a tabela estiver vazia
do $$ begin
  if not exists (select 1 from formas_pagamento) then
    insert into formas_pagamento (nome, ajuste, ordem) values
      ('Pix', 0, 10), ('À vista', 0, 20),
      ('Cartão de Crédito', 0, 30), ('Cartão de Débito', 0, 40),
      ('Boleto 1x', 0, 50), ('Boleto 2x', 0, 60), ('Boleto 3x', 0, 70),
      ('Boleto 4x', 0, 80), ('Boleto 5x', 0, 90), ('Boleto 6x', 0, 100);
  end if;
end $$;


-- >>>>>>>>>> 0014_estoque_simples.sql <<<<<<<<<<

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
