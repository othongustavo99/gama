# Gamma — Fase 01 | Correções essenciais de front-end

**Base do pacote:** `gama(20261111-171024).zip`, recebido em 11/11/2026.  
**Escopo:** exclusivamente Flutter, experiência de uso, navegação, contraste e Biblioteca local.  
**Back-end, APIs, Railway e modelos:** inalterados.

## 1. Arquivos do pacote

### Substituir (9 arquivos completos)
- `lib/core/gama_colors.dart` — token `onAccent` com contraste adequado.
- `lib/main.dart` — `ColorScheme.onPrimary` respeita o tema.
- `lib/widgets/app_drawer.dart` — ação Nova conversa sem gradiente de contraste inconsistente.
- `lib/widgets/chat_composer.dart` — cores acessíveis para Enviar e Parar.
- `lib/screens/chat_screen.dart` — Ctrl+V mantém colagem de texto durante geração; mídia continua protegida.
- `lib/screens/settings_screen.dart` — Conta abre perfil e privacidade em vez da exclusão diretamente.
- `lib/screens/library_screen.dart` — títulos móveis, cache de metadados e exclusão segura do índice.
- `lib/screens/images_screen.dart` — títulos móveis e metadados assíncronos da galeria.
- `lib/screens/scheduled_screen.dart` — remove segundo botão Novo lembrete e melhora contraste do FAB.

### Adicionar (3 arquivos completos)
- `lib/screens/account_screen.dart` — nova página Conta e privacidade.
- `lib/utils/local_file_metadata.dart` — leitura assíncrona de arquivos em lotes.
- `test/frontend_phase1_ux_test.dart` — regressões de contraste, conta, galeria e metadados.

### Excluir
- **Nenhum arquivo.**

## 2. Como aplicar no Windows (PowerShell)

1. Faça um commit ou backup antes de modificar. Aplique sobre o projeto que corresponde ao ZIP auditado.
2. Extraia o ZIP **dentro da raiz do repositório**, em que ficam `pubspec.yaml`, `lib/` e `test/`. Os caminhos do ZIP começam em `lib/` ou `test/`, **não** em `gama/lib/`.
3. Exemplo (troque os caminhos conforme seus diretórios):

```powershell
$repo = 'C:\Users\othon\Documents\frequencia40\gama'
$zip  = 'C:\Users\othon\Downloads\gama_frontend_fase_01.zip'
Set-Location $repo
git status --short
Expand-Archive -LiteralPath $zip -DestinationPath $repo -Force
flutter pub get
flutter analyze
flutter test test/frontend_phase1_ux_test.dart
flutter test
```

**Importante:** se houver alterações locais feitas depois do ZIP-base, confira `git diff` antes de substituir. Não aplique o pacote em uma versão posterior conflitante sem mesclar as mudanças.

## 3. Testar no aplicativo

### Android (tema claro e escuro)
- Abrir **Configurações > Conta**: deverá abrir **Conta e privacidade**. A exclusão aparece somente após tocar em **Solicitar exclusão da conta**. NÃO confirme a exclusão para testar.
- Em **Biblioteca** e **Galeria**, verificar título em tela estreita e rolagem sem travar.
- Em **Agendado**, há **um único** botão principal `+`, que abre Novo lembrete.
- Conferir ícone do envio e texto de Nova conversa legíveis sobre o botão laranja; botão Parar legível durante geração.
- Biblioteca: pesquisar, abrir, baixar, remover uma entrada **de teste**; conferir indicação de item indisponível e atualizar.

### Windows
- Inicie uma resposta longa. Enquanto a Gamma responde, **Ctrl+V com texto** deve colar no rascunho (sem enviar).
- Em repouso, **Ctrl+V com imagem ou arquivo** deve continuar anexando normalmente.
- Durante geração, anexos novos não são aceitos pelo atalho (intencional); **texto continua permitido**.
- Conferir ações de envio, parada e menu lateral em temas claro/escuro.

### Exclusão da Biblioteca (somente com dados descartáveis ou após backup)
- Nunca esvazie sua Biblioteca real só para testar esta fase.
- Confirme que o índice é salvo como vazio antes de tentar limpar a pasta da conta.
- Se a gravação do índice falhar, não deve apagar arquivos locais. Se a limpeza do disco falhar depois, a interface informa o problema, sem mostrar arquivos já removidos como se existissem.
- Arquivos previamente exportados para Downloads não devem ser apagados pela limpeza de arquivos internos da Biblioteca.

## 4. Código e serviços externos

- Não altere `.env`, Railway, rotas HTTP, permissões Android, IDs Google ou `pubspec.yaml`.
- Não é necessário atualizar banco de dados ou executar migrações.
- Execute Android e Windows com os `--dart-define` **que você já usa**, sem compartilhar chaves publicamente ou colocar credenciais em commits.
- O carregamento de arquivos é assíncrono e em lotes de até 24 caminhos únicos por vez. Os metadados são atualizados ao entrar/atualizar a tela; se um arquivo for alterado externamente enquanto ela estiver aberta, use Atualizar.

## 5. Commit sugerido

```powershell
git diff --stat
git status --short
git add lib/core/gama_colors.dart lib/main.dart lib/widgets/app_drawer.dart lib/widgets/chat_composer.dart lib/screens/chat_screen.dart lib/screens/settings_screen.dart lib/screens/account_screen.dart lib/screens/library_screen.dart lib/screens/images_screen.dart lib/screens/scheduled_screen.dart lib/utils/local_file_metadata.dart test/frontend_phase1_ux_test.dart
git commit -m "feat(frontend): fase 1 UX e acessibilidade Gamma"
git push origin main
```

Revise o branch de destino antes de dar push se não estiver na `main`.

## 6. Validação realizada neste ambiente

- Conferência dos arquivos-base contra o ZIP enviado.
- Comparação de diferenças dos 12 arquivos, caminhos e imports adicionados.
- Contraste calculado do acento: ~7,36:1 no tema escuro e ~5,15:1 no claro.
- O ZIP contém **arquivos completos**, não fragmentos ou instruções para edição manual.
- **Limitação:** Flutter e Dart não estão instalados no ambiente de preparação. `flutter analyze`, `flutter test` e builds em dispositivos ainda precisam ser executados no seu computador. Caso apareça erro, encaminhe a saída do terminal antes do commit.

## 7. Próxima fase

A **Fase 02 — Chat Clean** abordará cabeçalho/título de conversa, organização visual do compositor, ações contextuais das mensagens e seleção nativa do texto, preservando envio/voz/anexos.
