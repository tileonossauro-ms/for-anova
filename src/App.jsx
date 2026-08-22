import { Routes, Route, Navigate } from 'react-router-dom'
import { isConfigured } from './lib/supabase.js'
import { useAuth } from './auth/AuthContext.jsx'
import NotConfigured from './pages/NotConfigured.jsx'
import Login from './pages/Login.jsx'
import Layout from './components/Layout.jsx'
import Catalogo from './pages/Catalogo.jsx'
import Precos from './pages/Precos.jsx'
import Estoque from './pages/Estoque.jsx'
import Dashboard from './pages/Dashboard.jsx'
import Usuarios from './pages/Usuarios.jsx'

export default function App() {
  if (!isConfigured) return <NotConfigured />

  const { session, loading } = useAuth()

  if (loading) return <FullScreen>Carregando…</FullScreen>
  if (!session) return <Login />

  return (
    <Layout>
      <Routes>
        <Route path="/" element={<Catalogo />} />
        <Route path="/dashboard" element={<Dashboard />} />
        <Route path="/regras" element={<Precos />} />
        <Route path="/estoque" element={<Estoque />} />
        <Route path="/usuarios" element={<Usuarios />} />
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
