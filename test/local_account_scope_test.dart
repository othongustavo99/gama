import 'package:flutter_test/flutter_test.dart';
import 'package:gama/services/local_account_scope.dart';

void main() {
  test('contas diferentes não compartilham arquivos, Hive ou preferências', () {
    final a = LocalAccountScope.fromSession(
      loggedIn: true,
      provider: 'google',
      userId: 'google_email_alpha@example.com',
    );
    final b = LocalAccountScope.fromSession(
      loggedIn: true,
      provider: 'google',
      userId: 'google_email_beta@example.com',
    );
    expect(a.key, isNot(b.key));
    expect(a.conversationsBox, isNot(b.conversationsBox));
    expect(a.messagesBox, isNot(b.messagesBox));
    expect(a.draftPrefix, isNot(b.draftPrefix));
    expect(a.libraryPrefsKey, isNot(b.libraryPrefsKey));
    expect(a.libraryDirectoryName, isNot(b.libraryDirectoryName));
    expect(a.pendingGenerationsPrefsKey, isNot(b.pendingGenerationsPrefsKey));
    expect(a.remindersPrefsKey, isNot(b.remindersPrefsKey));
    expect(a.feedbackPrefix, isNot(b.feedbackPrefix));
  });

  test('mesmo usuário em Android e Windows gera o mesmo namespace', () {
    LocalAccountScope scope() => LocalAccountScope.fromSession(
      loggedIn: true,
      provider: 'google',
      userId: 'google_email_user@example.com',
    );
    expect(scope().conversationsBox, scope().conversationsBox);
  });

  test('namespace não revela e-mail no nome dos arquivos', () {
    final scope = LocalAccountScope.fromSession(
      loggedIn: true,
      provider: 'google',
      userId: 'google_email_private@example.com',
    );
    expect(scope.libraryDirectoryName, isNot(contains('private')));
    expect(scope.libraryDirectoryName, isNot(contains('@')));
    expect(scope.key, matches(RegExp(r'^google_[a-f0-9]{32}$')));
  });

  test('sessão deslogada nunca acessa dados da última conta', () {
    final loggedOut = LocalAccountScope.fromSession(
      loggedIn: false,
      provider: 'google',
      userId: 'google_email_user@example.com',
    );
    final loggedIn = LocalAccountScope.fromSession(
      loggedIn: true,
      provider: 'google',
      userId: 'google_email_user@example.com',
    );
    expect(loggedOut.key, 'signed_out');
    expect(loggedOut.messagesBox, isNot(loggedIn.messagesBox));
  });
}
