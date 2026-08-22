import { useEffect, useState } from 'react'
import { supabase } from '../lib/supabase.js'

const numDot = v => { const n = parseFloat(String(v).replace(',', '.')); return isNaN(n) ? null : n }

// Desconto (ou acréscimo) por tipo de pagamento. Aplicado sobre o preço da região.
export default function Pagamentos({ embutido = false }) {
  const [itens, setItens] = useState([])
  const [novo, setNovo] = useState('')
  const [msg, setMsg] = useState('')
  const flash = t => { setMsg(t); setTimeout(() => setMsg(''), 2500) }

  async function carregar() {
    const { data } = await supabase.from('formas_pagamento').select('*').order('ordem')
    setItens((data || []).map(f => ({ ...f, pctUI: (f.ajuste * 100).toString().replace('.', ',') })))
  }
  useEffect(() => { carregar() }, [])

  async function salvar(f) {
    const pct = numDot(f.pctUI); if (pct == null) return
    await supabase.from('formas_pagamento').update({ ajuste: pct / 100, ativo: f.ativo }).eq('id', f.id)
    flash(`${f.nome} salvo`)
  }
  async function adicionar() {
    if (!novo.trim()) return
    const ordem = (itens.at(-1)?.ordem || 0) + 10
    await supabase.from('formas_pagamento').insert({ nome: novo.trim(), ajuste: 0, ordem })
    setNovo(''); carregar(); flash('Forma adicionada')
  }
  async function remover(f) {
    if (!confirm(`Remover "${f.nome}"?`)) return
    await supabase.from('formas_pagamento').delete().eq('id', f.id); carregar(); flash('Removida')
  }
  function set(id, campo, valor) { setItens(s => s.map(f => f.id === id ? { ...f, [campo]: valor } : f)) }

  return (
    <div className="space-y-4">
      {msg && <div className="fixed top-16 right-4 bg-[var(--fn-brand)] text-white px-4 py-2 rounded-lg shadow z-30">{msg}</div>}

      {!embutido && (
        <div className="card p-4">
          <h1 className="font-bold mb-1">Desconto por tipo de pagamento</h1>
          <p className="text-sm text-[var(--fn-muted)]">
            Valor negativo = desconto (ex.: Pix −3%). Valor positivo = acréscimo (ex.: Boleto 3x +4%).
            Aplicado sobre o preço final da região.
          </p>
        </div>
      )}
      {embutido && (
        <p className="text-sm text-[var(--fn-muted)]">
          Negativo = desconto (Pix −3%) · positivo = acréscimo (Boleto 3x +4%). Aplicado sobre o preço da região.
        </p>
      )}

      <div className="card p-0 divide-y divide-[var(--fn-border)]">
        {itens.map(f => (
          <div key={f.id} className="flex items-center gap-3 p-3">
            <div className="flex-1 font-medium">{f.nome}</div>
            <label className="flex items-center gap-1.5 text-sm text-[var(--fn-muted)]">
              <input type="checkbox" checked={f.ativo} onChange={e => set(f.id, 'ativo', e.target.checked)} /> ativo
            </label>
            <div className="flex items-center gap-1">
              <input className="input w-24 text-right" value={f.pctUI}
                onChange={e => set(f.id, 'pctUI', e.target.value)} />
              <span className="text-[var(--fn-muted)]">%</span>
            </div>
            <button className="btn-primary py-2 px-3 text-sm" onClick={() => salvar(f)}>Salvar</button>
            <button className="text-red-500 text-sm" onClick={() => remover(f)}>×</button>
          </div>
        ))}
      </div>

      <div className="card p-3 flex gap-2">
        <input className="input flex-1" placeholder="Nova forma de pagamento (ex.: Financiamento)"
          value={novo} onChange={e => setNovo(e.target.value)} />
        <button className="btn-primary py-2 px-4" onClick={adicionar}>Adicionar</button>
      </div>
    </div>
  )
}
