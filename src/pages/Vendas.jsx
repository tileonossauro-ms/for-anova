import { useEffect, useMemo, useState } from 'react'
import { supabase } from '../lib/supabase.js'
import { useAuth } from '../auth/AuthContext.jsx'
import { brl } from '../lib/format.js'

export default function Vendas() {
  const { profile, isAdmin } = useAuth()
  const [regioes, setRegioes] = useState([])
  const [filiais, setFiliais] = useState([])
  const [regiaoId, setRegiaoId] = useState('')
  const [filialId, setFilialId] = useState('')
  const [busca, setBusca] = useState('')
  const [resultados, setResultados] = useState([])
  const [itens, setItens] = useState([])   // {id, descricao, quantidade, preco}
  const [cliente, setCliente] = useState('')
  const [obs, setObs] = useState('')
  const [msg, setMsg] = useState('')
  const [minhas, setMinhas] = useState([])

  useEffect(() => {
    supabase.from('regioes').select('*').eq('ativo', true).order('ordem')
      .then(({ data }) => { setRegioes(data || []); setRegiaoId(profile?.regiao_padrao_id || data?.[0]?.id || '') })
    supabase.from('filiais').select('*').eq('ativo', true).order('nome')
      .then(({ data }) => { setFiliais(data || []); setFilialId(data?.[0]?.id || '') })
  }, [profile])

  async function carregarMinhas() {
    const { data } = await supabase.from('sales')
      .select('id, cliente, total, created_at, filiais(nome)')
      .order('created_at', { ascending: false }).limit(10)
    setMinhas(data || [])
  }
  useEffect(() => { carregarMinhas() }, [])

  useEffect(() => {
    const q = busca.trim()
    if (q.length < 2) { setResultados([]); return }
    const t = setTimeout(async () => {
      const { data } = await supabase.from('produtos')
        .select('id, codigo, descricao')
        .or(`descricao.ilike.%${q}%,codigo.ilike.%${q}%`).order('descricao').limit(15)
      setResultados(data || [])
    }, 250)
    return () => clearTimeout(t)
  }, [busca])

  async function adicionar(p) {
    if (itens.some(i => i.id === p.id)) { setBusca(''); setResultados([]); return }
    let preco = 0
    if (regiaoId) {
      const { data } = await supabase.rpc('fn_calcular_preco', { p_produto: p.id, p_regiao: regiaoId })
      preco = data?.preco_final ?? 0
    }
    setItens(c => [...c, { id: p.id, descricao: p.descricao, quantidade: 1, preco }])
    setBusca(''); setResultados([])
  }

  function set(id, campo, valor) {
    setItens(c => c.map(i => i.id === id ? { ...i, [campo]: valor } : i))
  }

  const total = useMemo(
    () => itens.reduce((s, i) => s + (Number(i.quantidade) || 0) * (Number(i.preco) || 0), 0),
    [itens]
  )

  async function confirmar() {
    if (itens.length === 0) return
    if (!filialId) { setMsg('Selecione a filial de saída do estoque.'); return }
    const payload = itens.map(i => ({
      produto_id: i.id,
      quantidade: Number(i.quantidade) || 0,
      preco: Number(i.preco) || 0,
    }))
    const { data, error } = await supabase.rpc('fn_registrar_venda', {
      p_regiao: regiaoId || null, p_filial: filialId,
      p_cliente: cliente, p_obs: obs, p_itens: payload,
    })
    if (error) { setMsg('Erro: ' + error.message); return }
    setMsg('✅ Venda registrada e estoque baixado automaticamente.')
    setItens([]); setCliente(''); setObs(''); carregarMinhas()
  }

  return (
    <div className="space-y-4">
      <div className="card p-4">
        <h1 className="font-bold mb-3">Nova venda</h1>
        <div className="grid sm:grid-cols-2 gap-2 mb-2">
          <select className="input" value={filialId} onChange={e => setFilialId(e.target.value)}>
            <option value="">Filial (saída do estoque)…</option>
            {filiais.map(f => <option key={f.id} value={f.id}>{f.nome}</option>)}
          </select>
          <select className="input" value={regiaoId} onChange={e => setRegiaoId(e.target.value)}>
            {regioes.map(r => <option key={r.id} value={r.id}>Preço: {r.nome}</option>)}
          </select>
        </div>

        <div className="relative mb-3">
          <input className="input" placeholder="Adicionar produto (descrição ou código)…"
            value={busca} onChange={e => setBusca(e.target.value)} />
          {resultados.length > 0 && (
            <div className="absolute z-20 mt-1 w-full card max-h-72 overflow-auto">
              {resultados.map(p => (
                <button key={p.id} onClick={() => adicionar(p)}
                  className="block w-full text-left px-3 py-2 hover:bg-gray-50 border-b border-[var(--fn-border)] last:border-0 text-sm">
                  <span className="font-medium">{p.descricao}</span>
                  {p.codigo && <span className="text-[var(--fn-muted)]"> · {p.codigo}</span>}
                </button>
              ))}
            </div>
          )}
        </div>

        {itens.length > 0 && (
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead>
                <tr className="text-left text-[var(--fn-muted)] border-b border-[var(--fn-border)]">
                  <th className="py-2">Produto</th><th>Qtd</th><th>Preço unit.</th>
                  <th className="text-right">Subtotal</th><th></th>
                </tr>
              </thead>
              <tbody>
                {itens.map(i => (
                  <tr key={i.id} className="border-b border-[var(--fn-border)] last:border-0">
                    <td className="py-2 pr-2">{i.descricao}</td>
                    <td className="py-2 pr-2">
                      <input className="input w-16" type="number" min="0" step="1" value={i.quantidade}
                        onChange={e => set(i.id, 'quantidade', e.target.value)} />
                    </td>
                    <td className="py-2 pr-2">
                      <input className="input w-28" type="number" min="0" step="0.01" value={i.preco}
                        onChange={e => set(i.id, 'preco', e.target.value)} />
                    </td>
                    <td className="py-2 text-right whitespace-nowrap font-medium">
                      {brl((Number(i.quantidade) || 0) * (Number(i.preco) || 0))}
                    </td>
                    <td className="py-2 text-right">
                      <button className="text-red-500" onClick={() => setItens(c => c.filter(x => x.id !== i.id))}>×</button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}

        <div className="grid sm:grid-cols-2 gap-2 mt-3">
          <input className="input" placeholder="Cliente (opcional)" value={cliente} onChange={e => setCliente(e.target.value)} />
          <input className="input" placeholder="Observação (opcional)" value={obs} onChange={e => setObs(e.target.value)} />
        </div>

        <div className="flex items-center justify-between mt-4">
          <div className="text-lg font-bold">Total: <span className="text-[var(--fn-brand)]">{brl(total)}</span></div>
          <button className="btn-primary" disabled={itens.length === 0} onClick={confirmar}>Confirmar venda</button>
        </div>
        {msg && <div className="mt-3 text-sm bg-gray-50 rounded-lg p-3">{msg}</div>}
      </div>

      <div className="card p-4">
        <h2 className="font-bold mb-2">{isAdmin ? 'Últimas vendas' : 'Minhas últimas vendas'}</h2>
        {minhas.length === 0 && <div className="text-sm text-[var(--fn-muted)]">Nenhuma venda ainda.</div>}
        <div className="divide-y divide-[var(--fn-border)]">
          {minhas.map(v => (
            <div key={v.id} className="flex items-center justify-between py-2 text-sm">
              <div>
                <div className="font-medium">{v.cliente || 'Sem cliente'}</div>
                <div className="text-xs text-[var(--fn-muted)]">
                  {new Date(v.created_at).toLocaleString('pt-BR')} · {v.filiais?.nome}
                </div>
              </div>
              <div className="font-semibold text-[var(--fn-brand)]">{brl(v.total)}</div>
            </div>
          ))}
        </div>
      </div>
    </div>
  )
}
