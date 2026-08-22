import { useEffect, useState } from 'react'
import { supabase } from '../lib/supabase.js'
import { brl, pct } from '../lib/format.js'

// Mostra "por que esse produto custa R$ X" — passo a passo (seção 11)
export default function ExplicacaoPreco({ item, regiaoId, onClose }) {
  const [dados, setDados] = useState(null)

  useEffect(() => {
    supabase.rpc('fn_explicar_preco', {
      p_produto: item.produto_id, p_regiao: regiaoId,
    }).then(({ data }) => setDados(data))
  }, [item, regiaoId])

  const rotuloValor = (p) => {
    if (p.tipo === 'indice' || p.tipo === 'percentual' || p.tipo === 'imposto')
      return '+' + pct(p.valor)
    if (p.tipo === 'desconto') return '−' + pct(p.valor)
    if (p.tipo === 'multiplicador') return '×' + p.valor
    if (p.tipo === 'valor_fixo') return (p.valor >= 0 ? '+' : '') + brl(p.valor)
    if (p.tipo === 'arredondamento') return 'arredonda'
    return ''
  }

  return (
    <div className="fixed inset-0 bg-black/40 flex items-end sm:items-center justify-center z-20 p-0 sm:p-4"
      onClick={onClose}>
      <div className="card w-full sm:max-w-md p-5 rounded-b-none sm:rounded-b-xl max-h-[85vh] overflow-auto"
        onClick={e => e.stopPropagation()}>
        <div className="flex items-start justify-between gap-3 mb-1">
          <h2 className="font-bold leading-snug">{item.descricao}</h2>
          <button onClick={onClose} className="text-[var(--fn-muted)] text-xl leading-none">×</button>
        </div>
        <p className="text-sm text-[var(--fn-muted)] mb-4">Por que esse preço?</p>

        {!dados ? <div className="text-[var(--fn-muted)]">Calculando…</div> : (
          <>
            <table className="w-full text-sm">
              <tbody>
                {(dados.passos || []).map((p, idx) => (
                  <tr key={idx} className="border-b border-[var(--fn-border)] last:border-0">
                    <td className="py-2">
                      <div className="font-medium">{p.passo}</div>
                      <div className="text-xs text-[var(--fn-muted)]">{rotuloValor(p)}</div>
                    </td>
                    <td className="py-2 text-right font-medium">{brl(p.depois)}</td>
                  </tr>
                ))}
              </tbody>
            </table>

            {dados.usou_preco_manual && (
              <div className="mt-3 text-sm bg-amber-50 text-amber-800 rounded-lg p-3">
                Este produto usa <b>preço manual travado</b> ({brl(dados.preco_manual)}).
                O motor calcularia {brl(dados.preco_calculado)}.
              </div>
            )}

            <div className="mt-4 flex items-center justify-between border-t border-[var(--fn-border)] pt-3">
              <span className="font-semibold">Preço final</span>
              <span className="font-bold text-lg text-[var(--fn-brand)]">{brl(dados.preco_final)}</span>
            </div>
          </>
        )}
      </div>
    </div>
  )
}
