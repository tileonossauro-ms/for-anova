-- =====================================================================
-- 0017_mult_massa.sql — Aplicar % desconto (MULTIPLDESCON) em massa a um
-- conjunto de produtos, recalculando o custo (tabela × %). Respeita as
-- linhas travadas (não altera). Admin apenas.
-- =====================================================================
create or replace function fn_mult_massa(p_ids uuid[], p_mult numeric)
returns integer
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not is_admin() then raise exception 'apenas admin'; end if;
  update produtos
    set multiplicador_desconto = p_mult,
        custo_atual = case when tabela_bruta is not null and tabela_bruta > 0
                           then round(tabela_bruta * p_mult, 2) else custo_atual end
    where id = any(p_ids) and not travado;
  get diagnostics n = row_count;
  return n;
end $$;
