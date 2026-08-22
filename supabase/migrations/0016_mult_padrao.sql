-- =====================================================================
-- 0016_mult_padrao.sql — Aplica % desconto (MULTIPLDESCON) = 42,156% a
-- TODOS os produtos e recalcula o custo (tabela × 0,42156). Roda UMA vez
-- só (guardado por flag) para não sobrescrever ajustes futuros do admin.
-- =====================================================================
do $$ begin
  if not exists (select 1 from config_precificacao where chave = 'mult_padrao_aplicado') then
    update produtos set multiplicador_desconto = 0.42156;
    update produtos set custo_atual = round(tabela_bruta * 0.42156, 2)
      where tabela_bruta is not null and tabela_bruta > 0;
    insert into config_precificacao (chave, valor_txt, descricao)
    values ('mult_padrao_aplicado', 'sim', '42,156% aplicado a todos os produtos (uma vez)');
  end if;
end $$;
