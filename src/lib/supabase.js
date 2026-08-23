import { createClient } from '@supabase/supabase-js'

const url = import.meta.env.VITE_SUPABASE_URL
const anon = import.meta.env.VITE_SUPABASE_ANON_KEY

// isConfigured: falso enquanto o .env não estiver preenchido — a tela de
// configuração aparece no lugar de quebrar o app.
export const isConfigured = Boolean(url && anon && !url.includes('SEU-PROJETO'))

export const supabase = isConfigured
  ? createClient(url, anon)
  : null

export const supabaseUrl = url
export const supabaseAnon = anon

// cria um usuário (email+senha) sem afetar a sessão do admin logado —
// usa um cliente separado que não persiste sessão.
export async function criarUsuario(email, password) {
  const tmp = createClient(url, anon, {
    auth: { persistSession: false, autoRefreshToken: false, storageKey: 'fn-admin-create' },
  })
  return tmp.auth.signUp({ email, password })
}
