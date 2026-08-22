import { useEffect, useState } from 'react'
import { supabase } from '../lib/supabase.js'
import { brl } from '../lib/format.js'

const PERIODOS = [
  { label: 'Hoje', dias: 0 },
  { label: '7 dias', dias: 7 },
  { label: '30 dias', dias: 30 },
  { label: '90 dias', dias: 90 },
]

export default function Dashboard() {
  const [dias, setDias] = useState(30)
  const [d, setD] = useState(null)
  const [carregando, setCarregando] = useState(true)

  useEffect(() => {
    setCarregando(true)
    const fim = new Date()
    const inicio = new Date()
    if (dias === 0) inicio.setHours(0, 0, 0, 0)
    else inicio.setDate(inicio.getDate() - dias)
    supabase.rpc('fn_dashboard', { p_inicio: inicio.toISOString(), p_fim: fim.toISOString() })
      .then(({ data }) => { setD(data); setCarregando(false) })
  }, [dias])

  return (
    <div className="space-y-4">
      <div className="flex gap-1">
        {PERIODOS.map(p => (
          <button key={p.dias} onClick={() => setDias(p.dias)}
            className={'px-3 py-1.5 rounded-lg text-sm font-medium ' +
              (dias === p.dias ? 'bg-[var(--fn-brand)] text-white' : 'bg-white border border-[var(--fn-border)] text-[var(--fn-muted)]')}>
            {p.label}
          </button>
        ))}
      </div>

      {carregando || !d ? <div className="text-[var(--fn-muted)]">Carregando…</div> : (
        <>
          <div className="grid grid-cols-2 sm:grid-cols-4 gap-2">
            <Kpi titulo="Faturamento" valor={brl(d.vendas?.faturamento)} destaque />
            <Kpi titulo="Vendas" valor={d.vendas?.quantidade ?? 0} />
            <Kpi titulo="Ticket médio" valor={brl(d.vendas?.ticket_medio)} />
            <Kpi titulo="Transf. a receber" valor={d.transfer_pendentes ?? 0} />
          </div>

          <div className="grid sm:grid-cols-2 gap-4">
            <Lista titulo="Por vendedor" vazio="Sem vendas no período"
              itens={d.por_vendedor} render={v => (
                <>
                  <div><div className="font-medium">{v.nome}</div>
                    <div className="text-xs text-[var(--fn-muted)]">{v.vendas} venda(s) · ticket {brl(v.ticket_medio)}</div></div>
                  <div className="font-semibold text-[var(--fn-brand)]">{brl(v.faturamento)}</div>
                </>
              )} />

            <Lista titulo="Por região" vazio="Sem vendas no período"
              itens={d.por_regiao} render={v => (
                <><div className="font-medium">{v.nome}</div>
                  <div className="font-semibold text-[var(--fn-brand)]">{brl(v.faturamento)}</div></>
              )} />
          </div>

          <Lista titulo="Produtos mais vendidos" vazio="Sem vendas no período"
            itens={d.top_produtos} render={v => (
              <><div className="flex-1 min-w-0"><div className="font-medium truncate">{v.descricao}</div>
                <div className="text-xs text-[var(--fn-muted)]">{Number(v.quantidade)} un</div></div>
                <div className="font-semibold text-[var(--fn-brand)]">{brl(v.total)}</div></>
            )} />

          <div className="card p-4">
            <h2 className="font-bold mb-2">Estoque</h2>
            <div className="grid grid-cols-3 gap-2 text-center">
              <Mini titulo="Itens em estoque" valor={Number(d.estoque?.itens_totais || 0)} />
              <Mini titulo="Estoque baixo" valor={d.estoque?.estoque_baixo ?? 0} cor="text-amber-600" />
              <Mini titulo="Sem estoque" valor={d.estoque?.sem_estoque ?? 0} cor="text-red-600" />
            </div>
          </div>
        </>
      )}
    </div>
  )
}

function Kpi({ titulo, valor, destaque }) {
  return (
    <div className="card p-3">
      <div className="text-xs text-[var(--fn-muted)]">{titulo}</div>
      <div className={'text-lg font-bold ' + (destaque ? 'text-[var(--fn-brand)]' : '')}>{valor}</div>
    </div>
  )
}
function Mini({ titulo, valor, cor }) {
  return (
    <div>
      <div className={'text-2xl font-bold ' + (cor || '')}>{valor}</div>
      <div className="text-xs text-[var(--fn-muted)]">{titulo}</div>
    </div>
  )
}
function Lista({ titulo, itens, render, vazio }) {
  return (
    <div className="card p-4">
      <h2 className="font-bold mb-2">{titulo}</h2>
      {(!itens || itens.length === 0) ? <div className="text-sm text-[var(--fn-muted)]">{vazio}</div> : (
        <div className="divide-y divide-[var(--fn-border)]">
          {itens.map((v, i) => (
            <div key={i} className="flex items-center justify-between gap-3 py-2 text-sm">{render(v)}</div>
          ))}
        </div>
      )}
    </div>
  )
}
