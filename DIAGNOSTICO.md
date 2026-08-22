# Diagnóstico Inicial — Sistema Força Nova

> Documento de análise **anterior à implementação**, conforme seções 38 e 48 do prompt mestre.
> Baseado na análise real do arquivo `LPI COMPLETA - NOVA - SUL-SUDESTE.xlsx` (aberto com a senha 2390).
> **Nada de código foi escrito ainda.** Ao final há uma lista de decisões que preciso confirmar com você antes de começar.

---

## 0. Estado dos arquivos fornecidos

Só **um** dos arquivos citados no prompt está realmente nesta pasta:

| Arquivo citado no prompt | Situação |
|---|---|
| `LPI COMPLETA - NOVA - SUL-SUDESTE.xlsx` | ✅ Presente e analisado |
| `Build Together.zip` (projeto React/Supabase anterior) | ❌ Ausente |
| `spec-app-forca-nova.md` | ❌ Ausente |
| `produtos-forca-nova.csv` (~258 produtos) | ❌ Ausente |
| `parametros-forca-nova.json` (parâmetros de preço) | ❌ Ausente |

Consequência: o **diagnóstico da arquitetura anterior (item A)** e a parte do plano que dependia do CSV/JSON prontos ficam **pendentes** até você me enviar esses arquivos. A boa notícia: a própria planilha contém os produtos e os parâmetros reais, então consegui reconstruir a lógica direto da fonte.

---

## B. Diagnóstico da planilha (o que realmente existe)

A planilha tem 4 abas, mas só 3 têm conteúdo:

| Aba | Conteúdo | Papel |
|---|---|---|
| **GERAL ATUAL** | ~251 produtos "outras marcas" + regras de preço + fretes + condições comerciais | Núcleo da precificação |
| **AGRISHOW** | ~265 linhas, tabela de evento/usados com custo calculado | Tabela paralela (outra lógica de custo) |
| **INDICE DE DESC.** | Uma célula: índice de desconto 30% | "Parâmetro" isolado referenciado por fórmulas |
| Planilha1 | Vazia | — |

### B.1 A "tabela" não é uma tabela — é um documento

`GERAL ATUAL` **não é uma planilha tabular limpa**. É um documento visual com:

- **943 células mescladas**;
- **~15+ blocos de seção** (linhas 5, 7, 9, 30, 37, 42, 48, 52, 59, 64, 69, 70, 96, 129, 146, 180, 247…), cada um repetindo o cabeçalho;
- **cabeçalho em várias linhas** (linha 4 tem os títulos "grandes", com sub-rótulos abaixo);
- **linhas 293–311 não são produtos** — são condições comerciais, tabela de fretes compartilhados, notas de rodapé;
- o significado de cada coluna **muda conforme o bloco/seção**.

Isso confirma o diagnóstico do prompt: a planilha é frágil porque mistura **dados, layout e regras** no mesmo lugar.

### B.2 A coluna "MARCA" na verdade é CATEGORIA

A coluna B ("MARCA") contém em sua maioria **tipos de implemento**, não marcas:

```
50  ALMEIDA          33  NIVELADORA       19  CALCAREADEIRA
17  PESADA           12  USADOS           12  ROÇADEIRA
11  SUPER PESADA     10  TERRACEADOR       9  INTERMEDIÁRIA
7   EXTRA PESADA      6  COMPOSTADOR       6  PATROLA ...
```

`ALMEIDA` e `PICCIN` são marcas de verdade; `NIVELADORA`, `PESADA`, `ROÇADEIRA` são **categorias**. Há ainda inconsistências de digitação: `INTERMEDIÁRIA` vs `INTERMEDIARIA`, `ALMEIDA` vs `ALMEIDA ` (com espaço). **No novo sistema, marca e categoria precisam ser entidades separadas e normalizadas.**

### B.3 O motor de precificação real (o achado mais importante)

Extraí os templates de fórmula. O padrão é claro e **consistente**:

```
custo   = coluna_de_custo × fator
preço_X = custo × (1 + índice_da_região/coluna_X)
```

Fórmulas reais encontradas em `GERAL ATUAL`:

| Coluna | Fórmula | Significado |
|---|---|---|
| K (custo) | `I × 0,42156`  ou  `I × J` | custo a partir da coluna de custo/tabela |
| Q | `(K × 0,45) + K` | NF SP p/ São Paulo c/ montagem (índice 45%) |
| R | `Q × 1,04` | acréscimo de 4% sobre Q |
| T | `(K × 0,42) + K` (e `0,40`) | índice 42% |
| U | `(K × 0,31) + K` (e `0,30`) | NF SP p/ outros ES |
| W | `(K × 0,34) + K` (e `0,35`) | NF SP p/ MG/RJ/PR/SC/RS |
| Z | `(K × 0,38) + K` | índice 38% |

Em `AGRISHOW` a lógica de custo é outra: `custo = tabela × desconto(30%)` e `fora MS = custo × 1,27`.

**Conclusão de arquitetura:** o motor pedido no prompt (seções 8–11) é totalmente viável e mapeia 1:1 nesta lógica:

```
preço_final(produto, região) = round( custo × (1 + índice(região)) × ajustes )
```

Cada "coluna de preço" da planilha vira uma **região comercial** com seu índice. Nada de fórmula espalhada — um único motor com parâmetros por região/categoria/produto.

### B.4 Produtos-exceção são a maioria nesta aba (atenção)

Contagem real em `GERAL ATUAL` (linhas 5–290):

| Métrica | Valor |
|---|---|
| Produtos (descrição preenchida) | **~251** |
| Preço em Q **digitado à mão** (literal, sem fórmula) | **~168** |
| Preço em Q **calculado por fórmula** | **~78** |
| Produtos com "NT" (sem tabela/custo) | **21** |
| Custo zero | **10** |
| Sem código RG estável | muitos |

Ou seja: **~2/3 dos produtos desta aba têm preço manual**, e só ~1/3 é calculado. Faz sentido — o título da aba diz literalmente *"OUTRAS MARCAS - VÁRIOS VALORES E FORMAS DE FATURAR"*. **Esta é a aba das exceções.**

Implicação forte de design: **o override manual de preço tem que ser cidadão de primeira classe do motor**, não um caso raro. O motor calcula o preço padrão; o produto pode ter um preço travado manualmente que o motor **nunca sobrescreve** (seções 6, 34). Provavelmente as tabelas "normais" (com muito mais fórmulas) estão em **outras abas/arquivos que ainda não recebi** (ex.: a tabela do MS).

---

## C. Problemas encontrados (riscos da estrutura atual)

1. **Layout = dados.** Seções, merges e cabeçalhos repetidos tornam qualquer alteração perigosa (o problema que você já vive).
2. **"MARCA" mistura marca e categoria** e tem valores inconsistentes (acentos, espaços, duplicatas).
3. **Índices/impostos embutidos em fórmulas de célula** (0,45 / 0,42 / 0,31 / 0,38…), impossíveis de auditar em massa.
4. **Discrepância de parâmetros a validar:** o JSON citado no prompt fala em fator de custo **0,4651** e índices 0,30/0,35/0,38; a aba real usa fator **0,42156** e índices 0,45/0,42/0,31/0,34/0,38. **Não são iguais.** Isso é esperado — cada aba/região tem seus próprios números — mas **não posso assumir um valor único**. Precisa ser validado por você, região a região.
5. **Códigos instáveis.** Muitos produtos sem RG; a identidade do produto não é confiável para casar entrada de nota fiscal automaticamente.
6. **Sem histórico, sem autoria, sem estoque real** — exatamente o que o novo sistema resolve.

---

## D. Arquitetura proposta (resumo — detalhe completo após sua validação)

**Stack:** Supabase (Postgres + Auth + RLS) + front web mobile-first (React). Motor de preço como **função Postgres** (fonte única da verdade, testável, com RLS), nunca no frontend.

**Modelo de dados central (enxuto, sem "colunas mágicas"):**

- `products` (código, descrição, `brand_id`, `category_id`, unidade, status, `custo_atual`, `preco_manual?`, `regra_especial?`)
- `brands`, `categories`, `regions` (comerciais, p/ preço), `branches` (filiais, p/ estoque físico) — **regiões ≠ filiais** (seção 14)
- **Motor:** `pricing_components` (nome, tipo `percentual|valor_fixo|multiplicador|arredondamento`, ordem, escopo global/categoria/região/produto, prioridade, ativo) → resolve a hierarquia produto+região → produto → categoria+região → categoria → região → global (seção 9, a validar)
- `cost_history`, `price_history`, `audit_logs`
- `inventory_balances` (saldo materializado) + `inventory_movements` (log — fonte da verdade)
- `transfers` / `transfer_items` (com estados e transação no envio/recebimento)
- `sales` / `sale_items` (venda **gera** a baixa de estoque automaticamente — seção 20)
- `quotes` / `quote_items` (gera texto p/ WhatsApp)
- `profiles` + roles (ADMIN / VENDEDOR), com `region_id` padrão por vendedor

**Explicação de preço (seção 11):** cada preço calculado guarda o "rastro" dos componentes aplicados, para responder *"por que custa R$ X?"*.

---

## E. Plano de migração (em etapas, sem perder informação)

1. **Enviar os arquivos que faltam** (ou eu extraio tudo da planilha completa, incluindo a aba do MS).
2. Extrair produtos **preservando** flags: `manual`, `NT`, `custo_zero`, `sem_código`, `descontinuado?`.
3. Separar marca × categoria e normalizar (acentos/espaços/duplicatas).
4. Importar parâmetros como **configuração editável** (não hard-code), por região.
5. **Não sobrescrever** exceções: produto com preço manual entra travado.
6. **Validar cálculo:** rodar o motor em N produtos reais e comparar `preço do sistema × preço da planilha`. Só liberar quando bater (e, quando não bater, descobrir a regra — não "forçar o resultado", seções 33/36).
7. Liberar catálogo → depois vendas/estoque.

---

## F. Plano de implementação (fases pequenas e testáveis)

Segue a ordem do prompt (seção 39): **Fase 1** Fundação (Supabase, Auth, perfis, regiões, filiais, produtos, categorias, RLS, auditoria) → **Fase 2** Motor de preço + regras + massa + explicação → **Fase 3** Catálogo → **Fase 4** Estoque → **Fase 5** Vendas + baixa automática → **Fase 6** Orçamentos → **Fase 7** Dashboard. Cada fase: implementar → testar → validar → só então avançar (seção 47).

---

## ⚠️ Decisões que preciso de você ANTES de escrever código

1. **Arquivos faltantes:** você tem o `Build Together.zip` e os demais? Ou prefere que eu **ignore o projeto anterior** e extraia tudo da(s) planilha(s)?
2. **Planilha completa:** esta aba é só "OUTRAS MARCAS / SUL-SUDESTE" e é dominada por preços manuais. **Existe a aba/arquivo do MS e das marcas principais** (a que tem o motor de fórmulas de verdade)? Ela é essencial para validar os índices.
3. **Supabase:** você já tem um projeto Supabase? Posso usar credenciais suas, ou começo com um projeto/local novo? (Não coloque chaves aqui no chat — me diga só se existe.)
4. **Onde rodar:** confirmo que construo o app **nesta pasta** (`Desktop/forçanova`) do zero, certo?
5. **Índices oficiais:** os índices reais são os da planilha (0,45/0,42/0,31/0,34/0,38 nesta aba) ou os do JSON (0,30/0,35/0,38)? Preciso da tabela oficial região × índice, hoje válida.
