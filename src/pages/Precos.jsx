import { useEffect, useMemo, useState, useCallback } from 'react'
import { supabase } from '../lib/supabase.js'

const nf = new Intl.NumberFormat('pt-BR', { maximumFractionDigits: 0 })
const num = v => { const n = parseFloat(String(v).replace(/\./g, '').replace(',', '.')); return isNaN(n) ? null : n }
const numDot = v => { const n = parseFloat(String(v).replace(',', '.')); return isNaN(n) ? null : n }

export default function Precos() {
  const [regioes, setRegioes] = useState([])
  const [cols, setCols] = useState([])            // regiões visíveis (colunas)
  const [produtos, setProdutos] = useState([])
  const [overrides, setOverrides] = useState({})  // [`${prod}:${reg}`] = indice
  const [precos, setPrecos] = useState({})        // [`${prod}:${reg}`] = preco
  const [busca, setBusca] = useState('')
  const [sel, setSel] = useState(new Set())       // seleção p/ massa
  const [msg, setMsg] = useState('')
  const [impostosDe, setImpostosDe] = useState(null) // região aberta no gerenciador

  const flash = t => { setMsg(t); setTimeout(() => setMsg(''), 2500) }

  const carregarRegioes = useCallback(async () => {
    const { data } = await supabase.from('regioes').select('*').eq('ativo', true).order('ordem')
    setRegioes(data || [])
    setCols(c => c.length ? c : (data || []).slice(0, 3).map(r => r.id))
  }, [])

  const carregarProdutos = useCallback(async () => {
    const { data } = await supabase.from('produtos')
      .select('id, descricao, tabela_bruta, multiplicador_desconto, custo_atual, travado, tipo_preco, marcas(nome), categorias(nome)')
      .order('descricao')
    setProdutos(data || [])
    const { data: ov } = await supabase.from('produto_indice_regiao').select('produto_id, regiao_id, indice')
    const m = {}; (ov || []).forEach(o => { m[`${o.produto_id}:${o.regiao_id}`] = o.indice })
    setOverrides(m)
  }, [])

  const carregarPrecos = useCallback(async (regsIds) => {
    if (!regsIds || regsIds.length === 0) { setPrecos({}); return }
    const { data } = await supabase.rpc('fn_catalogo_multi', { p_regioes: regsIds })
    const m = {}; (data || []).forEach(r => { m[`${r.produto_id}:${r.regiao_id}`] = r.preco })
    setPrecos(m)
  }, [])

  useEffect(() => { carregarRegioes(); carregarProdutos() }, [carregarRegioes, carregarProdutos])
  useEffect(() => { carregarPrecos(cols) }, [cols, carregarPrecos])

  const colunas = useMemo(() => regioes.filter(r => cols.includes(r.id)), [regioes, cols])
  const indiceEfetivo = (p, r) => {
    const o = overrides[`${p}:${r.id}`]
    return o != null ? Number(o) : Number(r.indice_padrao)
  }

  const filtrados = useMemo(() => {
    const q = busca.trim().toLowerCase()
    if (!q) return produtos
    return produtos.filter(p => [p.descricao, p.marcas?.nome, p.categorias?.nome]
      .filter(Boolean).some(x => String(x).toLowerCase().includes(q)))
  }, [produtos, busca])

  // ---- edições ----
  async function salvarCustoPorTabela(p, tabela, mult) {
    await supabase.rpc('fn_definir_custo', { p_produto: p.id, p_tabela: tabela, p_mult: mult })
    await carregarProdutos(); await carregarPrecos(cols); flash('Custo atualizado')
  }
  async function salvarCustoDireto(p, custo) {
    await supabase.rpc('fn_aplicar_compra', { p_itens: [{ produto_id: p.id, custo }], p_origem: 'ajuste manual' })
    await carregarProdutos(); await carregarPrecos(cols); flash('Custo atualizado')
  }
  async function salvarTaxaRegiao(r, pct) {          // regra geral da região
    await supabase.from('regioes').update({ indice_padrao: pct / 100 }).eq('id', r.id)
    await carregarRegioes(); await carregarPrecos(cols); flash(`Taxa de ${r.nome} salva`)
  }
  async function salvarExcecao(p, r, pct) {          // exceção do produto na região
    if (pct == null) {
      await supabase.from('produto_indice_regiao').delete().eq('produto_id', p.id).eq('regiao_id', r.id)
    } else {
      await supabase.from('produto_indice_regiao')
        .upsert({ produto_id: p.id, regiao_id: r.id, indice: pct / 100 }, { onConflict: 'produto_id,regiao_id' })
    }
    await carregarProdutos(); await carregarPrecos(cols); flash('Exceção salva')
  }
  async function alternarTravado(p) {
    await supabase.from('produtos').update({ travado: !p.travado }).eq('id', p.id)
    await carregarProdutos(); flash(p.travado ? 'Linha destravada' : 'Linha travada')
  }

  // ---- massa ----
  const [massaPct, setMassaPct] = useState('')
  const [massaReg, setMassaReg] = useState('')
  useEffect(() => { if (!massaReg && colunas[0]) setMassaReg(colunas[0].id) }, [colunas, massaReg])
  async function aplicarMassa() {
    const pct = numDot(massaPct); if (pct == null || !massaReg) return
    const alvo = filtrados.filter(p => sel.has(p.id) && !p.travado)
    if (alvo.length === 0) { flash('Nenhum produto selecionado (ou todos travados)'); return }
    await supabase.from('produto_indice_regiao').upsert(
      alvo.map(p => ({ produto_id: p.id, regiao_id: massaReg, indice: pct / 100 })),
      { onConflict: 'produto_id,regiao_id' })
    setSel(new Set()); setMassaPct('')
    await carregarProdutos(); await carregarPrecos(cols)
    flash(`Taxa aplicada a ${alvo.length} produto(s)`)
  }

  function toggleSel(id) { setSel(s => { const n = new Set(s); n.has(id) ? n.delete(id) : n.add(id); return n }) }

  return (
    <div>
      {msg && <div className="fixed top-16 right-4 bg-[var(--fn-brand)] text-white px-4 py-2 rounded-lg shadow z-30">{msg}</div>}

      {/* barra de massa */}
      <div className="flex flex-wrap items-center gap-2 mb-3">
        <input className="input flex-1 min-w-[180px]" placeholder="Buscar produto…" value={busca} onChange={e => setBusca(e.target.value)} />
        <div className="flex items-center gap-2 text-sm">
          <span className="text-[var(--fn-muted)]">{sel.size} selec.</span>
          <input className="input w-24" placeholder="taxa %" value={massaPct} onChange={e => setMassaPct(e.target.value)} />
          <select className="input w-40" value={massaReg} onChange={e => setMassaReg(e.target.value)}>
            {colunas.map(r => <option key={r.id} value={r.id}>{r.nome}</option>)}
          </select>
          <button className="btn-primary py-2 px-3" onClick={aplicarMassa} disabled={sel.size === 0}>Aplicar em massa</button>
        </div>
      </div>

      {/* seleção de regiões visíveis */}
      <div className="flex gap-1.5 overflow-x-auto pb-2 mb-1 items-center">
        <span className="text-xs text-[var(--fn-muted)] shrink-0">Regiões:</span>
        {regioes.map(r => {
          const on = cols.includes(r.id)
          return (
            <button key={r.id} onClick={() => setCols(c => on ? c.filter(x => x !== r.id) : [...c, r.id])}
              className={'shrink-0 px-3 py-1 rounded-full text-xs border ' +
                (on ? 'bg-[var(--fn-brand)] text-white border-[var(--fn-brand)]' : 'bg-white text-[var(--fn-muted)] border-[var(--fn-border)]')}>
              {r.nome}
            </button>
          )
        })}
      </div>

      {impostosDe && <GerenciadorImpostos regiao={regioes.find(r => r.id === impostosDe)}
        onClose={() => setImpostosDe(null)} onChange={() => carregarPrecos(cols)} />}

      <div className="card p-0 overflow-x-auto">
        <table className="text-sm border-collapse" style={{ minWidth: 420 + colunas.length * 210 }}>
          <thead>
            <tr className="text-[var(--fn-muted)]">
              <th className="p-2 border-b border-[var(--fn-border)]"></th>
              <th className="text-left p-2 font-medium border-b border-[var(--fn-border)]">Produto</th>
              <th className="p-2 font-medium border-b border-[var(--fn-border)]">Tabela bruta</th>
              <th className="p-2 font-medium border-b border-[var(--fn-border)]">% desc</th>
              <th className="p-2 font-medium border-b border-[var(--fn-border)]">Custo</th>
              {colunas.map(r => (
                <th key={r.id} colSpan={2} className="p-2 font-medium text-center bg-gray-50 border-l border-b border-[var(--fn-border)]">
                  <div className="flex items-center justify-center gap-1.5">
                    <span>{r.nome}</span>
                    <EditHeader r={r} onSave={salvarTaxaRegiao} />
                    <button title="impostos/taxas" onClick={() => setImpostosDe(r.id)} className="text-[var(--fn-brand)]">+ imposto</button>
                  </div>
                </th>
              ))}
            </tr>
            <tr className="text-[var(--fn-muted)] text-[11px]">
              <th className="p-1 border-b border-[var(--fn-border)]"></th>
              <th colSpan={4} className="border-b border-[var(--fn-border)]"></th>
              {colunas.map(r => (
                <FragTaxaHead key={r.id} />
              ))}
            </tr>
          </thead>
          <tbody>
            {filtrados.slice(0, 200).map(p => (
              <tr key={p.id} className={'border-t border-[var(--fn-border)] ' + (p.travado ? 'bg-amber-50' : '')}>
                <td className="p-2 text-center">
                  {p.travado
                    ? <button title="travado — clique p/ destravar" onClick={() => alternarTravado(p)} className="text-amber-600">🔒</button>
                    : <input type="checkbox" checked={sel.has(p.id)} onChange={() => toggleSel(p.id)} />}
                </td>
                <td className="p-2">
                  <div className="font-medium leading-snug min-w-[180px]">{p.descricao}</div>
                  <div className="text-xs text-[var(--fn-muted)]">
                    {[p.marcas?.nome, p.categorias?.nome].filter(Boolean).join(' · ')}
                    <button onClick={() => alternarTravado(p)} className="ml-2 text-[var(--fn-muted)] underline">{p.travado ? 'destravar' : 'travar'}</button>
                  </div>
                </td>
                <CelEdit valor={p.tabela_bruta} fmt={v => v == null ? '—' : nf.format(v)}
                  onSave={v => salvarCustoPorTabela(p, num(v), p.multiplicador_desconto || 0)} />
                <CelEdit valor={p.multiplicador_desconto == null ? null : p.multiplicador_desconto * 100}
                  fmt={v => v == null ? '—' : v.toLocaleString('pt-BR', { maximumFractionDigits: 2 }) + '%'}
                  onSave={v => salvarCustoPorTabela(p, p.tabela_bruta, numDot(v) / 100)} />
                <CelEdit valor={p.custo_atual} fmt={v => v == null ? '—' : nf.format(v)} forte
                  onSave={v => salvarCustoDireto(p, num(v))} />
                {colunas.map(r => {
                  const ind = indiceEfetivo(p, r)
                  const exc = overrides[`${p.id}:${r.id}`] != null
                  const preco = precos[`${p.id}:${r.id}`]
                  return (
                    <FragTaxa key={r.id} ind={ind} exc={exc} preco={preco}
                      onSave={v => salvarExcecao(p, r, v === '' ? null : numDot(v))} />
                  )
                })}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <div className="flex flex-wrap gap-3 text-xs text-[var(--fn-muted)] mt-2">
        <span>clique num valor pra editar</span>
        <span className="text-green-700">↗ aumento</span>
        <span className="text-red-600">↘ diminuição</span>
        <span>🔒 trava a linha na edição em massa</span>
        {filtrados.length > 200 && <span>mostrando 200 de {filtrados.length} — refine a busca</span>}
      </div>
    </div>
  )
}

/* célula editável genérica (clique → input → salva no blur/Enter) */
function CelEdit({ valor, fmt, onSave, forte }) {
  const [edit, setEdit] = useState(false)
  const [v, setV] = useState('')
  function abrir() { setV(valor == null ? '' : String(valor).replace('.', ',')); setEdit(true) }
  function salvar() { setEdit(false); if (v !== '') onSave(v) }
  return (
    <td className="p-2 text-right whitespace-nowrap border-l border-[var(--fn-border)]">
      {edit
        ? <input autoFocus className="input w-24 text-right py-1" value={v}
            onChange={e => setV(e.target.value)} onBlur={salvar}
            onKeyDown={e => e.key === 'Enter' && salvar()} />
        : <button onClick={abrir} className={'hover:underline ' + (forte ? 'font-semibold' : '')}>{fmt(valor)}</button>}
    </td>
  )
}

function FragTaxaHead() {
  return (
    <>
      <th className="p-1 font-normal text-right bg-gray-50 border-l border-b border-[var(--fn-border)]">Taxa</th>
      <th className="p-1 font-normal text-right bg-gray-50 border-b border-[var(--fn-border)]">Preço final</th>
    </>
  )
}

function FragTaxa({ ind, exc, preco, onSave }) {
  const [edit, setEdit] = useState(false)
  const [v, setV] = useState('')
  const pct = Math.round(ind * 1000) / 10
  function abrir() { setV(String(pct).replace('.', ',')); setEdit(true) }
  function salvar() { setEdit(false); onSave(v) }
  const cor = ind < 0 ? 'text-red-600' : 'text-green-700'
  return (
    <>
      <td className="p-2 text-right border-l border-[var(--fn-border)] whitespace-nowrap">
        {edit
          ? <input autoFocus className="input w-16 text-right py-1" value={v}
              onChange={e => setV(e.target.value)} onBlur={salvar}
              onKeyDown={e => e.key === 'Enter' && salvar()} placeholder="%" />
          : <button onClick={abrir} className={cor} title={exc ? 'exceção deste produto' : 'regra geral da região'}>
              {ind >= 0 ? '↗ +' : '↘ '}{pct}%{exc ? ' *' : ''}
            </button>}
      </td>
      <td className="p-2 text-right font-semibold text-[var(--fn-brand)] whitespace-nowrap">
        {preco == null ? '—' : nf.format(preco)}
      </td>
    </>
  )
}

/* editar a taxa geral da região no cabeçalho */
function EditHeader({ r, onSave }) {
  const [edit, setEdit] = useState(false)
  const [v, setV] = useState('')
  const pct = Math.round(r.indice_padrao * 1000) / 10
  return edit
    ? <input autoFocus className="input w-16 py-0.5 text-xs" value={v} onChange={e => setV(e.target.value)}
        onBlur={() => { setEdit(false); const n = numDot(v); if (n != null) onSave(r, n) }}
        onKeyDown={e => e.key === 'Enter' && e.currentTarget.blur()} />
    : <button className="text-[var(--fn-muted)]" onClick={() => { setV(String(pct).replace('.', ',')); setEdit(true) }} title="taxa geral da região">✎ {pct}%</button>
}

/* gerenciador de impostos/taxas nomeáveis por região (componentes_preco) */
function GerenciadorImpostos({ regiao, onClose, onChange }) {
  const [lista, setLista] = useState([])
  const [nome, setNome] = useState('')
  const [tipo, setTipo] = useState('imposto')
  const [valor, setValor] = useState('')

  async function carregar() {
    const { data } = await supabase.from('componentes_preco').select('*')
      .eq('regiao_id', regiao.id).order('ordem')
    setLista(data || [])
  }
  useEffect(() => { carregar() }, [regiao.id])

  async function adicionar() {
    if (!nome.trim()) return
    const raw = numDot(valor); if (raw == null) return
    await supabase.from('componentes_preco').insert({
      nome: nome.trim(), tipo, valor: raw / 100, regiao_id: regiao.id, ordem: 100,
    })
    setNome(''); setValor(''); await carregar(); onChange()
  }
  async function remover(id) {
    await supabase.from('componentes_preco').delete().eq('id', id); await carregar(); onChange()
  }

  return (
    <div className="card p-4 mb-3">
      <div className="flex items-center justify-between mb-2">
        <h3 className="font-bold">Impostos e taxas — {regiao.nome}</h3>
        <button onClick={onClose} className="text-[var(--fn-muted)]">fechar ×</button>
      </div>
      <div className="divide-y divide-[var(--fn-border)] mb-3">
        {lista.length === 0 && <div className="text-sm text-[var(--fn-muted)] py-1">Nenhum ainda.</div>}
        {lista.map(c => (
          <div key={c.id} className="flex items-center justify-between py-1.5 text-sm">
            <span>{c.nome} <span className="text-[var(--fn-muted)]">· {c.tipo} {(c.valor * 100).toLocaleString('pt-BR')}%</span></span>
            <button className="text-red-500" onClick={() => remover(c.id)}>remover</button>
          </div>
        ))}
      </div>
      <div className="flex flex-wrap gap-2">
        <input className="input flex-1 min-w-[140px]" placeholder="Nome (ex.: ICMS, Frete)" value={nome} onChange={e => setNome(e.target.value)} />
        <select className="input w-36" value={tipo} onChange={e => setTipo(e.target.value)}>
          <option value="imposto">Imposto (+%)</option>
          <option value="percentual">Taxa (+%)</option>
          <option value="desconto">Desconto (−%)</option>
        </select>
        <input className="input w-28" placeholder="valor %" value={valor} onChange={e => setValor(e.target.value)} />
        <button className="btn-primary py-2 px-4" onClick={adicionar}>Adicionar</button>
      </div>
    </div>
  )
}
