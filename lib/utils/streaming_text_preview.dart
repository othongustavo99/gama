/// Apresentação provisória de texto durante streaming.
///
/// O conteúdo original continua completo na resposta e no histórico. Enquanto
/// o modelo ainda escreve, evitamos que Markdown inacabado e milhares de linhas
/// vazias ocupem a tela inteira ou disparem widgets caros de mídia/fórmulas.
String streamingTextPreview(String value) {
  var text = value;
  text = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  // Espaços sucessivos e quebras longas não precisam ser exibidos integralmente.
  text = text.replaceAll(RegExp(r'\n[ \t]*\n(?:[ \t]*\n)+'), '\n\n');
  // Não normalize quebras/espaços dentro de código; só compacte sequências
  // absurdamente longas, sem modificar o resultado final persistido.
  text = text.replaceAll(RegExp(r'[ \t]{400,}'), ' ');
  return text;
}
