import { Routes, Route, Navigate } from 'react-router-dom'
import { isConfigured } from './lib/supabase.js'
import { useAuth } from './auth/AuthContext.jsx'
import NotConfigured from './pages/NotConfigured.jsx'
import Login from './pages/Login.jsx'
import Layout from './components/Layout.jsx'
import Catalogo from './pages/Catalogo.jsx'
import Regras from './pages/Regras.jsx'
import Compras from './pages/Compras.jsx'
import Placeholder from './pages/Placeholder.jsx'

export default function App() {
  if (!isConfigured) return <NotConfigured />

  const { session, loading } = useAuth()

  if (loading) return <FullScreen>Carregando…</FullScreen>
  if (!session) return <Login />

  return (
    <Layout>
      <Routes>
        <Route path="/" element={<Catalogo />} />
        <Route path="/regras" element={<Regras />} />
        <Route path="/compras" element={<Compras />} />
        <Route path="/vendas" element={<Placeholder titulo="Vendas" />} />
        <Route path="/estoque" element={<Placeholder titulo="Estoque" />} />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>
    </Layout>
  )
}

function FullScreen({ children }) {
  return (
    <div className="min-h-screen flex items-center justify-center text-[var(--fn-muted)]">
      {children}
    </div>
  )
}
