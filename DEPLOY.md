# Deploy Frequencia40-Gamma (sem OpenRouter)

## Passo 1 — Teste local com Groq

1. Conta em https://console.groq.com → criar API key  
2. No PowerShell / terminal:

```bash
# Windows PowerShell
$env:LLM_PROVIDER="groq"
$env:GROQ_API_KEY="gsk_SUA_CHAVE"
$env:GROQ_DEFAULT_MODEL="llama-3.3-70b-versatile"

# Linux / macOS
export LLM_PROVIDER=groq
export GROQ_API_KEY=gsk_SUA_CHAVE
export GROQ_DEFAULT_MODEL=llama-3.3-70b-versatile
```

3. Suba a API:

```bash
cd backend
pip install -r requirements.txt
uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

4. Teste: http://127.0.0.1:8000/health  
   Deve mostrar `"provider":"groq"` e `"version":"...`.

---

## Passo 2 — Deploy da API (Railway — recomendado)

### Opção A: Railway

1. Conta em https://railway.app  
2. New Project → Deploy from GitHub (suba só a pasta `backend`)  
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
| `LLM_PROVIDER` | `groq` |
| `GROQ_API_KEY` | sua chave gsk_... |
| `GROQ_DEFAULT_MODEL` | `llama-3.3-70b-versatile` |
| `DATA_DIR` | `/data` |
| `APP_NAME` | `Frequencia40-Gamma` |

4. Generate Domain no Railway → algo como  
   `https://frequencia40-api-production.up.railway.app`

5. No app Gamma → Settings → cole essa URL **sem barra no final** → Testar → Salvar.

### Opção B: Render

1. https://render.com → New → Web Service  
2. Root: pasta `backend`, Docker  
3. Mesmas env vars acima  
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
| Groq (free tier generoso) | grátis na maioria dos usos |
| Railway hobby / free trial | ~US$ 0–5/mês no começo |
| Domínio .com.br | ~R$ 40/ano (opcional) |

---

## Checklist final

- [ ] `/health` na URL pública retorna `ok` + `provider: groq`
- [ ] App Settings aponta para a URL pública
- [ ] Chat responde sem o PC ter Ollama ligado
- [ ] Memória e anexos ainda funcionam

Pronto: API no ar só no Railway + Groq. OpenRouter removido.
