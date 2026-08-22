export default function Placeholder({ titulo }) {
  return (
    <div className="card p-8 text-center">
      <h1 className="text-lg font-bold mb-1">{titulo}</h1>
      <p className="text-[var(--fn-muted)] text-sm">
        Esta tela entra na próxima fase. A fundação e o motor de preço já estão prontos.
      </p>
    </div>
  )
}
