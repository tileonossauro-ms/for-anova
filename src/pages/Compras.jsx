import { useEffect, useMemo, useState } from 'react'
import { supabase } from '../lib/supabase.js'
import { brl } from '../lib/format.js'

// Fluxo (seção 12): busca produto -> informa custo -> prévia -> confirma.
export default function Compras() {
  const [regioes, setRegioes] = useState([])
  const [regiaoRef, setRegiaoRef] = useState('')   // região para exibir a prévia de preço
  const [busca, setBusca] = useState('')
  const [resultados, setResultados] = useState([])
  const [carrinho, setCarrinho] = useState([])     // [{id, descricao, custo_atual, custoNovo, precoAtual, precoPrev}]
  const [msg, setMsg] = useState('')

  useEffect(() => {
    supabase.from('regioes').select('*').eq('ativo', true).order('ordem')
      .then(({ data }) => { setRegioes(data || []); setRegiaoRef(data?.[0]?.id || '') })
  }, [])

  // busca produtos por descrição/código
  useEffect(() => {
    const q = busca.trim()
    if (q.length < 2) { setResultados([]); return }
    const t = setTimeout(async () => {
      const { data } = await supabase.from('produtos')
        .select('id, codigo, descricao, custo_atual')
        .or(`descricao.ilike.%${q}%,codigo.ilike.%${q}%`)
        .order('descricao').limit(20)
      setResultados(data || [])
    }, 250)
    return () => clearTimeout(t)
  }, [busca])

  async function precoDe(produtoId, custoOverride) {
    const { data } = await supabase.rpc('fn_calcular_preco', {
      p_produto: produtoId, p_regiao: regiaoRef,
      ...(custoOverride != null ? { p_custo_override: custoOverride } : {}),
    })
    return data?.preco_final ?? null
  }

  async function adicionar(p) {
    if (carrinho.some(i => i.id === p.id)) return
    const precoAtual = await precoDe(p.id, null)
    setCarrinho(c => [...c, {
      id: p.id, codigo: p.codigo, descricao: p.descricao,
      custo_atual: p.custo_atual, custoNovo: '', precoAtual, precoPrev: null,
    }])
    setBusca(''); setResultados([])
  }

  async function mudarCusto(id, valor) {
    setCarrinho(c => c.map(i => i.id === id ? { ...i, custoNovo: valor } : i))
    const num = parseFloat(String(valor).replace(',', '.'))
    if (!isNaN(num)) {
      const prev = await precoDe(id, num)
      setCarrinho(c => c.map(i => i.id === id ? { ...i, precoPrev: prev } : i))
    } else {
      setCarrinho(c => c.map(i => i.id === id ? { ...i, precoPrev: null } : i))
    }
  }

  // recalcula prévias quando muda a região de referência
  useEffect(() => {
    if (!regiaoRef || carrinho.length === 0) return
    ;(async () => {
      const atualizados = await Promise.all(carrinho.map(async i => {
        const precoAtual = await precoDe(i.id, null)
        const num = parseFloat(String(i.custoNovo).replace(',', '.'))
        const precoPrev = isNaN(num) ? null : await precoDe(i.id, num)
        return { ...i, precoAtual, precoPrev }
      }))
      setCarrinho(atualizados)
    })()
  }, [regiaoRef]) // eslint-disable-line

  const prontos = useMemo(
    () => carrinho.filter(i => !isNaN(parseFloat(String(i.custoNovo).replace(',', '.')))),
    [carrinho]
  )

  async function confirmar() {
    if (prontos.length === 0) return
    const itens = prontos.map(i => ({
      produto_id: i.id, custo: parseFloat(String(i.custoNovo).replace(',', '.')),
    }))
    const { data, error } = await supabase.rpc('fn_aplicar_compra', { p_itens: itens, p_origem: 'compra' })
    if (error) { setMsg('Erro: ' + error.message); return }
    setMsg(`✅ ${data} produto(s) atualizados. O catálogo já está com os novos preços.`)
    setCarrinho([])
  }

  return (
    <div className="space-y-4">
      <div className="card p-4">
        <h1 className="font-bold mb-1">Nova compra — atualizar custos</h1>
        <p className="text-sm text-[var(--fn-muted)] mb-3">
          Busque os produtos da nota, informe o novo custo e confira a prévia antes de confirmar.
        </p>
        <div className="flex flex-col sm:flex-row gap-2">
          <div className="flex-1 relative">
            <input className="input" placeholder="Buscar produto por descrição ou código…"
              value={busca} onChange={e => setBusca(e.target.value)} />
            {resultados.length > 0 && (
              <div className="absolute z-20 mt-1 w-full card max-h-72 overflow-auto">
                {resultados.map(p => (
                  <button key={p.id} onClick={() => adicionar(p)}
                    className="block w-full text-left px-3 py-2 hover:bg-gray-50 border-b border-[var(--fn-border)] last:border-0">
                    <div className="text-sm font-medium">{p.descricao}</div>
                    <div className="text-xs text-[var(--fn-muted)]">
                      {p.codigo && `Cód. ${p.codigo} · `}custo atual {brl(p.custo_atual)}
                    </div>
                  </button>
                ))}
              </div>
            )}
          </div>
          <select className="input sm:w-56" value={regiaoRef} onChange={e => setRegiaoRef(e.target.value)}>
            {regioes.map(r => <option key={r.id} value={r.id}>Prévia: {r.nome}</option>)}
          </select>
        </div>
      </div>

      {carrinho.length > 0 && (
        <div className="card p-4">
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead>
                <tr className="text-left text-[var(--fn-muted)] border-b border-[var(--fn-border)]">
                  <th className="py-2">Produto</th>
                  <th className="py-2">Custo atual</th>
                  <th className="py-2">Novo custo</th>
                  <th className="py-2 text-right">Preço atual</th>
                  <th className="py-2 text-right">Novo preço</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                {carrinho.map(i => (
                  <tr key={i.id} className="border-b border-[var(--fn-border)] last:border-0">
                    <td className="py-2 pr-2">
                      <div className="font-medium">{i.descricao}</div>
                      {i.codigo && <div className="text-xs text-[var(--fn-muted)]">Cód. {i.codigo}</div>}
                    </td>
                    <td className="py-2 pr-2 whitespace-nowrap">{brl(i.custo_atual)}</td>
                    <td className="py-2 pr-2">
                      <input className="input w-28" placeholder="R$" value={i.custoNovo}
                        onChange={e => mudarCusto(i.id, e.target.value)} />
                    </td>
                    <td className="py-2 text-right whitespace-nowrap">{brl(i.precoAtual)}</td>
                    <td className="py-2 text-right whitespace-nowrap font-semibold text-[var(--fn-brand)]">
                      {i.precoPrev != null ? brl(i.precoPrev) : '—'}
                    </td>
                    <td className="py-2 text-right">
                      <button className="text-red-500" onClick={() => setCarrinho(c => c.filter(x => x.id !== i.id))}>×</button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <div className="flex items-center justify-between mt-4">
            <span className="text-sm text-[var(--fn-muted)]">{prontos.length} de {carrinho.length} com novo custo</span>
            <button className="btn-primary" disabled={prontos.length === 0} onClick={confirmar}>
              Confirmar {prontos.length > 0 && `(${prontos.length})`}
            </button>
          </div>
        </div>
      )}

      {msg && <div className="card p-3 text-sm">{msg}</div>}
    </div>
  )
}
