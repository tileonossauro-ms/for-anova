import { useState } from 'react'
import { supabase } from '../lib/supabase.js'
import Logo from '../components/Logo.jsx'

export default function Login() {
  const [email, setEmail] = useState('')
  const [senha, setSenha] = useState('')
  const [erro, setErro] = useState('')
  const [carregando, setCarregando] = useState(false)

  async function entrar(e) {
    e.preventDefault()
    setErro(''); setCarregando(true)
    const { error } = await supabase.auth.signInWithPassword({ email, password: senha })
    setCarregando(false)
    if (error) setErro('Email ou senha incorretos.')
  }

  return (
    <div className="min-h-screen flex items-center justify-center p-6">
      <form onSubmit={entrar} className="card w-full max-w-sm p-8">
        <div className="flex flex-col items-center mb-6">
          <Logo height={52} />
          <div className="text-sm text-[var(--fn-muted)] mt-2">Catálogo e preços</div>
        </div>
        <label className="block text-sm font-medium mb-1">Email</label>
        <input className="input mb-3" type="email" value={email}
          onChange={e => setEmail(e.target.value)} required autoFocus />
        <label className="block text-sm font-medium mb-1">Senha</label>
        <input className="input mb-4" type="password" value={senha}
          onChange={e => setSenha(e.target.value)} required />
        {erro && <div className="text-sm text-red-600 mb-3">{erro}</div>}
        <button className="btn-primary w-full" disabled={carregando}>
          {carregando ? 'Entrando…' : 'Entrar'}
        </button>
      </form>
    </div>
  )
}
