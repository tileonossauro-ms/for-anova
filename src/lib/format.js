export function brl(v) {
  if (v == null || isNaN(v)) return '—'
  return Number(v).toLocaleString('pt-BR', {
    style: 'currency',
    currency: 'BRL',
    minimumFractionDigits: 2,
  })
}

export function pct(v) {
  if (v == null || isNaN(v)) return '—'
  return (Number(v) * 100).toLocaleString('pt-BR', { maximumFractionDigits: 2 }) + '%'
}
