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
