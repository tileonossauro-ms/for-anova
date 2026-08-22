import { useEffect, useState } from 'react'
import { supabase } from '../lib/supabase.js'

// Escopo reduzido: controla ENTRADA (com justificativa) e SAÍDA (podendo
// marcar como Venda e atrelar um vendedor). Tudo por região.
export default function Estoque() {
  const [regioes, setRegioes] = useState([])
  const [vendedores, setVendedores] = useState([])
  const [regiaoId, setRegiaoId] = useState('')
  const [busca, setBusca] = useState('')
  const [resultados, setResultados] = useState([])
  const [sel, setSel] = useState(null)      // { id, descricao, saldo }
  const [movs, setMovs] = useState([])
  const [msg, setMsg] = useState('')

  // formulários
  const [qtd, setQtd] = useState('')
  const [motivo, setMotivo] = useState('')
  const [ehVenda, setEhVenda] = useState(false)
  const [vendedorId, setVendedorId] = useState('')

  const flash = t => { setMsg(t); setTimeout(() => setMsg(''), 3000) }

  useEffect(() => {
    supabase.from('regioes').select('id, nome, ativo, ordem').eq('ativo', true).order('ordem')
      .then(({ data }) => { setRegioes(data || []); setRegiaoId(data?.[0]?.id || '') })
    supabase.from('profiles').select('id, nome, papel, ativo').order('nome')
      .then(({ data }) => setVendedores((data || []).filter(u => u.ativo)))
  }, [])

  async function carregarMovs() {
    if (!regiaoId) return
    const { data } = await supabase.rpc('fn_movimentos', { p_regiao: regiaoId })
    setMovs(data || [])
  }
  useEffect(() => { carregarMovs(); setSel(null) }, [regiaoId])

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

  async function escolher(p) {
    const { data } = await supabase.rpc('fn_saldo_regiao', { p_produto: p.id, p_regiao: regiaoId })
    setSel({ id: p.id, descricao: p.descricao, saldo: data ?? 0 })
    setBusca(''); setResultados([]); setQtd(''); setMotivo(''); setEhVenda(false); setVendedorId('')
  }
  async function recarregarSaldo() {
    const { data } = await supabase.rpc('fn_saldo_regiao', { p_produto: sel.id, p_regiao: regiaoId })
    setSel(s => ({ ...s, saldo: data ?? 0 }))
  }

  const q = () => { const n = parseFloat(String(qtd).replace(',', '.')); return isNaN(n) ? null : n }

  async function entrada() {
    if (q() == null) { flash('Informe a quantidade'); return }
    if (!motivo.trim()) { flash('Justifique a entrada'); return }
    const { error } = await supabase.rpc('fn_entrada', { p_produto: sel.id, p_regiao: regiaoId, p_qtd: q(), p_motivo: motivo })
    if (error) { flash('Erro: ' + error.message); return }
    flash('Entrada registrada'); setQtd(''); setMotivo(''); recarregarSaldo(); carregarMovs()
  }
  async function saida() {
    if (q() == null) { flash('Informe a quantidade'); return }
    if (ehVenda && !vendedorId) { flash('Escolha o vendedor da venda'); return }
    if (!ehVenda && !motivo.trim()) { flash('Informe o motivo da saída'); return }
    const { error } = await supabase.rpc('fn_saida', {
      p_produto: sel.id, p_regiao: regiaoId, p_qtd: q(), p_motivo: motivo,
      p_venda: ehVenda, p_vendedor: ehVenda ? vendedorId : null,
    })
    if (error) { flash('Erro: ' + error.message); return }
    flash(ehVenda ? 'Venda registrada e baixada' : 'Saída registrada')
    setQtd(''); setMotivo(''); setEhVenda(false); setVendedorId(''); recarregarSaldo(); carregarMovs()
  }

  return (
    <div className="space-y-4">
      {msg && <div className="fixed top-16 right-4 bg-[var(--fn-brand)] text-white px-4 py-2 rounded-lg shadow z-30">{msg}</div>}

      <div className="card p-4">
        <h1 className="font-bold mb-3">Estoque</h1>
        <label className="block text-sm text-[var(--fn-muted)] mb-1">Região / estoque</label>
        <select className="input sm:w-72 mb-3" value={regiaoId} onChange={e => setRegiaoId(e.target.value)}>
          {regioes.map(r => <option key={r.id} value={r.id}>{r.nome}</option>)}
        </select>

        <div className="relative">
          <input className="input" placeholder="Buscar produto…" value={busca} onChange={e => setBusca(e.target.value)} />
          {resultados.length > 0 && (
            <div className="absolute z-20 mt-1 w-full card max-h-72 overflow-auto">
              {resultados.map(p => (
                <button key={p.id} onClick={() => escolher(p)}
                  className="block w-full text-left px-3 py-2 hover:bg-gray-50 border-b border-[var(--fn-border)] last:border-0 text-sm">
                  {p.descricao}{p.codigo && <span className="text-[var(--fn-muted)]"> · {p.codigo}</span>}
                </button>
              ))}
            </div>
          )}
        </div>
      </div>

      {sel && (
        <div className="card p-4">
          <div className="font-medium">{sel.descricao}</div>
          <div className="text-sm text-[var(--fn-muted)] mb-4">Saldo atual nesta região: <b className="text-[var(--fn-text)]">{sel.saldo}</b></div>

          <div className="grid md:grid-cols-2 gap-4">
            {/* ENTRADA */}
            <div className="bg-gray-50 rounded-lg p-3">
              <div className="font-medium text-sm mb-2 flex items-center gap-2"><span className="text-green-700">▲</span> Entrada</div>
              <input className="input mb-2" placeholder="Quantidade" value={qtd} onChange={e => setQtd(e.target.value)} />
              <input className="input mb-2" placeholder="Justificativa (obrigatória) — ex.: compra NF 123"
                value={motivo} onChange={e => setMotivo(e.target.value)} />
              <button className="btn-primary py-2 px-4 text-sm w-full" onClick={entrada}>Registrar entrada</button>
            </div>

            {/* SAÍDA */}
            <div className="bg-gray-50 rounded-lg p-3">
              <div className="font-medium text-sm mb-2 flex items-center gap-2"><span className="text-red-600">▼</span> Saída</div>
              <input className="input mb-2" placeholder="Quantidade" value={qtd} onChange={e => setQtd(e.target.value)} />
              <label className="flex items-center gap-2 text-sm mb-2">
                <input type="checkbox" checked={ehVenda} onChange={e => setEhVenda(e.target.checked)} /> É uma venda
              </label>
              {ehVenda ? (
                <select className="input mb-2" value={vendedorId} onChange={e => setVendedorId(e.target.value)}>
                  <option value="">Vendedor…</option>
                  {vendedores.map(v => <option key={v.id} value={v.id}>{v.nome}{v.papel === 'admin' ? ' (admin)' : ''}</option>)}
                </select>
              ) : (
                <input className="input mb-2" placeholder="Motivo (ex.: perda, avaria)"
                  value={motivo} onChange={e => setMotivo(e.target.value)} />
              )}
              <button className="btn-primary py-2 px-4 text-sm w-full" onClick={saida}>Registrar saída</button>
            </div>
          </div>
        </div>
      )}

      {/* movimentos recentes */}
      <div className="card p-4">
        <h2 className="font-bold mb-2">Movimentos recentes</h2>
        {movs.length === 0 && <div className="text-sm text-[var(--fn-muted)]">Nenhum movimento nesta região.</div>}
        <div className="divide-y divide-[var(--fn-border)]">
          {movs.map((m, i) => {
            const ent = Number(m.quantidade) > 0
            return (
              <div key={i} className="flex items-center justify-between py-2 text-sm gap-3">
                <div className="min-w-0">
                  <div className="font-medium truncate">{m.produto}</div>
                  <div className="text-xs text-[var(--fn-muted)]">
                    {rotuloTipo(m.tipo)}
                    {m.vendedor && ` · vendedor: ${m.vendedor}`}
                    {m.motivo && ` · ${m.motivo}`}
                    {' · '}{new Date(m.quando).toLocaleString('pt-BR')}
                  </div>
                </div>
                <div className={'font-semibold whitespace-nowrap ' + (ent ? 'text-green-700' : 'text-red-600')}>
                  {ent ? '+' : ''}{Number(m.quantidade)}
                </div>
              </div>
            )
          })}
        </div>
      </div>
    </div>
  )
}

function rotuloTipo(t) {
  return { entrada: 'Entrada', venda: 'Venda', ajuste: 'Saída/ajuste',
    transferencia_saida: 'Transf. saída', transferencia_entrada: 'Transf. entrada' }[t] || t
}
