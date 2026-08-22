export default function NotConfigured() {
  return (
    <div className="min-h-screen flex items-center justify-center p-6">
      <div className="card max-w-lg w-full p-8">
        <h1 className="text-xl font-bold mb-2">Falta conectar o Supabase</h1>
        <p className="text-[var(--fn-muted)] mb-4">
          O site está pronto, mas ainda não sabe qual é o seu banco de dados.
        </p>
        <ol className="list-decimal ml-5 space-y-2 text-sm">
          <li>Copie o arquivo <code className="bg-gray-100 px-1 rounded">.env.example</code> para <code className="bg-gray-100 px-1 rounded">.env</code>.</li>
          <li>No Supabase, vá em <b>Project Settings → API</b>.</li>
          <li>Cole a <b>Project URL</b> e a <b>anon public key</b> no arquivo <code className="bg-gray-100 px-1 rounded">.env</code>.</li>
          <li>Pare o site (Ctrl+C) e rode <code className="bg-gray-100 px-1 rounded">npm run dev</code> de novo.</li>
        </ol>
      </div>
    </div>
  )
}
