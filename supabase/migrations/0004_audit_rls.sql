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
