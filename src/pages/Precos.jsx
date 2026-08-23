import { useEffect, useMemo, useState, useCallback, useRef } from 'react'
import { supabase } from '../lib/supabase.js'
import Pagamentos from './Pagamentos.jsx'

const nf = new Intl.NumberFormat('pt-BR', { maximumFractionDigits: 0 })
const num = v => { const n = parseFloat(String(v).replace(/\./g, '').replace(',', '.')); return isNaN(n) ? null : n }
const numDot = v => { const n = parseFloat(String(v).replace(',', '.')); return isNaN(n) ? null : n }

export default function Precos() {
  const [regioes, setRegioes] = useState([])
  const [cols, setCols] = useState([])
  const [produtos, setProdutos] = useState([])
  const [overrides, setOverrides] = useState({})
  const [precos, setPrecos] = useState({})
  const [fator, setFator] = useState(0.4288)
  const [busca, setBusca] = useState('')
  const [sel, setSel] = useState(new Set())
  const [msg, setMsg] = useState('')
  const [impostosDe, setImpostosDe] = useState(null)

  const flash = t => { setMsg(t); setTimeout(() => setMsg(''), 2500) }

  const carregarRegioes = useCallback(async () => {
    const { data } = await supabase.from('regioes').select('*').eq('ativo', true).order('ordem')
    setRegioes(data || [])
    setCols(c => c.length ? c : (data || []).map(r => r.id))   // TODAS por padrão
  }, [])

  const carregarProdutos = useCallback(async () => {
    const { data } = await supabase.from('produtos')
      .select('id, codigo, descricao, tabela_bruta, multiplicador_desconto, custo_atual, travado, tipo_preco, marcas(nome), categorias(nome)')
      .order('descricao')
    setProdutos(data || [])
    const { data: ov } = await supabase.from('produto_indice_regiao').select('produto_id, regiao_id, indice')
    const m = {}; (ov || []).forEach(o => { m[`${o.produto_id}:${o.regiao_id}`] = o.indice }); setOverrides(m)
    const { data: cfg } = await supabase.from('config_precificacao').select('valor_num').eq('chave', 'fator_custo_padrao').maybeSingle()
    if (cfg?.valor_num) setFator(Number(cfg.valor_num))
  }, [])

  const carregarPrecos = useCallback(async (regsIds) => {
    if (!regsIds || regsIds.length === 0) { setPrecos({}); return }
    // grade do admin: preço CALCULADO de todos os produtos (o motor sempre calcula)
    const { data } = await supabase.rpc('fn_grade_precos', { p_regioes: regsIds })
    const m = {}; (data || []).forEach(r => { m[`${r.produto_id}:${r.regiao_id}`] = r.preco_calculado }); setPrecos(m)
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

  async function salvarCustoPorTabela(p, tabela, mult) {
    const m = (mult && mult > 0) ? mult : fator      // % padrão = fator global quando vazio
    await supabase.rpc('fn_definir_custo', { p_produto: p.id, p_tabela: tabela, p_mult: m })
    await carregarProdutos(); await carregarPrecos(cols); flash('Custo atualizado')
  }
  async function salvarCustoDireto(p, custo) {
    await supabase.rpc('fn_aplicar_compra', { p_itens: [{ produto_id: p.id, custo }], p_origem: 'ajuste manual' })
    await carregarProdutos(); await carregarPrecos(cols); flash('Custo atualizado')
  }
  async function salvarTaxaRegiao(r, frac) {
    await supabase.from('regioes').update({ indice_padrao: frac }).eq('id', r.id)
    await carregarRegioes(); await carregarPrecos(cols); flash(`Taxa de ${r.nome} salva`)
  }
  async function salvarExcecao(p, r, frac) {
    if (frac == null) {
      await supabase.from('produto_indice_regiao').delete().eq('produto_id', p.id).eq('regiao_id', r.id)
    } else {
      await supabase.from('produto_indice_regiao')
        .upsert({ produto_id: p.id, regiao_id: r.id, indice: frac }, { onConflict: 'produto_id,regiao_id' })
    }
    await carregarProdutos(); await carregarPrecos(cols); flash('Exceção salva')
  }
  async function alternarTravado(p) {
    await supabase.from('produtos').update({ travado: !p.travado }).eq('id', p.id)
    await carregarProdutos(); flash(p.travado ? 'Linha destravada' : 'Linha travada')
  }

  const [massaAberta, setMassaAberta] = useState(false)
  const [massaPct, setMassaPct] = useState('')
  const [massaSinal, setMassaSinal] = useState('+')
  const [massaReg, setMassaReg] = useState('')
  const [massaDesc, setMassaDesc] = useState('')
  useEffect(() => { if (!massaReg && colunas[0]) setMassaReg(colunas[0].id) }, [colunas, massaReg])

  async function aplicarMassa() {
    const pct = numDot(massaPct); if (pct == null || !massaReg) return
    const frac = (massaSinal === '-' ? -Math.abs(pct) : Math.abs(pct)) / 100
    const alvo = filtrados.filter(p => sel.has(p.id) && !p.travado)
    if (alvo.length === 0) { flash('Nenhum produto selecionado (ou todos travados)'); return }
    await supabase.from('produto_indice_regiao').upsert(
      alvo.map(p => ({ produto_id: p.id, regiao_id: massaReg, indice: frac })), { onConflict: 'produto_id,regiao_id' })
    setMassaPct(''); setMassaAberta(false); setSel(new Set())
    await carregarProdutos(); await carregarPrecos(cols); flash(`Taxa aplicada a ${alvo.length} produto(s)`)
  }
  async function aplicarMassaDesconto() {
    const pct = numDot(massaDesc); if (pct == null) return
    const ids = filtrados.filter(p => sel.has(p.id) && !p.travado).map(p => p.id)
    if (ids.length === 0) { flash('Nenhum produto selecionado (ou todos travados)'); return }
    const { data, error } = await supabase.rpc('fn_mult_massa', { p_ids: ids, p_mult: pct / 100 })
    if (error) { flash('Erro: ' + error.message); return }
    setMassaDesc(''); setMassaAberta(false); setSel(new Set())
    await carregarProdutos(); await carregarPrecos(cols); flash(`% desconto aplicado a ${data} produto(s)`)
  }
  function toggleSel(id) { setSel(s => { const n = new Set(s); n.has(id) ? n.delete(id) : n.add(id); return n }) }
  const selecionaveis = filtrados.filter(p => !p.travado)
  const todosSel = selecionaveis.length > 0 && selecionaveis.every(p => sel.has(p.id))
  function toggleTodos() { setSel(todosSel ? new Set() : new Set(selecionaveis.map(p => p.id))) }

  // barra de rolagem no TOPO, sincronizada com a tabela
  const topRef = useRef(null), tblRef = useRef(null)
  const larguraTabela = 460 + colunas.length * 210
  function syncFromTop() { if (tblRef.current && topRef.current) tblRef.current.scrollLeft = topRef.current.scrollLeft }
  function syncFromTbl() { if (tblRef.current && topRef.current) topRef.current.scrollLeft = tblRef.current.scrollLeft }

  const stickyL = { position: 'sticky', left: 0, background: '#fff', zIndex: 1 }
  const stickyL2 = { position: 'sticky', left: 40, background: '#fff', zIndex: 1 }

  return (
    <div>
      {msg && <div className="fixed top-16 right-4 bg-[var(--fn-brand)] text-white px-4 py-2 rounded-lg shadow z-30">{msg}</div>}

      {massaAberta && (
        <div className="fixed inset-0 bg-black/40 flex items-center justify-center z-40 p-4" onClick={() => setMassaAberta(false)}>
          <div className="card p-5 w-full max-w-md" onClick={e => e.stopPropagation()}>
            <div className="flex items-center justify-between mb-3">
              <h3 className="font-bold">Ações em massa — {sel.size} produto(s)</h3>
              <button onClick={() => setMassaAberta(false)} className="text-[var(--fn-muted)] text-xl">×</button>
            </div>

            <div className="mb-4">
              <div className="text-sm font-medium mb-1">% de desconto (custo)</div>
              <div className="text-xs text-[var(--fn-muted)] mb-2">Aplica o MULTIPLDESCON e recalcula o custo (tabela × %).</div>
              <div className="flex gap-2">
                <input className="input w-28" placeholder="ex.: 42,156" value={massaDesc} onChange={e => setMassaDesc(e.target.value)} />
                <span className="self-center text-[var(--fn-muted)]">%</span>
                <button className="btn-primary py-2 px-4" onClick={aplicarMassaDesconto}>Aplicar</button>
              </div>
            </div>

            <div className="border-t border-[var(--fn-border)] pt-4">
              <div className="text-sm font-medium mb-1">Taxa de uma região</div>
              <div className="text-xs text-[var(--fn-muted)] mb-2">Define a taxa (índice) dos selecionados numa região.</div>
              <div className="flex flex-wrap gap-2">
                <div className="flex rounded-lg border border-[var(--fn-border)] overflow-hidden">
                  <button onClick={() => setMassaSinal('+')} className={'px-3 py-2 ' + (massaSinal === '+' ? 'bg-[var(--fn-brand)] text-white' : '')}>+</button>
                  <button onClick={() => setMassaSinal('-')} className={'px-3 py-2 ' + (massaSinal === '-' ? 'bg-red-600 text-white' : '')}>−</button>
                </div>
                <input className="input w-20" placeholder="taxa %" value={massaPct} onChange={e => setMassaPct(e.target.value)} />
                <select className="input flex-1 min-w-[140px]" value={massaReg} onChange={e => setMassaReg(e.target.value)}>
                  {colunas.map(r => <option key={r.id} value={r.id}>{r.nome}</option>)}
                </select>
                <button className="btn-primary py-2 px-4" onClick={aplicarMassa}>Aplicar</button>
              </div>
            </div>

            <p className="text-xs text-[var(--fn-muted)] mt-3">Linhas travadas 🔒 não são alteradas.</p>
          </div>
        </div>
      )}

      <details className="card p-0 mb-4">
        <summary className="p-3 font-medium cursor-pointer select-none">Descontos por tipo de pagamento</summary>
        <div className="px-3 pb-3 border-t border-[var(--fn-border)]"><Pagamentos embutido /></div>
      </details>

      <details className="card p-0 mb-4">
        <summary className="p-3 font-medium cursor-pointer select-none">Gerenciar regiões</summary>
        <div className="px-3 pb-3 border-t border-[var(--fn-border)]">
          <RegioesManager regioes={regioes} onChange={() => { carregarRegioes(); carregarProdutos() }} flash={flash} />
        </div>
      </details>

      <div className="flex items-center gap-2 mb-3">
        <input className="input flex-1" placeholder="Buscar produto…" value={busca} onChange={e => setBusca(e.target.value)} />
        <span className="text-sm text-[var(--fn-muted)] whitespace-nowrap">{sel.size} selec.</span>
        <button className="py-2 px-4 rounded-lg border border-[var(--fn-border)] whitespace-nowrap disabled:opacity-40"
          onClick={() => setMassaAberta(true)} disabled={sel.size === 0}>Ações em massa</button>
      </div>

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
      <div className="text-xs text-[var(--fn-muted)] mb-1">← use a barra de rolagem (em cima ou embaixo) para ver todas as regiões →</div>

      {impostosDe && <GerenciadorMult regiao={regioes.find(r => r.id === impostosDe)}
        onClose={() => setImpostosDe(null)} onChange={() => carregarPrecos(cols)} />}

      {/* barra de rolagem no topo, sincronizada com a tabela */}
      <div ref={topRef} onScroll={syncFromTop} style={{ overflowX: 'auto', overflowY: 'hidden' }} className="mb-1">
        <div style={{ width: larguraTabela, height: 1 }} />
      </div>

      <div ref={tblRef} onScroll={syncFromTbl} className="card p-0" style={{ overflowX: 'scroll' }}>
        <table className="text-sm border-collapse" style={{ minWidth: larguraTabela }}>
          <thead>
            <tr className="text-[var(--fn-muted)]">
              <th style={stickyL} className="p-2 border-b border-[var(--fn-border)] text-center">
                <input type="checkbox" checked={todosSel} onChange={toggleTodos} title="selecionar todos" />
              </th>
              <th style={stickyL2} className="text-left p-2 font-medium border-b border-[var(--fn-border)]">Produto</th>
              <th className="p-2 font-medium border-b border-[var(--fn-border)]">Tabela bruta</th>
              <th className="p-2 font-medium border-b border-[var(--fn-border)]">% desc</th>
              <th className="p-2 font-medium border-b border-[var(--fn-border)]">Custo</th>
              {colunas.map(r => (
                <th key={r.id} colSpan={2} className="p-2 font-medium text-center bg-gray-50 border-l border-b border-[var(--fn-border)]">
                  <div className="flex items-center justify-center gap-1.5 whitespace-nowrap">
                    <span>{r.nome}</span>
                    <EditHeader r={r} onSave={salvarTaxaRegiao} />
                    <button onClick={() => setImpostosDe(r.id)} className="text-[var(--fn-brand)]">+ MULT</button>
                  </div>
                </th>
              ))}
            </tr>
            <tr className="text-[var(--fn-muted)] text-[11px]">
              <th style={stickyL} className="p-1 border-b border-[var(--fn-border)]"></th>
              <th style={stickyL2} className="border-b border-[var(--fn-border)]"></th>
              <th colSpan={3} className="border-b border-[var(--fn-border)]"></th>
              {colunas.map(r => <FragTaxaHead key={r.id} />)}
            </tr>
          </thead>
          <tbody>
            {filtrados.slice(0, 200).map(p => {
              return (
                <tr key={p.id} className={'border-t border-[var(--fn-border)] ' + (p.travado ? 'bg-amber-50' : '')}>
                  <td style={{ ...stickyL, background: p.travado ? '#fffbeb' : '#fff' }} className="p-2 text-center">
                    {p.travado
                      ? <button title="travado — clique p/ destravar" onClick={() => alternarTravado(p)} className="text-amber-600">🔒</button>
                      : <input type="checkbox" checked={sel.has(p.id)} onChange={() => toggleSel(p.id)} />}
                  </td>
                  <td style={{ ...stickyL2, background: p.travado ? '#fffbeb' : '#fff' }} className="p-2">
                    <div className="font-medium leading-snug min-w-[180px]">{p.descricao}</div>
                    <div className="text-xs text-[var(--fn-muted)]">
                      {[p.codigo && 'RG ' + p.codigo, p.marcas?.nome, p.categorias?.nome].filter(Boolean).join(' · ')}
                      <button onClick={() => alternarTravado(p)} className="ml-2 underline">{p.travado ? 'destravar' : 'travar'}</button>
                    </div>
                  </td>
                  <CelEdit valor={p.tabela_bruta} fmt={v => v == null ? '—' : nf.format(v)}
                    onSave={v => salvarCustoPorTabela(p, num(v), p.multiplicador_desconto)} />
                  <CelEdit valor={p.multiplicador_desconto == null ? null : p.multiplicador_desconto * 100}
                    fmt={v => v == null ? '—' : v.toLocaleString('pt-BR', { maximumFractionDigits: 2 }) + '%'}
                    onSave={v => salvarCustoPorTabela(p, p.tabela_bruta, numDot(v) / 100)} />
                  <CelEdit valor={p.custo_atual} fmt={v => v == null ? '—' : nf.format(v)} forte
                    onSave={v => salvarCustoDireto(p, num(v))} />
                  {colunas.map(r => {
                    const ind = indiceEfetivo(p, r)
                    const exc = overrides[`${p.id}:${r.id}`] != null
                    return (
                      <FragTaxa key={r.id} ind={ind} exc={exc} preco={precos[`${p.id}:${r.id}`]}
                        onSave={frac => salvarExcecao(p, r, frac)} />
                    )
                  })}
                </tr>
              )
            })}
          </tbody>
        </table>
      </div>
      <div className="flex flex-wrap gap-3 text-xs text-[var(--fn-muted)] mt-2">
        <span>clique num valor pra editar</span>
        <span className="text-green-700">↗ aumento</span>
        <span className="text-red-600">↘ diminuição</span>
        <span>o motor calcula o preço de todo produto (custo × taxa × impostos)</span>
        {filtrados.length > 200 && <span>mostrando 200 de {filtrados.length} — refine a busca</span>}
      </div>
    </div>
  )
}

function CelEdit({ valor, fmt, onSave, forte }) {
  const [edit, setEdit] = useState(false)
  const [v, setV] = useState('')
  function abrir() { setV(valor == null ? '' : String(valor).replace('.', ',')); setEdit(true) }
  function salvar() { setEdit(false); if (v !== '') onSave(v) }
  return (
    <td className="p-2 text-right whitespace-nowrap border-l border-[var(--fn-border)]">
      {edit
        ? <input autoFocus className="input w-24 text-right py-1" value={v}
            onChange={e => setV(e.target.value)} onBlur={salvar} onKeyDown={e => e.key === 'Enter' && salvar()} />
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
  const [sinal, setSinal] = useState('+')
  const [v, setV] = useState('')
  const pct = Math.round(ind * 1000) / 10
  function abrir() { setSinal(ind < 0 ? '-' : '+'); setV(String(Math.abs(pct)).replace('.', ',')); setEdit(true) }
  function salvar() {
    setEdit(false)
    if (v === '') { onSave(null); return }
    const n = Math.abs(numDot(v) || 0)
    onSave((sinal === '-' ? -n : n) / 100)
  }
  const cor = ind < 0 ? 'text-red-600' : 'text-green-700'
  return (
    <>
      <td className="p-2 text-right border-l border-[var(--fn-border)] whitespace-nowrap">
        {edit
          ? <span className="inline-flex items-center gap-1">
              <button onClick={() => setSinal(s => s === '+' ? '-' : '+')}
                className={'w-6 h-7 rounded ' + (sinal === '-' ? 'bg-red-600 text-white' : 'bg-[var(--fn-brand)] text-white')}>{sinal}</button>
              <input autoFocus className="input w-14 text-right py-1" value={v} placeholder="%"
                onChange={e => setV(e.target.value)} onKeyDown={e => e.key === 'Enter' && salvar()} />
              <button className="text-[var(--fn-brand)] text-xs" onClick={salvar}>ok</button>
            </span>
          : <button onClick={abrir} className={cor} title={exc ? 'exceção deste produto (clique p/ editar)' : 'regra geral (clique p/ exceção)'}>
              {ind >= 0 ? '↗ +' : '↘ '}{pct}%{exc ? ' *' : ''}
            </button>}
      </td>
      <td className="p-2 text-right font-semibold whitespace-nowrap text-[var(--fn-brand)]">
        {preco == null ? '—' : nf.format(preco)}
      </td>
    </>
  )
}

function EditHeader({ r, onSave }) {
  const [edit, setEdit] = useState(false)
  const [sinal, setSinal] = useState('+')
  const [v, setV] = useState('')
  const pct = Math.round(r.indice_padrao * 1000) / 10
  function abrir() { setSinal(r.indice_padrao < 0 ? '-' : '+'); setV(String(Math.abs(pct)).replace('.', ',')); setEdit(true) }
  function salvar() { setEdit(false); const n = Math.abs(numDot(v) || 0); onSave(r, (sinal === '-' ? -n : n) / 100) }
  return edit
    ? <span className="inline-flex items-center gap-1">
        <button onClick={() => setSinal(s => s === '+' ? '-' : '+')} className={'w-5 h-6 rounded text-xs ' + (sinal === '-' ? 'bg-red-600 text-white' : 'bg-[var(--fn-brand)] text-white')}>{sinal}</button>
        <input autoFocus className="input w-12 py-0.5 text-xs" value={v} onChange={e => setV(e.target.value)}
          onKeyDown={e => e.key === 'Enter' && salvar()} />
        <button className="text-[var(--fn-brand)] text-xs" onClick={salvar}>ok</button>
      </span>
    : <button className="text-[var(--fn-muted)]" onClick={abrir} title="taxa geral da região">✎ {pct}%</button>
}

// Gerenciar regiões: renomear, mudar índice, excluir e adicionar
function RegioesManager({ regioes, onChange, flash }) {
  const [rasc, setRasc] = useState({})
  const [nova, setNova] = useState({ nome: '', indice: '' })
  useEffect(() => {
    const d = {}; regioes.forEach(r => { d[r.id] = { nome: r.nome, indice: (r.indice_padrao * 100).toString().replace('.', ',') } })
    setRasc(d)
  }, [regioes])

  async function salvar(r) {
    const v = rasc[r.id]; const ind = numDot(v.indice)
    await supabase.from('regioes').update({ nome: v.nome, indice_padrao: ind == null ? r.indice_padrao : ind / 100 }).eq('id', r.id)
    flash(`${v.nome} salva`); onChange()
  }
  async function excluir(r) {
    if (!confirm(`Excluir a região "${r.nome}"? Os preços/estoque dela serão desvinculados.`)) return
    await supabase.from('regioes').delete().eq('id', r.id)
    flash('Região excluída'); onChange()
  }
  async function adicionar() {
    if (!nova.nome.trim()) return
    const slug = nova.nome.trim().toUpperCase().replace(/[^A-Z0-9]+/g, '_').slice(0, 24)
    const codigo = (slug || 'REG') + '_' + Date.now().toString().slice(-5)
    const ind = numDot(nova.indice) || 0
    const ordem = (regioes.at(-1)?.ordem || 0) + 10
    const { error } = await supabase.from('regioes').insert({ codigo, nome: nova.nome.trim(), indice_padrao: ind / 100, ordem })
    if (error) { flash('Erro: ' + error.message); return }
    setNova({ nome: '', indice: '' }); flash('Região adicionada'); onChange()
  }

  return (
    <div>
      <div className="divide-y divide-[var(--fn-border)] mb-3">
        {regioes.map(r => (
          <div key={r.id} className="flex flex-wrap items-center gap-2 py-2 text-sm">
            <input className="input flex-1 min-w-[160px]" value={rasc[r.id]?.nome || ''}
              onChange={e => setRasc(s => ({ ...s, [r.id]: { ...s[r.id], nome: e.target.value } }))} />
            <div className="flex items-center gap-1">
              <input className="input w-20 text-right" value={rasc[r.id]?.indice || ''}
                onChange={e => setRasc(s => ({ ...s, [r.id]: { ...s[r.id], indice: e.target.value } }))} />
              <span className="text-[var(--fn-muted)]">%</span>
            </div>
            <button className="btn-primary py-1.5 px-3" onClick={() => salvar(r)}>Salvar</button>
            <button className="text-red-500 px-2" onClick={() => excluir(r)}>excluir</button>
          </div>
        ))}
      </div>
      <div className="flex flex-wrap gap-2 items-center">
        <input className="input flex-1 min-w-[160px]" placeholder="Nova região (ex.: MS Interior)"
          value={nova.nome} onChange={e => setNova(s => ({ ...s, nome: e.target.value }))} />
        <div className="flex items-center gap-1">
          <input className="input w-20 text-right" placeholder="taxa %" value={nova.indice}
            onChange={e => setNova(s => ({ ...s, indice: e.target.value }))} />
          <span className="text-[var(--fn-muted)]">%</span>
        </div>
        <button className="btn-primary py-2 px-4" onClick={adicionar}>Adicionar região</button>
      </div>
    </div>
  )
}

// Gerenciador de MULT por região: um % nomeado que soma (+) ou desconta (−)
function GerenciadorMult({ regiao, onClose, onChange }) {
  const [lista, setLista] = useState([])
  const [nome, setNome] = useState('')
  const [sinal, setSinal] = useState('+')
  const [valor, setValor] = useState('')
  async function carregar() {
    const { data } = await supabase.from('componentes_preco').select('*').eq('regiao_id', regiao.id).order('ordem')
    setLista(data || [])
  }
  useEffect(() => { carregar() }, [regiao.id])
  async function adicionar() {
    if (!nome.trim()) return
    const raw = numDot(valor); if (raw == null) return
    const tipo = sinal === '-' ? 'desconto' : 'percentual'
    await supabase.from('componentes_preco').insert({ nome: nome.trim(), tipo, valor: Math.abs(raw) / 100, regiao_id: regiao.id, ordem: 100 })
    setNome(''); setValor(''); await carregar(); onChange()
  }
  async function remover(id) { await supabase.from('componentes_preco').delete().eq('id', id); await carregar(); onChange() }
  return (
    <div className="card p-4 mb-3">
      <div className="flex items-center justify-between mb-2">
        <h3 className="font-bold">Multiplicadores (MULT) — {regiao.nome}</h3>
        <button onClick={onClose} className="text-[var(--fn-muted)]">fechar ×</button>
      </div>
      <div className="divide-y divide-[var(--fn-border)] mb-3">
        {lista.length === 0 && <div className="text-sm text-[var(--fn-muted)] py-1">Nenhum ainda.</div>}
        {lista.map(c => (
          <div key={c.id} className="flex items-center justify-between py-1.5 text-sm">
            <span>{c.nome} <span className={c.tipo === 'desconto' ? 'text-red-600' : 'text-green-700'}>
              {c.tipo === 'desconto' ? '−' : '+'}{(c.valor * 100).toLocaleString('pt-BR')}%</span></span>
            <button className="text-red-500" onClick={() => remover(c.id)}>remover</button>
          </div>
        ))}
      </div>
      <div className="flex flex-wrap gap-2 items-center">
        <input className="input flex-1 min-w-[140px]" placeholder="Nome (ex.: ICMS, Frete)" value={nome} onChange={e => setNome(e.target.value)} />
        <div className="flex rounded-lg border border-[var(--fn-border)] overflow-hidden">
          <button onClick={() => setSinal('+')} className={'px-3 py-2 ' + (sinal === '+' ? 'bg-[var(--fn-brand)] text-white' : '')}>somar +</button>
          <button onClick={() => setSinal('-')} className={'px-3 py-2 ' + (sinal === '-' ? 'bg-red-600 text-white' : '')}>descontar −</button>
        </div>
        <input className="input w-28" placeholder="valor %" value={valor} onChange={e => setValor(e.target.value)} />
        <button className="btn-primary py-2 px-4" onClick={adicionar}>Adicionar</button>
      </div>
    </div>
  )
}
