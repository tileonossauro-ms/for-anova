import { useState } from 'react'

// Mostra o logo oficial se existir em /logo.png (coloque o arquivo em public/).
// Enquanto não houver, mostra o wordmark na identidade da marca.
export default function Logo({ height = 30 }) {
  const [erro, setErro] = useState(false)
  if (!erro) {
    return <img src="/logo.png" alt="Força Nova" style={{ height, width: 'auto' }} onError={() => setErro(true)} />
  }
  return (
    <span style={{ display: 'inline-flex', alignItems: 'center', gap: 6 }}>
      <span style={{ color: 'var(--fn-brand)', fontWeight: 800, fontStyle: 'italic', fontSize: height * 0.7 }}>//</span>
      <span style={{ color: 'var(--fn-brown)', fontWeight: 800, letterSpacing: '.5px', fontSize: height * 0.55 }}>FORÇA NOVA</span>
    </span>
  )
}
