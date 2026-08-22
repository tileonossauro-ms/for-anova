# Como aplicar o banco no seu Supabase

Você **não precisa instalar nada**. Caminho mais fácil (um arquivo só):

1. Acesse [supabase.com](https://supabase.com) e entre no seu projeto.
2. No menu à esquerda, abra **SQL Editor** → **New query**.
3. Abra o arquivo **`supabase/APLICAR_TUDO.sql`**, copie **todo** o conteúdo, cole no editor e clique em **Run**.

Pronto — cria a estrutura, o motor de preço, os 248 produtos, a auditoria, a segurança e o catálogo de uma vez.

> Se preferir passo a passo, os arquivos separados estão em `supabase/migrations/` (rodar na ordem 0001 → 0005).

## Criar o primeiro usuário admin (Marcos)

1. No menu, vá em **Authentication → Users → Add user** e crie o login do Marcos (email + senha).
2. Copie o **User UID** que aparece.
3. Volte no **SQL Editor** e rode (trocando o UID e o nome):

```sql
insert into profiles (id, nome, papel)
values ('COLE-O-UID-AQUI', 'Marcos', 'admin');
```

Pronto — o Marcos vira admin e enxerga/edita tudo.

## O que vou precisar de você para conectar o site (com segurança)

Do painel **Project Settings → API**, me passe só:
- **Project URL** (algo como `https://xxxx.supabase.co`)
- **anon public key** (a chave marcada como *public/publishable* — pode compartilhar, é feita pra isso)

⚠️ **NUNCA** me mande a **service_role key** nem a senha do banco. Não preciso delas e elas são secretas.
