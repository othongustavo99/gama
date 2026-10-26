import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import '../core/constants.dart';
import 'auth_interceptor.dart';
import 'identity_service.dart';
import 'settings_service.dart';

/// Google Play Billing: nunca aceita preço ou direito informado pelo cliente.
/// A liberação do plano depende de /account/billing/play/verify no backend.
/// A verificação/recuperação funciona somente com conta Google autenticada.
class GammaPlayBillingService extends ChangeNotifier {
  GammaPlayBillingService._();
  static final GammaPlayBillingService instance = GammaPlayBillingService._();

  final InAppPurchase _store = InAppPurchase.instance;
  StreamSubscription<List<PurchaseDetails>>? _subscription;
  final Set<String> _processing = <String>{};
  final Map<String, String> _planNames = <String, String>{};
  final Map<String, ProductDetails> _products = <String, ProductDetails>{};

  bool _initialized = false;
  bool loading = false;
  bool checkoutAvailable = false;
  bool purchasePending = false;
  String? error;
  String? notice;

  bool get supported => Platform.isAndroid;
  List<ProductDetails> get products => List.unmodifiable(_products.values);
  String planFor(String productId) => switch (_planNames[productId]) {
    'pro' => 'Pro',
    'creator' => 'Creator',
    _ => 'Assinatura',
  };

  Future<void> initialize() async {
    if (_initialized || !supported) return;
    _initialized = true;
    // Escutar antes de consultar o catálogo: eventos podem chegar depois que
    // o aplicativo retorna da Google Play ou é reaberto.
    _subscription = _store.purchaseStream.listen(
      (purchases) { unawaited(_handlePurchases(purchases)); },
      onError: (Object _) {
        error = 'A Google Play não conseguiu atualizar sua compra. Use Restaurar compras.';
        notifyListeners();
      },
    );
  }

  Future<Map<String, dynamic>> _request(String route, {Object? body}) async {
    if (IdentityService.instance.provider != 'google') {
      throw StateError('Entre com sua conta Google para gerenciar assinaturas.');
    }
    final identity = IdentityService.instance.userId;
    final dio = Dio(BaseOptions(
      baseUrl: SettingsService.instance.baseUrl,
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 25),
      headers: AppConstants.authHeaders,
    ));
    dio.interceptors.add(GammaAuthInterceptor(client: dio));
    try {
      final Response<dynamic> result = body == null
          ? await dio.get<dynamic>(route)
          : await dio.post<dynamic>(route, data: body);
      if (identity != IdentityService.instance.userId ||
          IdentityService.instance.provider != 'google') {
        throw StateError('A conta Google mudou. Entre novamente antes de continuar.');
      }
      if (result.data is! Map) throw const FormatException('Resposta inválida');
      return Map<String, dynamic>.from(result.data as Map);
    } on DioException catch (exception) {
      if (exception.response?.statusCode == 401 || exception.response?.statusCode == 403) {
        throw StateError('Esta compra não pertence à conta Gamma atual, ou sua sessão expirou.');
      }
      throw StateError('Não foi possível consultar a Google Play pelo servidor. Tente novamente.');
    } finally {
      dio.close();
    }
  }

  Future<void> loadCatalog() async {
    if (!supported) return;
    await initialize();
    loading = true;
    error = null;
    notice = null;
    checkoutAvailable = false;
    _products.clear();
    notifyListeners();
    try {
      final status = await _request('/account/billing/status');
      if (status['checkout_enabled'] != true ||
          status['entitlements_auto_granted'] != true) {
        notice = 'Assinaturas ainda não foram habilitadas para esta conta.';
        return;
      }
      final catalog = await _request('/account/billing/play/catalog');
      if (catalog['available'] != true || catalog['products'] is! List) {
        notice = 'O catálogo da Google Play ainda não está disponível.';
        return;
      }
      _planNames.clear();
      for (final item in (catalog['products'] as List)) {
        if (item is Map && item['id'] is String && item['plan'] is String) {
          final id = item['id'] as String;
          final plan = item['plan'] as String;
          if (plan == 'pro' || plan == 'creator') _planNames[id] = plan;
        }
      }
      if (_planNames.isEmpty || !await _store.isAvailable()) {
        notice = 'A Google Play não está disponível neste aparelho.';
        return;
      }
      final result = await _store.queryProductDetails(_planNames.keys.toSet());
      if (result.error != null) {
        throw StateError('Não foi possível consultar os preços na Google Play.');
      }
      for (final item in result.productDetails) {
        if (_planNames.containsKey(item.id)) _products[item.id] = item;
      }
      checkoutAvailable = _products.isNotEmpty;
      if (!checkoutAvailable) {
        notice = 'Os produtos ainda não estão publicados para este teste na Play Console.';
      }
    } catch (_) {
      error = 'Não foi possível carregar as assinaturas. Confira a conta e a conexão.';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> purchase(ProductDetails product) async {
    if (!supported || !checkoutAvailable || !_products.containsKey(product.id) || purchasePending) return;
    if (IdentityService.instance.provider != 'google') {
      error = 'Faça login com o Google antes de assinar.';
      notifyListeners();
      return;
    }
    purchasePending = true;
    error = null;
    notice = null;
    notifyListeners();
    try {
      final binding = await _request('/account/billing/play/account-binding');
      final opaque = binding['obfuscated_account_id'];
      if (opaque is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(opaque)) {
        throw StateError('Vínculo de conta inválido.');
      }
      // Para assinaturas a biblioteca usa buyNonConsumable, pois não devem
      // ser consumidas como produtos avulsos.
      final started = await _store.buyNonConsumable(
        purchaseParam: PurchaseParam(
          productDetails: product,
          applicationUserName: opaque,
        ),
      );
      if (!started) throw StateError('A Google Play não conseguiu iniciar a compra.');
      notice = 'Finalize a operação na Google Play. A verificação será automática.';
    } catch (_) {
      error = 'Não foi possível iniciar sua compra. Nenhum plano foi alterado.';
      purchasePending = false;
    }
    notifyListeners();
  }

  Future<void> restore() async {
    if (!supported) return;
    error = null;
    notice = 'Procurando assinaturas associadas à conta da loja...';
    notifyListeners();
    try {
      await _store.restorePurchases();
      notice = 'Consulta enviada. Assinaturas encontradas serão verificadas pelo servidor.';
    } catch (_) {
      error = 'Não foi possível restaurar as compras agora. Tente novamente.';
    }
    notifyListeners();
  }

  Future<void> _handlePurchases(List<PurchaseDetails> purchases) async {
    for (final purchase in purchases) {
      if (purchase.status == PurchaseStatus.pending) {
        purchasePending = true;
        notice = 'Pagamento pendente na Google Play. O plano ainda não foi liberado.';
        notifyListeners();
        continue;
      }
      if (purchase.status == PurchaseStatus.error ||
          purchase.status == PurchaseStatus.canceled) {
        purchasePending = false;
        error = purchase.status == PurchaseStatus.canceled
            ? 'Compra cancelada.'
            : 'A Google Play não conseguiu concluir a compra.';
        notifyListeners();
        continue;
      }
      if (purchase.status != PurchaseStatus.purchased &&
          purchase.status != PurchaseStatus.restored) continue;
      final token = purchase.verificationData.serverVerificationData;
      if (token.isEmpty || !_processing.add(token)) continue;
      try {
        // Sempre consultar o backend com a identidade Google atual.
        // Se o token for de outra conta, o servidor rejeitará.
        final result = await _request('/account/billing/play/verify', body: {
          'purchase_token': token,
        });
        if (result['entitlement_applied'] != true || result['verified_active'] != true) {
          throw StateError('Assinatura não confirmada.');
        }
        // O backend já confirmou/registrou o direito e reconheceu a compra;
        // falha da confirmação local não reverte um direito válido.
        if (purchase.pendingCompletePurchase) {
          try {
            await _store.completePurchase(purchase);
          } catch (_) {
            notice = 'Assinatura confirmada. A atualização da loja pode demorar um pouco.';
          }
        }
        purchasePending = false;
        error = null;
        notice ??= 'Assinatura confirmada! Atualize a tela Meu plano e consumo.';
      } catch (_) {
        purchasePending = false;
        error = 'Sua compra ainda não foi validada. Use Restaurar compras antes de tentar comprar novamente.';
        // Não reconhecer transações rejeitadas ou sem direito confirmado.
      } finally {
        _processing.remove(token);
        notifyListeners();
      }
    }
  }
}
