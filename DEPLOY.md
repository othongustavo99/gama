# Gama — Release sem depender do PC

## Arquitetura

```text
APK Flutter -> HTTPS -> FastAPI -> rede Docker -> Ollama -> qwen2.5-coder:7b
```

O Ollama não é exposto à internet. Somente a API FastAPI publica a porta 8000.

## Requisitos do servidor

Use uma máquina/VM com pelo menos 8 GB de RAM; 16 GB é mais confortável para o modelo,
contexto e sistema. GPU é opcional, mas acelera bastante a inferência.

O modelo `qwen2.5-coder:7b` distribuído pelo Ollama é aproximadamente 4,7 GB em Q4_K_M.

## 1. Instalar Docker

Instale Docker + Docker Compose no servidor Linux.

## 2. Copiar o projeto

Envie esta pasta para o servidor e entre nela:

```bash
cd gama
```

## 3. Definir domínio

Crie um arquivo `.env` na raiz:

```env
APP_URL=https://api.seudominio.com
WEB_SEARCH_ENABLED=1
```

## 4. Subir

```bash
docker compose up -d --build
```

Na primeira inicialização o container `model-init` baixa automaticamente:

```text
qwen2.5-coder:7b
```

Isso pode demorar e usa vários GB de disco.

## 5. Verificar

```bash
docker compose ps
docker compose logs api
docker compose logs model-init
```

Teste:

```bash
curl http://127.0.0.1:8000/health
```

O retorno deve indicar `"provider":"ollama"` e `"llm":"online"`.

## 6. HTTPS

Para o APK Release, publique a API atrás de HTTPS usando um domínio e um proxy reverso
como Caddy ou Nginx. Não publique `11434` na internet.

## 7. Configurar o Flutter

Abra:

```text
lib/core/constants.dart
```

Troque:

```dart
static const String apiBaseUrl = 'https://SEU-DOMINIO-DA-API';
```

pelo domínio HTTPS real da API.

Depois:

```powershell
flutter clean
flutter pub get
flutter build apk --release
```

O APK não precisa do seu PC ligado. O PC pode estar completamente desligado: o modelo
está no servidor.

## Modelo

Padrão:

```text
qwen2.5-coder:7b
```

O app não oferece modelos que não estejam liberados pelo backend.
