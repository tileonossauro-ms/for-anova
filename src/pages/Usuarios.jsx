import { useEffect, useState } from 'react'
import { supabase } from '../lib/supabase.js'
import { useAuth } from '../auth/AuthContext.jsx'

export default function Usuarios() {
  const { profile } = useAuth()
  const [usuarios, setUsuarios] = useState([])
  const [regioes, setRegioes] = useState([])
  const [msg, setMsg] = useState('')

  async function carregar() {
    const [{ data: us }, { data: rs }] = await Promise.all([
      supabase.rpc('fn_usuarios'),
      supabase.from('regioes').select('id, nome').eq('ativo', true).order('ordem'),
    ])
    setUsuarios((us || []).map(u => ({ ...u })))
    setRegioes(rs || [])
  }
  useEffect(() => { carregar() }, [])

  function set(id, campo, valor) {
    setUsuarios(us => us.map(u => u.id === id ? { ...u, [campo]: valor } : u))
  }

  async function salvar(u) {
    const patch = {
      nome: u.nome, papel: u.papel, ativo: u.ativo,
      regiao_padrao_id: u.regiao_padrao_id || null,
    }
    const { error } = await supabase.from('profiles').update(patch).eq('id', u.id)
    setMsg(error ? 'Erro: ' + error.message : `✅ ${u.nome} salvo`)
    setTimeout(() => setMsg(''), 2500)
  }

  return (
    <div className="space-y-4">
      {msg && <div className="fixed top-16 right-4 bg-[var(--fn-brand)] text-white px-4 py-2 rounded-lg shadow z-30">{msg}</div>}

      <div className="card p-4">
        <h1 className="font-bold mb-1">Usuários</h1>
        <p className="text-sm text-[var(--fn-muted)]">
          Defina papel, região padrão e status de cada pessoa. O vendedor entra e já vê os preços da região dele.
        </p>
      </div>

      <div className="space-y-2">
        {usuarios.map(u => (
          <div key={u.id} className="card p-3">
            <div className="grid sm:grid-cols-[1fr_140px_1fr_auto_auto] gap-2 items-center">
              <input className="input" value={u.nome || ''} onChange={e => set(u.id, 'nome', e.target.value)} />
              <select className="input" value={u.papel} onChange={e => set(u.id, 'papel', e.target.value)}
                disabled={u.id === profile?.id}>
                <option value="vendedor">Vendedor</option>
                <option value="admin">Admin</option>
              </select>
              <select className="input" value={u.regiao_padrao_id || ''} onChange={e => set(u.id, 'regiao_padrao_id', e.target.value)}>
                <option value="">Sem região padrão</option>
                {regioes.map(r => <option key={r.id} value={r.id}>{r.nome}</option>)}
              </select>
              <label className="flex items-center gap-1.5 text-sm justify-center">
                <input type="checkbox" checked={u.ativo}
                  onChange={e => set(u.id, 'ativo', e.target.checked)}
                  disabled={u.id === profile?.id} />
                Ativo
              </label>
              <button className="btn-primary py-2 px-3 text-sm" onClick={() => salvar(u)}>Salvar</button>
            </div>
            <div className="text-xs text-[var(--fn-muted)] mt-1.5">
              {u.vendas || 0} venda(s)
              {u.ultima_venda && ` · última em ${new Date(u.ultima_venda).toLocaleDateString('pt-BR')}`}
              {u.id === profile?.id && ' · (você)'}
            </div>
          </div>
        ))}
      </div>

      <div className="card p-4 bg-gray-50">
        <h2 className="font-bold mb-1 text-sm">Como adicionar um novo vendedor</h2>
        <ol className="list-decimal ml-5 text-sm text-[var(--fn-muted)] space-y-1">
          <li>No Supabase: <b>Authentication → Users → Add user</b> (email + senha).</li>
          <li>Pronto — a pessoa aparece aqui automaticamente como <b>Vendedor</b>.</li>
          <li>Ajuste o nome, a <b>região padrão</b> e salve. Ela já entra vendo os preços da região dela.</li>
        </ol>
        <p className="text-xs text-[var(--fn-muted)] mt-2">
          A criação do login fica no Supabase por segurança (exige a chave secreta, que nunca vai para o site).
        </p>
      </div>
    </div>
  )
}
