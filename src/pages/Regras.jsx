import { useEffect, useState } from 'react'
import { supabase } from '../lib/supabase.js'
import { pct, brl } from '../lib/format.js'

const TIPOS = [
  { v: 'imposto',       label: 'Imposto (+%)',        modo: 'pct' },
  { v: 'percentual',    label: 'Acréscimo (+%)',      modo: 'pct' },
  { v: 'desconto',      label: 'Desconto (−%)',       modo: 'pct' },
  { v: 'valor_fixo',    label: 'Valor fixo (R$)',     modo: 'reais' },
  { v: 'multiplicador', label: 'Multiplicador (×)',   modo: 'fator' },
  { v: 'arredondamento',label: 'Arredondar p/ múltiplo', modo: 'inteiro' },
]
const modoDe = t => TIPOS.find(x => x.v === t)?.modo || 'fator'

export default function Regras() {
  const [regioes, setRegioes] = useState([])
  const [categorias, setCategorias] = useState([])
  const [componentes, setComponentes] = useState([])
  const [fatorCusto, setFatorCusto] = useState('')
  const [msg, setMsg] = useState('')

  async function carregar() {
    const [r, c, comp, cfg] = await Promise.all([
      supabase.from('regioes').select('*').order('ordem'),
      supabase.from('categorias').select('*').order('nome'),
      supabase.from('componentes_preco')
        .select('*, regioes(nome), categorias(nome)').order('ordem'),
      supabase.from('config_precificacao').select('*').eq('chave', 'fator_custo_padrao').maybeSingle(),
    ])
    setRegioes(r.data || [])
    setCategorias(c.data || [])
    setComponentes(comp.data || [])
    setFatorCusto(cfg.data?.valor_num ?? '')
  }
  useEffect(() => { carregar() }, [])

  function flash(t) { setMsg(t); setTimeout(() => setMsg(''), 2500) }

  return (
    <div className="space-y-6">
      {msg && <div className="fixed top-16 right-4 bg-[var(--fn-brand)] text-white px-4 py-2 rounded-lg shadow z-30">{msg}</div>}

      <IndicesRegiao regioes={regioes} onSave={flash} reload={carregar} />
      <FatorCusto valor={fatorCusto} onSave={flash} reload={carregar} />
      <Componentes componentes={componentes} regioes={regioes} categorias={categorias}
        onSave={flash} reload={carregar} />
    </div>
  )
}

/* ---------- Índices por região (editar direto) ---------- */
function IndicesRegiao({ regioes, onSave, reload }) {
  const [rascunho, setRascunho] = useState({})
  useEffect(() => {
    const d = {}; regioes.forEach(r => { d[r.id] = (r.indice_padrao * 100).toString() })
    setRascunho(d)
  }, [regioes])

  async function salvar(r) {
    const v = parseFloat(String(rascunho[r.id]).replace(',', '.')) / 100
    if (isNaN(v)) return
    await supabase.from('regioes').update({ indice_padrao: v }).eq('id', r.id)
    onSave(`Índice de ${r.nome} salvo`); reload()
  }

  return (
    <section className="card p-4">
      <h2 className="font-bold mb-1">Índices por região</h2>
      <p className="text-sm text-[var(--fn-muted)] mb-3">
        É o percentual aplicado sobre o custo. Muda aqui → o catálogo inteiro recalcula.
      </p>
      <div className="divide-y divide-[var(--fn-border)]">
        {regioes.map(r => (
          <div key={r.id} className="flex items-center gap-3 py-2">
            <div className="flex-1">
              <div className="font-medium">{r.nome}</div>
              <div className="text-xs text-[var(--fn-muted)]">{r.codigo}</div>
            </div>
            <div className="flex items-center gap-1">
              <input className="input w-24 text-right" value={rascunho[r.id] ?? ''}
                onChange={e => setRascunho(s => ({ ...s, [r.id]: e.target.value }))} />
              <span className="text-[var(--fn-muted)]">%</span>
            </div>
            <button className="btn-primary py-2 px-3 text-sm" onClick={() => salvar(r)}>Salvar</button>
          </div>
        ))}
      </div>
    </section>
  )
}

/* ---------- Fator de custo global ---------- */
function FatorCusto({ valor, onSave, reload }) {
  const [v, setV] = useState('')
  useEffect(() => { setV(valor?.toString() ?? '') }, [valor])
  async function salvar() {
    const num = parseFloat(String(v).replace(',', '.'))
    if (isNaN(num)) return
    await supabase.from('config_precificacao')
      .update({ valor_num: num }).eq('chave', 'fator_custo_padrao')
    onSave('Fator de custo salvo'); reload()
  }
  return (
    <section className="card p-4">
      <h2 className="font-bold mb-1">Fator de custo (sugestão)</h2>
      <p className="text-sm text-[var(--fn-muted)] mb-3">
        Usado só quando o produto não tem custo informado: custo ≈ tabela × fator.
      </p>
      <div className="flex items-center gap-2">
        <input className="input w-32" value={v} onChange={e => setV(e.target.value)} />
        <button className="btn-primary py-2 px-3 text-sm" onClick={salvar}>Salvar</button>
      </div>
    </section>
  )
}

/* ---------- Componentes (impostos, taxas, descontos, arredondamento) ---------- */
function Componentes({ componentes, regioes, categorias, onSave, reload }) {
  const vazio = { nome: '', tipo: 'imposto', valorUI: '', ordem: 100, regiao_id: '', categoria_id: '', ativo: true }
  const [form, setForm] = useState(vazio)
  const [editId, setEditId] = useState(null)

  function valorParaBanco() {
    const raw = parseFloat(String(form.valorUI).replace(',', '.'))
    if (isNaN(raw)) return 0
    return modoDe(form.tipo) === 'pct' ? raw / 100 : raw
  }
  function valorParaUI(c) {
    return modoDe(c.tipo) === 'pct' ? (c.valor * 100).toString() : c.valor.toString()
  }

  async function salvar() {
    if (!form.nome.trim()) { onSave('Dê um nome ao componente'); return }
    const reg = {
      nome: form.nome.trim(), tipo: form.tipo, valor: valorParaBanco(),
      ordem: Number(form.ordem) || 100, ativo: form.ativo,
      regiao_id: form.regiao_id || null, categoria_id: form.categoria_id || null,
    }
    if (editId) await supabase.from('componentes_preco').update(reg).eq('id', editId)
    else await supabase.from('componentes_preco').insert(reg)
    setForm(vazio); setEditId(null); onSave('Componente salvo'); reload()
  }
  function editar(c) {
    setEditId(c.id)
    setForm({ nome: c.nome, tipo: c.tipo, valorUI: valorParaUI(c), ordem: c.ordem,
      regiao_id: c.regiao_id || '', categoria_id: c.categoria_id || '', ativo: c.ativo })
  }
  async function excluir(c) {
    if (!confirm(`Remover "${c.nome}"?`)) return
    await supabase.from('componentes_preco').delete().eq('id', c.id)
    onSave('Componente removido'); reload()
  }

  const rotuloValor = c => modoDe(c.tipo) === 'pct' ? pct(c.valor)
    : c.tipo === 'valor_fixo' ? brl(c.valor)
    : c.tipo === 'arredondamento' ? `múltiplo de ${c.valor}` : `× ${c.valor}`

  return (
    <section className="card p-4">
      <h2 className="font-bold mb-1">Impostos, taxas e ajustes</h2>
      <p className="text-sm text-[var(--fn-muted)] mb-3">
        Cada linha é um passo do cálculo. Aplicados na ordem, depois do índice da região.
      </p>

      {/* lista */}
      <div className="divide-y divide-[var(--fn-border)] mb-4">
        {componentes.length === 0 && <div className="text-sm text-[var(--fn-muted)] py-2">Nenhum componente ainda.</div>}
        {componentes.map(c => (
          <div key={c.id} className="flex items-center gap-3 py-2">
            <div className="flex-1">
              <div className="font-medium">
                {c.nome} {!c.ativo && <span className="text-xs text-red-500">(inativo)</span>}
              </div>
              <div className="text-xs text-[var(--fn-muted)]">
                {rotuloValor(c)} · ordem {c.ordem}
                {c.regioes?.nome && ` · região: ${c.regioes.nome}`}
                {c.categorias?.nome && ` · categoria: ${c.categorias.nome}`}
                {!c.regiao_id && !c.categoria_id && ' · global'}
              </div>
            </div>
            <button className="text-sm text-[var(--fn-brand)]" onClick={() => editar(c)}>Editar</button>
            <button className="text-sm text-red-500" onClick={() => excluir(c)}>Excluir</button>
          </div>
        ))}
      </div>

      {/* form add/editar */}
      <div className="bg-gray-50 rounded-lg p-3 grid sm:grid-cols-2 gap-2">
        <div className="sm:col-span-2 font-medium text-sm">{editId ? 'Editar componente' : 'Adicionar componente'}</div>
        <input className="input" placeholder="Nome (ex.: ICMS Antecipa SP)"
          value={form.nome} onChange={e => setForm(s => ({ ...s, nome: e.target.value }))} />
        <select className="input" value={form.tipo} onChange={e => setForm(s => ({ ...s, tipo: e.target.value }))}>
          {TIPOS.map(t => <option key={t.v} value={t.v}>{t.label}</option>)}
        </select>
        <input className="input" placeholder={modoDe(form.tipo) === 'pct' ? 'valor em % (ex.: 19)' : 'valor'}
          value={form.valorUI} onChange={e => setForm(s => ({ ...s, valorUI: e.target.value }))} />
        <input className="input" type="number" placeholder="ordem"
          value={form.ordem} onChange={e => setForm(s => ({ ...s, ordem: e.target.value }))} />
        <select className="input" value={form.regiao_id} onChange={e => setForm(s => ({ ...s, regiao_id: e.target.value }))}>
          <option value="">Todas as regiões</option>
          {regioes.map(r => <option key={r.id} value={r.id}>{r.nome}</option>)}
        </select>
        <select className="input" value={form.categoria_id} onChange={e => setForm(s => ({ ...s, categoria_id: e.target.value }))}>
          <option value="">Todas as categorias</option>
          {categorias.map(c => <option key={c.id} value={c.id}>{c.nome}</option>)}
        </select>
        <label className="flex items-center gap-2 text-sm">
          <input type="checkbox" checked={form.ativo} onChange={e => setForm(s => ({ ...s, ativo: e.target.checked }))} />
          Ativo
        </label>
        <div className="sm:col-span-2 flex gap-2">
          <button className="btn-primary py-2 px-4 text-sm" onClick={salvar}>{editId ? 'Salvar alteração' : 'Adicionar'}</button>
          {editId && <button className="text-sm px-3" onClick={() => { setForm(vazio); setEditId(null) }}>Cancelar</button>}
        </div>
      </div>
    </section>
  )
}
