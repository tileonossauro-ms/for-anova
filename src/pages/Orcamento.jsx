import { useEffect, useMemo, useState } from 'react'
import { supabase } from '../lib/supabase.js'
import { useAuth } from '../auth/AuthContext.jsx'
import { brl } from '../lib/format.js'

// Gera um texto de orçamento pronto para copiar no WhatsApp (seção 19).
// Sem PDF, sem CRM — só o texto, editável antes de copiar.
export default function Orcamento() {
  const { profile } = useAuth()
  const [regioes, setRegioes] = useState([])
  const [regiaoId, setRegiaoId] = useState('')
  const [busca, setBusca] = useState('')
  const [resultados, setResultados] = useState([])
  const [itens, setItens] = useState([])
  const [cliente, setCliente] = useState('')
  const [texto, setTexto] = useState('')
  const [copiado, setCopiado] = useState(false)

  useEffect(() => {
    supabase.from('regioes').select('*').eq('ativo', true).order('ordem')
      .then(({ data }) => { setRegioes(data || []); setRegiaoId(profile?.regiao_padrao_id || data?.[0]?.id || '') })
  }, [profile])

  useEffect(() => {
    const q = busca.trim()
    if (q.length < 2) { setResultados([]); return }
    const t = setTimeout(async () => {
      const { data } = await supabase.from('produtos').select('id, codigo, descricao')
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
  function set(id, campo, valor) { setItens(c => c.map(i => i.id === id ? { ...i, [campo]: valor } : i)) }

  const total = useMemo(
    () => itens.reduce((s, i) => s + (Number(i.quantidade) || 0) * (Number(i.preco) || 0), 0), [itens])

  function gerar() {
    const linhas = ['*ORÇAMENTO*', '']
    if (cliente.trim()) linhas.push(`Cliente: ${cliente.trim()}`, '')
    itens.forEach(i => {
      const q = Number(i.quantidade) || 0, p = Number(i.preco) || 0
      linhas.push(`${q}x ${i.descricao}`)
      linhas.push(`   ${brl(p)} cada — ${brl(q * p)}`)
    })
    linhas.push('', `*Total: ${brl(total)}*`, '', '_Valores sujeitos à confirmação._')
    setTexto(linhas.join('\n'))
    setCopiado(false)
  }

  async function copiar() {
    try { await navigator.clipboard.writeText(texto); setCopiado(true); setTimeout(() => setCopiado(false), 2000) }
    catch { /* usuário copia manualmente */ }
  }

  return (
    <div className="space-y-4">
      <div className="card p-4">
        <h1 className="font-bold mb-3">Novo orçamento</h1>
        <div className="grid sm:grid-cols-2 gap-2 mb-2">
          <input className="input" placeholder="Cliente" value={cliente} onChange={e => setCliente(e.target.value)} />
          <select className="input" value={regiaoId} onChange={e => setRegiaoId(e.target.value)}>
            {regioes.map(r => <option key={r.id} value={r.id}>Preço: {r.nome}</option>)}
          </select>
        </div>
        <div className="relative">
          <input className="input" placeholder="Adicionar produto…" value={busca} onChange={e => setBusca(e.target.value)} />
          {resultados.length > 0 && (
            <div className="absolute z-20 mt-1 w-full card max-h-72 overflow-auto">
              {resultados.map(p => (
                <button key={p.id} onClick={() => adicionar(p)}
                  className="block w-full text-left px-3 py-2 hover:bg-gray-50 border-b border-[var(--fn-border)] last:border-0 text-sm">
                  {p.descricao}{p.codigo && <span className="text-[var(--fn-muted)]"> · {p.codigo}</span>}
                </button>
              ))}
            </div>
          )}
        </div>

        {itens.length > 0 && (
          <div className="overflow-x-auto mt-3">
            <table className="w-full text-sm">
              <thead><tr className="text-left text-[var(--fn-muted)] border-b border-[var(--fn-border)]">
                <th className="py-2">Produto</th><th>Qtd</th><th>Preço</th><th className="text-right">Subtotal</th><th></th>
              </tr></thead>
              <tbody>
                {itens.map(i => (
                  <tr key={i.id} className="border-b border-[var(--fn-border)] last:border-0">
                    <td className="py-2 pr-2">{i.descricao}</td>
                    <td className="py-2 pr-2"><input className="input w-16" type="number" min="0" value={i.quantidade}
                      onChange={e => set(i.id, 'quantidade', e.target.value)} /></td>
                    <td className="py-2 pr-2"><input className="input w-28" type="number" min="0" step="0.01" value={i.preco}
                      onChange={e => set(i.id, 'preco', e.target.value)} /></td>
                    <td className="py-2 text-right whitespace-nowrap font-medium">{brl((Number(i.quantidade) || 0) * (Number(i.preco) || 0))}</td>
                    <td className="py-2 text-right"><button className="text-red-500" onClick={() => setItens(c => c.filter(x => x.id !== i.id))}>×</button></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}

        <div className="flex items-center justify-between mt-4">
          <div className="text-lg font-bold">Total: <span className="text-[var(--fn-brand)]">{brl(total)}</span></div>
          <button className="btn-primary" disabled={itens.length === 0} onClick={gerar}>Gerar texto</button>
        </div>
      </div>

      {texto && (
        <div className="card p-4">
          <div className="flex items-center justify-between mb-2">
            <h2 className="font-bold">Texto para WhatsApp</h2>
            <button className="btn-primary py-2 px-4 text-sm" onClick={copiar}>{copiado ? 'Copiado ✓' : 'Copiar'}</button>
          </div>
          <textarea className="input font-mono text-sm" rows={Math.min(4 + itens.length * 2, 20)}
            value={texto} onChange={e => setTexto(e.target.value)} />
          <p className="text-xs text-[var(--fn-muted)] mt-1">Pode editar o texto antes de copiar.</p>
        </div>
      )}
    </div>
  )
}
