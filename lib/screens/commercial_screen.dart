import 'dart:io';

import 'package:flutter/material.dart';
import '../widgets/gama_floating_page.dart';

import '../core/gama_colors.dart';
import '../models/commercial_account.dart';
import '../services/commercial_service.dart';
import '../services/identity_service.dart';
import '../services/admin_service.dart';
import '../core/gama_page_route.dart';
import 'admin_dashboard_screen.dart';
import 'play_subscription_screen.dart';

/// Visão de consumo e acesso ao checkout oficial Google Play (Android).
/// Atualiza sempre ao abrir/recarregar, sem cache compartilhado entre contas.
class CommercialScreen extends StatefulWidget {
  final Future<CommercialAccount> Function()? loadAccount;
  final bool requireGoogleAccount;

  const CommercialScreen({
    super.key,
    this.loadAccount,
    this.requireGoogleAccount = true,
  });

  @override
  State<CommercialScreen> createState() => _CommercialScreenState();
}

class _CommercialScreenState extends State<CommercialScreen> {
  CommercialAccount? _account;
  String? _error;
  bool _loading = false;
  int _loadVersion = 0;
  bool _canAdmin = false;
  String? _adminIdentity;

  bool get _isGoogle => !widget.requireGoogleAccount ||
      IdentityService.instance.provider == 'google';

  @override
  void initState() {
    super.initState();
    if (_isGoogle) _refresh();
    if (widget.requireGoogleAccount && IdentityService.instance.provider == 'google') {
      _checkAdmin();
    }
  }

  Future<void> _checkAdmin() async {
    final identity = IdentityService.instance.userId;
    _adminIdentity = identity;
    try {
      final authorized = await AdminService.instance.checkAccess();
      if (!mounted || IdentityService.instance.userId != identity ||
          _adminIdentity != identity) return;
      setState(() => _canAdmin = authorized);
    } catch (_) {
      // Não mostramos o painel até o servidor autorizar explicitamente.
      if (mounted && IdentityService.instance.userId == identity) {
        setState(() => _canAdmin = false);
      }
    }
  }

  Future<void> _refresh() async {
    if (_loading || !_isGoogle) return;
    final version = ++_loadVersion;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final snapshot = await (widget.loadAccount ??
          CommercialService.instance.fetchAccount)();
      if (!mounted || version != _loadVersion) return;
      setState(() => _account = snapshot);
    } catch (error) {
      if (!mounted || version != _loadVersion) return;
      setState(() {
        _error = error is CommercialAccountException
            ? error.message
            : 'Não foi possível carregar seu plano. Tente novamente.';
        // Não mostre informações obsoletas se uma atualização falhar.
        _account = null;
      });
    } finally {
      if (mounted && version == _loadVersion) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.gama.background,
      
      body: GamaFloatingPage(
        actions: [
          if (_canAdmin && _adminIdentity == IdentityService.instance.userId)
            IconButton(
              tooltip: 'Painel administrativo',
              icon: const Icon(Icons.admin_panel_settings_outlined),
              onPressed: () => Navigator.of(context).push(GamaPageRoute(
                builder: (_) => const AdminDashboardScreen(),
              )),
            ),
          IconButton(
            tooltip: 'Atualizar informações do plano',
            onPressed: _loading || !_isGoogle ? null : _refresh,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
        child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 780),
          child: !_isGoogle
              ? _Notice(
                  icon: Icons.lock_outline,
                  title: 'Entre com sua conta Google',
                  detail: 'Planos e créditos pertencem à sua conta. '
                      'Entre com o Google para consultar esses dados.',
                )
              : _loading && _account == null
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                      ? _Notice(
                          icon: Icons.cloud_off_outlined,
                          title: 'Informações indisponíveis',
                          detail: _error!,
                          onRetry: _refresh,
                        )
                      : _account == null
                          ? const SizedBox.shrink()
                          : RefreshIndicator(
                              onRefresh: _refresh,
                              child: _AccountBody(account: _account!),
                            ),
        ),
      )
      ),
    );
  }
}

class _AccountBody extends StatelessWidget {
  final CommercialAccount account;
  const _AccountBody({required this.account});

  String _expiry(BuildContext context, DateTime timestamp) {
    return MaterialLocalizations.of(context)
        .formatMediumDate(timestamp.toLocal());
  }

  @override
  Widget build(BuildContext context) {
    final enforced = account.enforcementActive && !account.limitsPreviewOnly;
    const features = <(String, String, IconData)>[
      ('chat', 'Conversas', Icons.chat_bubble_outline_rounded),
      ('image', 'Imagens', Icons.image_outlined),
      ('video', 'Vídeos', Icons.movie_outlined),
      ('artifact', 'Arquivos ZIP e PDF', Icons.folder_zip_outlined),
    ];
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 36),
      children: [
        Container(
          decoration: BoxDecoration(
            color: context.gama.surfaceCard,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: context.gama.border),
          ),
          padding: const EdgeInsets.all(22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('PLANO ATUAL', style: TextStyle(
                color: context.gama.textMuted,
                fontWeight: FontWeight.w700,
                fontSize: 11,
                letterSpacing: 1,
              )),
              const SizedBox(height: 8),
              Row(children: [
                Icon(Icons.workspace_premium_outlined,
                  color: context.gama.accent, size: 31),
                const SizedBox(width: 10),
                Flexible(child: Text(account.displayPlan,
                  style: TextStyle(color: context.gama.textPrimary,
                    fontSize: 28, fontWeight: FontWeight.w700))),
              ]),
              if (account.expiresAt != null) ...[
                const SizedBox(height: 8),
                Text('Válido até ${_expiry(context, account.expiresAt!)}',
                  style: TextStyle(color: context.gama.textSecondary)),
              ],
              const SizedBox(height: 14),
              Text(enforced ? 'Franquias de teste ativas' :
                'Franquias de teste — aplicação desativada',
                style: TextStyle(color: context.gama.textSecondary)),
            ],
          ),
        ),
        if (Platform.isAndroid) ...[
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => Navigator.of(context).push(GamaPageRoute(
              builder: (_) => const PlaySubscriptionScreen(),
            )),
            icon: const Icon(Icons.shopping_bag_outlined),
            label: const Text('Assinaturas na Google Play'),
          ),
        ],
        const SizedBox(height: 24),
        Text('Utilização de hoje', style: TextStyle(
          fontSize: 19, fontWeight: FontWeight.w700,
          color: context.gama.textPrimary)),
        const SizedBox(height: 5),
        Text('Contagem diária em UTC (reinicia às 00:00 UTC).',
          style: TextStyle(color: context.gama.textMuted, fontSize: 12)),
        const SizedBox(height: 12),
        for (final feature in features) ...[
          _FeatureUsage(
            feature: feature.$1,
            title: feature.$2,
            icon: feature.$3,
            account: account,
            enforced: enforced,
          ),
          const SizedBox(height: 10),
        ],
        const SizedBox(height: 16),
        Text('Créditos internos', style: TextStyle(
          fontSize: 19, fontWeight: FontWeight.w700,
          color: context.gama.textPrimary)),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: context.gama.surfaceCard,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: context.gama.border),
          ),
          child: Row(children: [
            Icon(Icons.toll_outlined, color: context.gama.accent, size: 26),
            const SizedBox(width: 12),
            Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${account.creditsBalance} créditos',
                  style: TextStyle(color: context.gama.textPrimary,
                    fontSize: 20, fontWeight: FontWeight.w700)),
                const SizedBox(height: 3),
                Text('Saldo de testes; não representa dinheiro nem pode ser resgatado.',
                  style: TextStyle(color: context.gama.textMuted,
                    fontSize: 12, height: 1.35)),
              ],
            )),
          ]),
        ),
        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: context.gama.surfaceElevated,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.info_outline_rounded,
              color: context.gama.textSecondary, size: 20),
            const SizedBox(width: 10),
            Expanded(child: Text(
              'Assinaturas pela Google Play permanecem em testes. '
              'Os limites apresentados são experimentais e podem mudar '
              'antes da publicação comercial. Compras exigem validação no servidor.',
              style: TextStyle(color: context.gama.textSecondary,
                fontSize: 13, height: 1.45),
            )),
          ]),
        ),
      ],
    );
  }
}

class _FeatureUsage extends StatelessWidget {
  final String feature;
  final String title;
  final IconData icon;
  final CommercialAccount account;
  final bool enforced;
  const _FeatureUsage({required this.feature, required this.title,
    required this.icon, required this.account, required this.enforced});

  @override
  Widget build(BuildContext context) {
    final used = account.used(feature);
    final limit = account.limit(feature);
    final left = account.remaining(feature);
    final progress = limit == null || limit == 0
        ? 0.0 : (used / limit).clamp(0.0, 1.0).toDouble();
    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: context.gama.surfaceCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: context.gama.borderSoft),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, color: context.gama.textSecondary, size: 20),
          const SizedBox(width: 9),
          Expanded(child: Text(title, style: TextStyle(
            color: context.gama.textPrimary, fontWeight: FontWeight.w600))),
          if (limit != null) Text('$used / $limit', style: TextStyle(
            color: context.gama.textSecondary, fontWeight: FontWeight.w600))
          else Text('$used usadas', style: TextStyle(
            color: context.gama.textSecondary)),
        ]),
        const SizedBox(height: 9),
        if (enforced && limit != null) ...[
          Semantics(
            label: '$title: $used utilizadas de $limit. '
                '${left ?? 0} restantes.',
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 6,
              borderRadius: BorderRadius.circular(4),
              color: context.gama.accent,
              backgroundColor: context.gama.surfaceInput,
            ),
          ),
          const SizedBox(height: 7),
          Text(limit == 0 ? 'Não incluído neste plano' :
            '$left restantes hoje', style: TextStyle(
              color: context.gama.textMuted, fontSize: 12)),
        ] else
          Text(limit == null ? 'Informação de referência indisponível' :
            'Referência experimental: $limit por dia (sem bloqueio)',
            style: TextStyle(color: context.gama.textMuted, fontSize: 12)),
      ]),
    );
  }
}

class _Notice extends StatelessWidget {
  final IconData icon;
  final String title;
  final String detail;
  final VoidCallback? onRetry;
  const _Notice({required this.icon, required this.title,
    required this.detail, this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 42, color: context.gama.textSecondary),
        const SizedBox(height: 16),
        Text(title, textAlign: TextAlign.center, style: TextStyle(
          color: context.gama.textPrimary, fontSize: 19,
          fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Text(detail, textAlign: TextAlign.center, style: TextStyle(
          color: context.gama.textSecondary, height: 1.4)),
        if (onRetry != null) ...[
          const SizedBox(height: 16),
          OutlinedButton.icon(onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('Tentar novamente')),
        ],
      ]),
    ));
  }
}
