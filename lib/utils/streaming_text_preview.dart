/// Apresentação provisória de texto durante streaming.
///
/// O conteúdo original continua completo na resposta e no histórico. Enquanto
/// o modelo ainda escreve, evitamos que Markdown inacabado e milhares de linhas
/// vazias ocupem a tela inteira ou disparem widgets caros de mídia/fórmulas.
String streamingTextPreview(String value, {int maxCharacters = 16000}) {
  if (value.isEmpty) return '';
  var text = value.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  // Espaços sucessivos e quebras longas não precisam ser exibidos integralmente.
  text = text.replaceAll(RegExp(r'\n[ \t]*\n(?:[ \t]*\n)+'), '\n\n');
  // Não normalize quebras/espaços dentro de código; só compacte sequências
  // absurdamente longas, sem modificar o resultado final persistido.
  text = text.replaceAll(RegExp(r'[ \t]{400,}'), ' ');
  if (maxCharacters > 0 && text.length > maxCharacters) {
    // Mostra a parte mais recente para acompanhar a resposta em andamento.
    text = '… [prévia anterior ocultada durante a geração]\n\n' +
        text.substring(text.length - maxCharacters);
  }
  return text;
}
