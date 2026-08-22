import { NavLink } from 'react-router-dom'
import { useAuth } from '../auth/AuthContext.jsx'

export default function Layout({ children }) {
  const { profile, isAdmin, signOut } = useAuth()

  const linkCls = ({ isActive }) =>
    'px-3 py-2 rounded-lg text-sm font-medium ' +
    (isActive ? 'bg-[var(--fn-brand)] text-white' : 'text-[var(--fn-muted)] hover:bg-gray-100')

  return (
    <div className="min-h-screen flex flex-col">
      <header className="card rounded-none border-x-0 border-t-0 sticky top-0 z-10">
        <div className="max-w-5xl mx-auto px-4 h-14 flex items-center gap-2">
          <div className="font-extrabold text-[var(--fn-brand)] mr-2">Força Nova</div>
          <nav className="flex gap-1 flex-1 overflow-x-auto">
            {isAdmin && <NavLink to="/dashboard" className={linkCls}>Painel</NavLink>}
            <NavLink to="/" className={linkCls} end>Catálogo</NavLink>
            <NavLink to="/orcamento" className={linkCls}>Orçamento</NavLink>
            <NavLink to="/vendas" className={linkCls}>Vendas</NavLink>
            {isAdmin && <NavLink to="/regras" className={linkCls}>Regras de Preço</NavLink>}
            {isAdmin && <NavLink to="/compras" className={linkCls}>Compras</NavLink>}
            {isAdmin && <NavLink to="/estoque" className={linkCls}>Estoque</NavLink>}
            {isAdmin && <NavLink to="/usuarios" className={linkCls}>Usuários</NavLink>}
          </nav>
          <div className="hidden sm:block text-sm text-[var(--fn-muted)]">{profile?.nome}</div>
          <button onClick={signOut} className="text-sm text-[var(--fn-muted)] hover:text-red-600 px-2">
            Sair
          </button>
        </div>
      </header>
      <main className="flex-1 max-w-5xl mx-auto w-full px-4 py-4">{children}</main>
    </div>
  )
}
