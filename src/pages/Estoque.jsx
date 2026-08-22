import { useEffect, useState } from 'react'
import { supabase } from '../lib/supabase.js'

export default function Estoque() {
  const [aba, setAba] = useState('saldos')
  return (
    <div className="space-y-4">
      <div className="flex gap-1">
        <Tab a={aba} v="saldos" set={setAba}>Saldos & ajustes</Tab>
        <Tab a={aba} v="transfer" set={setAba}>Transferências</Tab>
      </div>
      {aba === 'saldos' ? <Saldos /> : <Transferencias />}
    </div>
  )
}

function Tab({ a, v, set, children }) {
  return (
    <button onClick={() => set(v)}
      className={'px-3 py-2 rounded-lg text-sm font-medium ' +
        (a === v ? 'bg-[var(--fn-brand)] text-white' : 'text-[var(--fn-muted)] hover:bg-gray-100')}>
      {children}
    </button>
  )
}

/* ---------------- Saldos, entrada e ajuste ---------------- */
function Saldos() {
  const [filiais, setFiliais] = useState([])
  const [filialId, setFilialId] = useState('')
  const [busca, setBusca] = useState('')
  const [resultados, setResultados] = useState([])
  const [sel, setSel] = useState(null)   // {id, descricao, saldo}
  const [qtd, setQtd] = useState('')
  const [motivo, setMotivo] = useState('')
  const [msg, setMsg] = useState('')

  useEffect(() => {
    supabase.from('filiais').select('*').eq('ativo', true).order('nome')
      .then(({ data }) => { setFiliais(data || []); setFilialId(data?.[0]?.id || '') })
  }, [])

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
    const { data } = await supabase.from('inventory_balances')
      .select('quantidade').eq('produto_id', p.id).eq('filial_id', filialId).maybeSingle()
    setSel({ id: p.id, descricao: p.descricao, saldo: data?.quantidade ?? 0 })
    setQtd(''); setBusca(''); setResultados([])
  }

  async function entrada() {
    const n = parseFloat(String(qtd).replace(',', '.'))
    if (isNaN(n)) return
    const { error } = await supabase.rpc('fn_entrada_estoque',
      { p_produto: sel.id, p_filial: filialId, p_quantidade: n, p_motivo: motivo })
    finaliza(error, `Entrada de ${n} registrada.`)
  }
  async function ajustar() {
    const n = parseFloat(String(qtd).replace(',', '.'))
    if (isNaN(n)) return
    const { error } = await supabase.rpc('fn_ajustar_estoque',
      { p_produto: sel.id, p_filial: filialId, p_quantidade_contada: n, p_motivo: motivo })
    finaliza(error, `Saldo ajustado para ${n}.`)
  }
  async function finaliza(error, ok) {
    if (error) { setMsg('Erro: ' + error.message); return }
    setMsg('✅ ' + ok)
    await escolher({ id: sel.id, descricao: sel.descricao })  // recarrega saldo
    setMotivo('')
  }

  return (
    <div className="card p-4 space-y-3">
      <select className="input sm:w-64" value={filialId} onChange={e => setFilialId(e.target.value)}>
        {filiais.map(f => <option key={f.id} value={f.id}>{f.nome}</option>)}
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

      {sel && (
        <div className="bg-gray-50 rounded-lg p-3">
          <div className="font-medium">{sel.descricao}</div>
          <div className="text-sm text-[var(--fn-muted)] mb-3">Saldo atual nesta filial: <b>{sel.saldo}</b></div>
          <div className="grid sm:grid-cols-2 gap-2">
            <input className="input" placeholder="Quantidade" value={qtd} onChange={e => setQtd(e.target.value)} />
            <input className="input" placeholder="Motivo (opcional)" value={motivo} onChange={e => setMotivo(e.target.value)} />
          </div>
          <div className="flex gap-2 mt-2">
            <button className="btn-primary py-2 px-3 text-sm" onClick={entrada}>Entrada (+)</button>
            <button className="py-2 px-3 text-sm rounded-lg border border-[var(--fn-border)]" onClick={ajustar}>
              Ajustar p/ inventário (=)
            </button>
          </div>
          <p className="text-xs text-[var(--fn-muted)] mt-2">
            Entrada soma ao saldo. Ajuste define o saldo para a quantidade contada (inventário, perda, avaria).
          </p>
        </div>
      )}
      {msg && <div className="text-sm bg-gray-50 rounded-lg p-3">{msg}</div>}
    </div>
  )
}

/* ---------------- Transferências ---------------- */
function Transferencias() {
  const [filiais, setFiliais] = useState([])
  const [lista, setLista] = useState([])
  const [origem, setOrigem] = useState('')
  const [destino, setDestino] = useState('')
  const [busca, setBusca] = useState('')
  const [resultados, setResultados] = useState([])
  const [itens, setItens] = useState([])
  const [msg, setMsg] = useState('')

  async function carregar() {
    const { data } = await supabase.from('transfers')
      .select('id, estado, created_at, origem:origem_id(nome), destino:destino_id(nome), transfer_items(quantidade)')
      .order('created_at', { ascending: false }).limit(20)
    setLista(data || [])
  }
  useEffect(() => {
    supabase.from('filiais').select('*').eq('ativo', true).order('nome')
      .then(({ data }) => { setFiliais(data || []); setOrigem(data?.[0]?.id || ''); setDestino(data?.[1]?.id || '') })
    carregar()
  }, [])

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

  async function criar() {
    if (!origem || !destino || origem === destino) { setMsg('Escolha origem e destino diferentes.'); return }
    if (itens.length === 0) { setMsg('Adicione ao menos um produto.'); return }
    const { data: t, error } = await supabase.from('transfers')
      .insert({ origem_id: origem, destino_id: destino, estado: 'em_montagem' }).select('id').single()
    if (error) { setMsg('Erro: ' + error.message); return }
    await supabase.from('transfer_items').insert(
      itens.map(i => ({ transfer_id: t.id, produto_id: i.id, quantidade: Number(i.quantidade) || 0 })))
    setItens([]); setMsg('✅ Transferência criada (em montagem).'); carregar()
  }
  async function enviar(id) { const { error } = await supabase.rpc('fn_enviar_transferencia', { p_transfer: id }); act(error, 'Enviada — estoque saiu da origem.') }
  async function receber(id) { const { error } = await supabase.rpc('fn_receber_transferencia', { p_transfer: id }); act(error, 'Recebida — estoque entrou no destino.') }
  function act(error, ok) { setMsg(error ? 'Erro: ' + error.message : '✅ ' + ok); carregar() }

  return (
    <div className="space-y-4">
      <div className="card p-4">
        <h2 className="font-bold mb-2">Nova transferência</h2>
        <div className="grid sm:grid-cols-2 gap-2 mb-2">
          <select className="input" value={origem} onChange={e => setOrigem(e.target.value)}>
            {filiais.map(f => <option key={f.id} value={f.id}>De: {f.nome}</option>)}
          </select>
          <select className="input" value={destino} onChange={e => setDestino(e.target.value)}>
            {filiais.map(f => <option key={f.id} value={f.id}>Para: {f.nome}</option>)}
          </select>
        </div>
        <div className="relative mb-2">
          <input className="input" placeholder="Adicionar produto…" value={busca} onChange={e => setBusca(e.target.value)} />
          {resultados.length > 0 && (
            <div className="absolute z-20 mt-1 w-full card max-h-72 overflow-auto">
              {resultados.map(p => (
                <button key={p.id} onClick={() => { if (!itens.some(i => i.id === p.id)) setItens(c => [...c, { id: p.id, descricao: p.descricao, quantidade: 1 }]); setBusca(''); setResultados([]) }}
                  className="block w-full text-left px-3 py-2 hover:bg-gray-50 border-b border-[var(--fn-border)] last:border-0 text-sm">
                  {p.descricao}
                </button>
              ))}
            </div>
          )}
        </div>
        {itens.map(i => (
          <div key={i.id} className="flex items-center gap-2 py-1 text-sm">
            <span className="flex-1">{i.descricao}</span>
            <input className="input w-20" type="number" min="0" value={i.quantidade}
              onChange={e => setItens(c => c.map(x => x.id === i.id ? { ...x, quantidade: e.target.value } : x))} />
            <button className="text-red-500" onClick={() => setItens(c => c.filter(x => x.id !== i.id))}>×</button>
          </div>
        ))}
        <button className="btn-primary py-2 px-4 text-sm mt-2" onClick={criar}>Criar transferência</button>
      </div>

      {msg && <div className="card p-3 text-sm">{msg}</div>}

      <div className="card p-4">
        <h2 className="font-bold mb-2">Transferências</h2>
        {lista.length === 0 && <div className="text-sm text-[var(--fn-muted)]">Nenhuma ainda.</div>}
        <div className="divide-y divide-[var(--fn-border)]">
          {lista.map(t => (
            <div key={t.id} className="flex items-center justify-between py-2 text-sm">
              <div>
                <div className="font-medium">{t.origem?.nome} → {t.destino?.nome}</div>
                <div className="text-xs text-[var(--fn-muted)]">
                  {t.transfer_items?.length || 0} item(ns) · <EstadoBadge e={t.estado} />
                </div>
              </div>
              <div className="flex gap-2">
                {(t.estado === 'rascunho' || t.estado === 'em_montagem') &&
                  <button className="btn-primary py-1.5 px-3 text-xs" onClick={() => enviar(t.id)}>Enviar</button>}
                {t.estado === 'enviada' &&
                  <button className="btn-primary py-1.5 px-3 text-xs" onClick={() => receber(t.id)}>Receber</button>}
              </div>
            </div>
          ))}
        </div>
      </div>
    </div>
  )
}

function EstadoBadge({ e }) {
  const cor = { rascunho: 'bg-gray-100 text-gray-600', em_montagem: 'bg-blue-50 text-blue-700',
    enviada: 'bg-amber-50 text-amber-700', recebida: 'bg-green-50 text-green-700',
    cancelada: 'bg-red-50 text-red-700' }[e] || 'bg-gray-100'
  return <span className={'px-2 py-0.5 rounded-full ' + cor}>{e}</span>
}
