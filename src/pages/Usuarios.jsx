import { useEffect, useState } from 'react'
import { supabase, criarUsuario } from '../lib/supabase.js'
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

  const [novo, setNovo] = useState({ email: '', senha: '' })
  const [erroNovo, setErroNovo] = useState('')
  async function criar() {
    setErroNovo('')
    if (!novo.email.trim() || novo.senha.length < 6) { setErroNovo('Informe email e uma senha de 6+ caracteres'); return }
    const { data, error } = await criarUsuario(novo.email.trim(), novo.senha)
    if (error) { setErroNovo('Erro: ' + error.message); return }
    const id = data?.user?.id
    if (id) {
      await supabase.from('profiles').upsert(
        { id, nome: novo.email.split('@')[0], papel: 'vendedor', ativo: true }, { onConflict: 'id' })
    }
    setNovo({ email: '', senha: '' }); await carregar()
    setMsg('✅ Usuário criado'); setTimeout(() => setMsg(''), 2500)
  }

  return (
    <div className="space-y-4">
      {msg && <div className="fixed top-16 right-4 bg-[var(--fn-brand)] text-white px-4 py-2 rounded-lg shadow z-30">{msg}</div>}

      <div className="card p-4">
        <h1 className="font-bold mb-2">Novo usuário</h1>
        <div className="flex flex-wrap gap-2 items-center">
          <input className="input flex-1 min-w-[200px]" type="email" placeholder="email"
            value={novo.email} onChange={e => setNovo(s => ({ ...s, email: e.target.value }))} />
          <input className="input w-44" type="password" placeholder="senha (6+ caracteres)"
            value={novo.senha} onChange={e => setNovo(s => ({ ...s, senha: e.target.value }))} />
          <button className="btn-primary py-2 px-4" onClick={criar}>Criar</button>
        </div>
        {erroNovo && <div className="text-sm text-red-600 mt-2">{erroNovo}</div>}
        <p className="text-xs text-[var(--fn-muted)] mt-2">
          Cria o login (vendedor, já ativo). Depois ajuste a região padrão na lista abaixo.
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

    </div>
  )
}
