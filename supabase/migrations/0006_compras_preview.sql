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
