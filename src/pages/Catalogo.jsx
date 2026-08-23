import { useEffect, useMemo, useState } from 'react'
import jsPDF from 'jspdf'
import autoTable from 'jspdf-autotable'
import { supabase } from '../lib/supabase.js'
import { useAuth } from '../auth/AuthContext.jsx'

const nf = new Intl.NumberFormat('pt-BR', { maximumFractionDigits: 0 })

export default function Catalogo() {
  const { profile } = useAuth()
  const [regioes, setRegioes] = useState([])
  const [selecionadas, setSelecionadas] = useState([])   // ids de regiões visíveis
  const [linhas, setLinhas] = useState([])                // resultado bruto (produto+região)
  const [busca, setBusca] = useState('')
  const [categoria, setCategoria] = useState('')
  const [carregando, setCarregando] = useState(true)

  // regiões + seleção inicial (região do vendedor, ou a primeira)
  useEffect(() => {
    supabase.from('regioes').select('id, nome, ativo, ordem').eq('ativo', true).order('ordem')
      .then(({ data }) => {
        const rs = data || []
        setRegioes(rs)
        const inicial = profile?.regiao_padrao_id && rs.some(r => r.id === profile.regiao_padrao_id)
          ? [profile.regiao_padrao_id] : (rs[0] ? [rs[0].id] : [])
        setSelecionadas(inicial)
      })
  }, [profile])

  // catálogo das regiões selecionadas
  useEffect(() => {
    if (selecionadas.length === 0) { setLinhas([]); setCarregando(false); return }
    setCarregando(true)
    supabase.rpc('fn_catalogo_multi', { p_regioes: selecionadas }).then(({ data }) => {
      setLinhas(data || [])
      setCarregando(false)
    })
  }, [selecionadas])

  function toggleRegiao(id) {
    setSelecionadas(s => s.includes(id) ? s.filter(x => x !== id) : [...s, id])
  }

  // regiões visíveis na ordem oficial
  const colunas = useMemo(
    () => regioes.filter(r => selecionadas.includes(r.id)),
    [regioes, selecionadas]
  )

  // pivota: 1 objeto por produto, com precos[regiao] = {preco, estoque}
  const produtos = useMemo(() => {
    const map = new Map()
    for (const l of linhas) {
      if (!map.has(l.produto_id)) {
        map.set(l.produto_id, {
          id: l.produto_id, descricao: l.descricao, marca: l.marca,
          categoria: l.categoria, codigo: l.codigo, cel: {},
        })
      }
      map.get(l.produto_id).cel[l.regiao_id] = { preco: l.preco, estoque: l.estoque }
    }
    return [...map.values()]
  }, [linhas])

  const categorias = useMemo(
    () => [...new Set(produtos.map(p => p.categoria).filter(Boolean))].sort(),
    [produtos]
  )

  const filtrados = useMemo(() => {
    const q = busca.trim().toLowerCase()
    return produtos.filter(p => {
      if (categoria && p.categoria !== categoria) return false
      if (!q) return true
      return [p.descricao, p.codigo, p.marca, p.categoria]
        .filter(Boolean).some(x => String(x).toLowerCase().includes(q))
    })
  }, [produtos, busca, categoria])

  function gerarPDF() {
    if (colunas.length === 0) return
    const doc = new jsPDF({ orientation: 'landscape', unit: 'pt', format: 'a4' })
    const data = new Date().toLocaleDateString('pt-BR')
    doc.setFontSize(13); doc.text('Força Nova — Catálogo', 30, 30)
    doc.setFontSize(9); doc.setTextColor(120)
    doc.text(`Atualizado em ${data}`, 30, 44)

    const head = [['Produto', ...colunas.map(c => c.nome)]]
    const body = filtrados.map(p => ([
      p.descricao + (p.codigo ? `  (RG ${p.codigo})` : ''),
      ...colunas.map(c => { const v = p.cel[c.id]?.preco; return v == null ? '—' : nf.format(v) }),
    ]))

    autoTable(doc, {
      head, body, startY: 54,
      theme: 'grid',
      styles: { fontSize: 7, cellPadding: 2, overflow: 'linebreak' },
      headStyles: { fillColor: [21, 128, 61], textColor: 255, fontSize: 7 },
      columnStyles: { 0: { cellWidth: 240 } },
      bodyStyles: { valign: 'middle' },
      didParseCell: (d) => { if (d.section === 'body' && d.column.index > 0) d.cell.styles.halign = 'right' },
    })
    doc.save(`catalogo-forca-nova-${data.replace(/\//g, '-')}.pdf`)
  }

  return (
    <div>
      <div className="flex gap-2 mb-3">
        <input className="input flex-1" placeholder="Buscar por descrição, código, marca…"
          value={busca} onChange={e => setBusca(e.target.value)} />
        <button className="btn-primary px-4 whitespace-nowrap" onClick={gerarPDF} disabled={colunas.length === 0}>
          Baixar PDF
        </button>
      </div>

      {/* seleção de regiões */}
      <div className="mb-3">
        <div className="text-xs text-[var(--fn-muted)] mb-1.5">Regiões que quero ver</div>
        <div className="flex gap-1.5 overflow-x-auto pb-1">
          {regioes.map(r => {
            const on = selecionadas.includes(r.id)
            return (
              <button key={r.id} onClick={() => toggleRegiao(r.id)}
                className={'shrink-0 px-3 py-1.5 rounded-full text-sm border flex items-center gap-1.5 ' +
                  (on ? 'bg-[var(--fn-brand)] text-white border-[var(--fn-brand)]'
                      : 'bg-white text-[var(--fn-muted)] border-[var(--fn-border)]')}>
                {on && <span>✓</span>}{r.nome}
              </button>
            )
          })}
        </div>
      </div>

      {/* filtro por categoria */}
      {categorias.length > 0 && (
        <div className="flex gap-1.5 overflow-x-auto pb-2 mb-1">
          <Chip ativo={!categoria} onClick={() => setCategoria('')}>Todas</Chip>
          {categorias.map(c => <Chip key={c} ativo={categoria === c} onClick={() => setCategoria(c)}>{c}</Chip>)}
        </div>
      )}

      <div className="text-xs text-[var(--fn-muted)] mb-2">
        {carregando ? 'Carregando…' : `${filtrados.length} produto(s)`}
      </div>

      {colunas.length === 0 ? (
        <div className="card p-6 text-center text-[var(--fn-muted)]">Selecione ao menos uma região.</div>
      ) : (
        <div className="card p-0 overflow-x-auto">
          <table className="w-full text-sm border-collapse" style={{ minWidth: 360 + colunas.length * 150 }}>
            <thead>
              <tr className="text-[var(--fn-muted)]">
                <th rowSpan={2} className="text-left p-3 font-medium border-b border-[var(--fn-border)] sticky left-0 bg-white">Produto</th>
                {colunas.map(c => (
                  <th key={c.id} colSpan={2} className="p-2 font-medium text-center bg-gray-50 border-l border-[var(--fn-border)]">{c.nome}</th>
                ))}
              </tr>
              <tr className="text-[var(--fn-muted)] text-[11px]">
                {colunas.map(c => (
                  <FragmentHeader key={c.id} />
                ))}
              </tr>
            </thead>
            <tbody>
              {filtrados.map(p => (
                <tr key={p.id} className="border-t border-[var(--fn-border)] align-top">
                  <td className="p-3 sticky left-0 bg-white">
                    <div className="font-medium leading-snug">{p.descricao}</div>
                    <div className="text-xs text-[var(--fn-muted)]">
                      {[p.marca, p.codigo && `cód. ${p.codigo}`, p.categoria].filter(Boolean).join(' · ')}
                    </div>
                  </td>
                  {colunas.map(c => {
                    const cel = p.cel[c.id] || {}
                    const temPreco = cel.preco != null
                    return (
                      <FragmentCell key={c.id} preco={cel.preco} estoque={cel.estoque} temPreco={temPreco} />
                    )
                  })}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      <div className="flex flex-wrap gap-3 text-xs text-[var(--fn-muted)] mt-2">
        <span><span className="text-red-600">0</span> = esgotado</span>
        <span><span className="text-amber-600">1</span> = estoque baixo</span>
        <span>role pro lado pra ver mais regiões</span>
      </div>
    </div>
  )
}

function FragmentHeader() {
  return (
    <>
      <th className="p-1.5 font-normal text-right bg-gray-50 border-l border-b border-[var(--fn-border)]">Preço</th>
      <th className="p-1.5 font-normal text-right bg-gray-50 border-b border-[var(--fn-border)]">Estoque</th>
    </>
  )
}

function FragmentCell({ preco, estoque, temPreco }) {
  const est = Number(estoque) || 0
  const corEstoque = est <= 0 ? 'text-red-600' : est <= 2 ? 'text-amber-600' : ''
  return (
    <>
      <td className="p-3 text-right font-semibold text-[var(--fn-brand)] border-l border-[var(--fn-border)] whitespace-nowrap">
        {temPreco ? nf.format(preco) : '—'}
      </td>
      <td className={'p-3 text-right whitespace-nowrap ' + corEstoque}>{temPreco ? est : '—'}</td>
    </>
  )
}

function Chip({ ativo, children, onClick }) {
  return (
    <button onClick={onClick}
      className={'shrink-0 px-3 py-1.5 rounded-full text-sm border ' +
        (ativo ? 'bg-[var(--fn-brand)] text-white border-[var(--fn-brand)]'
               : 'bg-white text-[var(--fn-muted)] border-[var(--fn-border)]')}>
      {children}
    </button>
  )
}
