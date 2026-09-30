# Frequência40 / Gamma — Passos 1 e 2 (nuvem + deploy)

## Passo 1 — Provider nuvem

Arquivos backend a substituir/adicionar:

```
backend/app/config.py      ← substituir
backend/app/llm.py         ← NOVO (substitui o uso direto de ollama.py)
backend/app/routes/chat.py ← substituir
backend/app/main.py        ← substituir
backend/app/core/memory.py ← substituir (DATA_DIR no deploy)
backend/requirements.txt   ← ok como está
backend/Dockerfile         ← NOVO
backend/.env.example       ← NOVO
```

O arquivo `ollama.py` pode ficar (não quebra), mas o chat agora usa `llm.py`.

### Teste local com OpenRouter

1. Conta em https://openrouter.ai → criar API key  
2. No `backend`:

```bash
# Windows PowerShell
$env:LLM_PROVIDER="openrouter"
$env:OPENROUTER_API_KEY="sk-or-v1-SUA_CHAVE"
$env:OPENROUTER_DEFAULT_MODEL="openai/gpt-4o-mini"

cd backend
.\venv\Scripts\activate
uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload
```

3. Abra http://127.0.0.1:8000/health  
   Deve mostrar `"provider":"openrouter"` e `"version":"0.5.0"`.

4. No app Gamma → Settings → URL `http://127.0.0.1:8000` → Testar → Salvar  
5. Mande uma mensagem. O stream continua igual.

### Voltar para Ollama local

```bash
$env:LLM_PROVIDER="ollama"
# ou não defina nada (default = ollama)
```

### Groq (alternativa)

```bash
$env:LLM_PROVIDER="groq"
$env:GROQ_API_KEY="gsk_..."
$env:GROQ_DEFAULT_MODEL="llama-3.3-70b-versatile"
```

---

## Passo 2 — Deploy da API (Railway — mais simples)

### Opção A: Railway (recomendado)

1. Conta em https://railway.app  
2. New Project → Deploy from GitHub (subá só a pasta `backend`)  
   **ou** Railway CLI:

```bash
cd backend
railway login
railway init
railway up
```

3. Variables no painel Railway:

| Key | Value |
|-----|--------|
| `LLM_PROVIDER` | `openrouter` |
| `OPENROUTER_API_KEY` | sua chave |
| `OPENROUTER_DEFAULT_MODEL` | `openai/gpt-4o-mini` |
| `DATA_DIR` | `/data` |
| `APP_NAME` | `Frequencia40-Gamma` |

4. Generate Domain no Railway → algo como  
   `https://frequencia40-api-production.up.railway.app`

5. No app Gamma → Settings → cole essa URL **sem barra no final** → Testar → Salvar.

### Opção B: Render

1. https://render.com → New → Web Service  
2. Root: pasta `backend`, Docker  
3. Mesmas env vars  
4. Plano free funciona para demo (pode “dormir” após inatividade)

### Domínio próprio (opcional)

No Registro.br / Cloudflare:

- Tipo **CNAME**: `api` → hostname do Railway/Render  
- No app: `https://api.seudominio.com`

HTTPS já vem no Railway/Render.

---

## Custos aproximados (início)

| Item | Custo |
|------|--------|
| OpenRouter gpt-4o-mini | centavos por muitas mensagens |
| Railway hobby / free trial | ~US$ 0–5/mês no começo |
| Domínio .com.br | ~R$ 40/ano (opcional) |

---

## Checklist final

- [ ] `/health` na URL pública retorna `ok` + `provider`
- [ ] App Settings aponta para a URL pública
- [ ] Chat responde sem o PC ter Ollama ligado
- [ ] Memória e anexos ainda funcionam

Pronto: API no ar, PC pode desligar.
