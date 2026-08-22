import { useEffect, useMemo, useState } from 'react'
import { supabase } from '../lib/supabase.js'
import { useAuth } from '../auth/AuthContext.jsx'
import { brl } from '../lib/format.js'
import ExplicacaoPreco from '../components/ExplicacaoPreco.jsx'

export default function Catalogo() {
  const { profile, isAdmin } = useAuth()
  const [regioes, setRegioes] = useState([])
  const [regiaoId, setRegiaoId] = useState('')
  const [itens, setItens] = useState([])
  const [busca, setBusca] = useState('')
  const [categoria, setCategoria] = useState('')
  const [carregando, setCarregando] = useState(true)
  const [explicar, setExplicar] = useState(null)  // { produto_id, descricao }

  // regiões (admin escolhe; vendedor já vem na sua)
  useEffect(() => {
    supabase.from('regioes').select('id, codigo, nome, ativo')
      .eq('ativo', true).order('ordem')
      .then(({ data }) => {
        const rs = data || []
        setRegioes(rs)
        setRegiaoId(profile?.regiao_padrao_id || rs[0]?.id || '')
      })
  }, [profile])

  // catálogo da região selecionada
  useEffect(() => {
    if (!regiaoId) return
    setCarregando(true)
    supabase.rpc('fn_catalogo', { p_regiao: regiaoId }).then(({ data }) => {
      setItens(data || [])
      setCarregando(false)
    })
  }, [regiaoId])

  const categorias = useMemo(
    () => [...new Set(itens.map(i => i.categoria).filter(Boolean))].sort(),
    [itens]
  )

  const filtrados = useMemo(() => {
    const q = busca.trim().toLowerCase()
    return itens.filter(i => {
      if (categoria && i.categoria !== categoria) return false
      if (!q) return true
      return [i.descricao, i.codigo, i.marca, i.categoria]
        .filter(Boolean).some(x => String(x).toLowerCase().includes(q))
    })
  }, [itens, busca, categoria])

  return (
    <div>
      {/* barra de busca + região */}
      <div className="flex flex-col sm:flex-row gap-2 mb-3">
        <input className="input flex-1" placeholder="Buscar por descrição, código, marca…"
          value={busca} onChange={e => setBusca(e.target.value)} />
        {(isAdmin || regioes.length > 1) && (
          <select className="input sm:w-64" value={regiaoId}
            onChange={e => setRegiaoId(e.target.value)}>
            {regioes.map(r => <option key={r.id} value={r.id}>{r.nome}</option>)}
          </select>
        )}
      </div>

      {/* filtro por categoria */}
      {categorias.length > 0 && (
        <div className="flex gap-1.5 overflow-x-auto pb-2 mb-1">
          <Chip ativo={!categoria} onClick={() => setCategoria('')}>Todas</Chip>
          {categorias.map(c => (
            <Chip key={c} ativo={categoria === c} onClick={() => setCategoria(c)}>{c}</Chip>
          ))}
        </div>
      )}

      <div className="text-xs text-[var(--fn-muted)] mb-2">
        {carregando ? 'Carregando…' : `${filtrados.length} produto(s)`}
      </div>

      {/* lista */}
      <div className="grid gap-2">
        {filtrados.map(i => (
          <button key={i.produto_id}
            onClick={() => isAdmin && setExplicar(i)}
            className="card p-3 flex items-center gap-3 text-left hover:border-[var(--fn-brand)] transition">
            <div className="flex-1 min-w-0">
              <div className="font-medium leading-snug">{i.descricao}</div>
              <div className="text-xs text-[var(--fn-muted)] mt-0.5 flex gap-2 flex-wrap">
                {i.codigo && <span>Cód. {i.codigo}</span>}
                {i.categoria && <span>· {i.categoria}</span>}
                {i.usou_preco_manual && <span className="text-amber-600">· preço manual</span>}
              </div>
            </div>
            <div className="text-right shrink-0">
              <div className="font-bold text-[var(--fn-brand)]">{brl(i.preco_final)}</div>
              {isAdmin && <div className="text-[10px] text-[var(--fn-muted)]">por quê?</div>}
            </div>
          </button>
        ))}
      </div>

      {explicar && (
        <ExplicacaoPreco item={explicar} regiaoId={regiaoId} onClose={() => setExplicar(null)} />
      )}
    </div>
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
