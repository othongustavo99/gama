/// Apresentação provisória de texto durante streaming.
///
/// O conteúdo original continua completo na resposta e no histórico. Enquanto
/// o modelo ainda escreve, evitamos que Markdown inacabado e milhares de linhas
/// vazias ocupem a tela inteira ou disparem widgets caros de mídia/fórmulas.
String streamingTextPreview(String value, {int maxCharacters = 16000}) {
  if (value.isEmpty) return '';
  // Corta antes dos regex para não percorrer dezenas de milhares de caracteres
  // a cada atualização de um stream longo. O texto persistido não é alterado.
  var text = value;
  if (maxCharacters > 0 && text.length > maxCharacters) {
    var start = text.length - maxCharacters;
    // Evita iniciar no segundo elemento de um par surrogate UTF-16.
    if (start > 0 && start < text.length &&
        text.codeUnitAt(start) >= 0xDC00 &&
        text.codeUnitAt(start) <= 0xDFFF) {
      start++;
    }
    text = '… [prévia anterior ocultada durante a geração]\n\n${text.substring(start)}';
  }
  text = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  // Espaços sucessivos e quebras longas não precisam ser exibidos integralmente.
  text = text.replaceAll(RegExp(r'\n[ \t]*\n(?:[ \t]*\n)+'), '\n\n');
  // Não normalize quebras/espaços dentro de código; só compacte sequências
  // absurdamente longas, sem modificar o resultado final persistido.
  text = text.replaceAll(RegExp(r'[ \t]{400,}'), ' ');
  return text;
}
