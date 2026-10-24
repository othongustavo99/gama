/// Identifica quando um pedido de imagem depende de uma imagem anterior.
///
/// Palavras como "versão" ou "transformação" não são referência por si só:
/// "crie uma foto sua em versão humana" deve gerar uma imagem do zero.
class ImageReferenceIntent {
  ImageReferenceIntent._();

  static final RegExp _explicitReference = RegExp(
    r'\b(?:essa|esta|dessa|desta|naquela|aquela|nessa|nesta|daquela|'
    r'essa mesma|esta mesma|a ultima|a última|da ultima|da última)\s+'
    r'(?:imagem|foto|ilustra[cç][aã]o|desenho|arte|figura)\b|'
    r'\b(?:imagem|foto|ilustra[cç][aã]o|desenho|arte|figura)\s+'
    r'(?:anterior|acima|que (?:voc[eê]|a gama|a gamma) (?:fez|gerou|criou)|'
    r'que (?:enviei|anexei))\b|'
    r'\b(?:isso|nela|nele|nessa|nela mesma|nessa mesma|a anterior|'
    r'a de antes|a ultima|a última)\b',
    caseSensitive: false,
  );

  static final RegExp _editAction = RegExp(
    r'\b(?:edita|edite|editar|modifica|modifique|modificar|'
    r'altera|altere|alterar|muda|mude|mudar|troca|troque|trocar|'
    r'substitui|substitua|substituir|remove|remova|remover|'
    r'retira|retire|retirar|adiciona|adicione|adicionar|'
    r'inclui|inclua|incluir|transforma|transforme|transformar|'
    r'deixa|deixe|coloca|coloque|recorta|recorte|'
    r'melhora|melhore|melhorar|aprimora|aprimore|'
    r'varia|varie|variar|refa[cç]a|recrie|regenere)\b',
    caseSensitive: false,
  );

  static final RegExp _newCreation = RegExp(
    r'\b(?:cria|crie|criar|gera|gere|gerar|desenha|desenhe|'
    r'desenhar|imagina|imagine|imaginar|produza|produzir|'
    r'fa[cç]a|faz|fazer|quero|create|generate|draw|make)\b',
    caseSensitive: false,
  );

  static final RegExp _information = RegExp(
    r'^\s*(?:como|por que|porque|qual|o que|explique|me ensine|tutorial|'
    r'quais ferramentas)\b',
    caseSensitive: false,
  );

  /// True apenas quando há uma edição/variação da mídia anterior implícita
  /// ou explícita. Anexar uma nova imagem continua sendo decisão do usuário.
  static bool requiresPreviousImage(String text) {
    final request = text.trim();
    if (request.isEmpty || _information.hasMatch(request)) return false;
    if (_explicitReference.hasMatch(request)) return true;
    if (_newCreation.hasMatch(request)) return false;
    return _editAction.hasMatch(request);
  }
}
