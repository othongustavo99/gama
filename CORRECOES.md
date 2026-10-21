Correções incluídas

- Cores do hub e do chip Oficina agora usam a paleta do tema.
- Conversas guardam o modo Oficina em um novo campo Hive opcional (campo 5), compatível com registros antigos.
- Home e drawer identificam o modo pelo campo persistido, mesmo depois de renomear a conversa; o drawer mostra o ícone do modo.
- A Oficina reutiliza o rascunho vazio e não cria uma conversa adicional ao tocar em um cartão. O primeiro envio mantém a criação condicional.
- O título padrão da conversa é substituído pelo título gerado a partir do primeiro pedido.
- O estado vazio usa o subtítulo e as sugestões configurados por tipo de Oficina.
- Textos técnicos sobre skills, modelo e provedor foram simplificados.

O ZIP contém o projeto completo sem a pasta .git e sem artefatos de build locais. O código original de gama.zip foi preservado.

Atualização do hub da Oficina

- Cores por modo: laranja para Imagem, azul para Vídeo e verde para Programar, sem alterar a paleta.
- Cartões maiores com descrição e dois exemplos clicáveis que abrem o chat com o texto preenchido.
- Grade de três colunas no Windows e cartões verticais em telas móveis.
- Seção Recentes da Oficina, com cartões para conversas que têm modo; imagens da Biblioteca associadas à conversa viram miniaturas reais.
- Animação escalonada de entrada, escala de pressão em 0,98 e transição Hero do ícone do modo até o chat.
- Biblioteca registra a conversa de origem para relacionar imagens às criações recentes.

Atualização das telas por modo

- Cabeçalho da Oficina identifica o modo ativo e oferece retorno à Oficina; oculta o modelo em Imagem e Vídeo, mantendo-o apenas em Programar.
- Composer mostra o chip do modo ativo com ação para sair dele, usa placeholders próprios e oculta voz/comandos de modo que não se aplicam.
- Imagem: seletores de proporção e estilo, placeholder com shimmer, ações para variar/editar/regenerar/ver o prompt, e comparação antes/depois após edição. Sugestões que precisam de uma imagem abrem o seletor de anexos.
- Vídeo: dependência media_kit para reprodução inline em Android e Windows; cartão mostra controles, duração/resolução e progresso da geração com tempo decorrido e cancelamento. Removidos custo e texto de aviso.
- Programar: ZIP apresenta árvore de arquivos com tamanhos e prévia em painel lateral no Windows ou bottom sheet em telas móveis; atalhos de ZIP, GitHub e erro ficam no composer. A análise do projeto apresenta etapas e tempo decorrido.
- O manifesto inclui media_kit, media_kit_video e media_kit_libs_video. A resolução de pacotes não foi concluída neste ambiente; executar `flutter pub get` antes de compilar.

Polimento de design e estados de carregamento

- Tokens centralizados em `lib/core/design_tokens.dart` para espaçamento, raios, elevação e duração de transições; tema e cartões da Oficina passaram a reutilizá-los.
- Fonte variável Inter e licença SIL OFL incluídas em `assets/fonts/`; Inter configurada como tipografia global do tema.
- Novo `GamaSkeleton` reutilizável para listas, grades, botões e estados de carregamento. Os `CircularProgressIndicator` de `lib/` foram removidos.
- `AnimatedSwitcher` aplicado na troca entre estados da conversa, na entrada da home e no ícone de enviar/parar; feedback tátil na seleção do modo e abertura da Oficina.
- Estado vazio e cartões de artefato extraídos para `lib/widgets/empty_state.dart` e `lib/widgets/artifact_status_list.dart`.
- Respostas com várias imagens agora usam uma grade de duas colunas; uma única imagem continua ocupando a largura disponível.
