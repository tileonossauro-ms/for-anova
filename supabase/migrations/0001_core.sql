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
