# Força Nova — Gestão comercial, precificação, estoque e vendas

Sistema web que substitui a planilha de preços (LPI). Motor de precificação
100% configurável, catálogo mobile-first para vendedores, e controle de
compras/estoque/vendas — tudo sobre Supabase.

## Stack
- **Frontend:** React + Vite
- **Backend:** Supabase (PostgreSQL + Auth + RLS)
- **Motor de preço:** funções PostgreSQL dirigidas por dados (nenhuma regra chumbada no código)

## Rodar localmente
```bash
npm install
cp .env.example .env   # e preencha com a URL e a anon key do seu Supabase
npm run dev
```

## Banco de dados
As migrations ficam em [`supabase/migrations/`](supabase/migrations) e são
**idempotentes** (podem ser aplicadas mais de uma vez sem duplicar dados).
Para aplicar manualmente, veja [`supabase/COMO_APLICAR.md`](supabase/COMO_APLICAR.md)
ou cole [`supabase/APLICAR_TUDO.sql`](supabase/APLICAR_TUDO.sql) no SQL Editor.

| Migration | Conteúdo |
|---|---|
| 0001_core | perfis, regiões, filiais, marcas, categorias, produtos |
| 0002_pricing_engine | motor de preço editável + `fn_calcular_preco` |
| 0003_seed | 248 produtos reais importados da planilha |
| 0004_audit_rls | auditoria + segurança (RLS) |
| 0005_catalogo | RPC de catálogo e explicação de preço |
| 0006_compras_preview | histórico de custo + aplicar nova compra |

## Documentos
- [`DIAGNOSTICO.md`](DIAGNOSTICO.md) — análise da planilha e da arquitetura
- [`produtos-forca-nova.csv`](produtos-forca-nova.csv) / [`parametros-forca-nova.json`](parametros-forca-nova.json) — dados extraídos
