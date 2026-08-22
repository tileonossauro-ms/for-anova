import { createContext, useContext, useEffect, useState } from 'react'
import { supabase, isConfigured } from '../lib/supabase.js'

const AuthCtx = createContext(null)
export const useAuth = () => useContext(AuthCtx)

export function AuthProvider({ children }) {
  const [session, setSession] = useState(null)
  const [profile, setProfile] = useState(null)   // { id, nome, papel, regiao_padrao_id }
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    if (!isConfigured) { setLoading(false); return }
    supabase.auth.getSession().then(({ data }) => {
      setSession(data.session)
      if (!data.session) setLoading(false)
    })
    const { data: sub } = supabase.auth.onAuthStateChange((_e, s) => {
      setSession(s)
      if (!s) { setProfile(null); setLoading(false) }
    })
    return () => sub.subscription.unsubscribe()
  }, [])

  // carrega o perfil (papel + região padrão) quando há sessão
  useEffect(() => {
    if (!isConfigured || !session) return
    let active = true
    ;(async () => {
      const { data } = await supabase
        .from('profiles')
        .select('id, nome, papel, regiao_padrao_id, ativo')
        .eq('id', session.user.id)
        .maybeSingle()
      if (active) { setProfile(data); setLoading(false) }
    })()
    return () => { active = false }
  }, [session])

  const signOut = () => supabase?.auth.signOut()
  const isAdmin = profile?.papel === 'admin'

  return (
    <AuthCtx.Provider value={{ session, profile, isAdmin, loading, signOut }}>
      {children}
    </AuthCtx.Provider>
  )
}
