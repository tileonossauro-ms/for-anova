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
