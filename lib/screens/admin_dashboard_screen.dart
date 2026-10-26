import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../core/gama_colors.dart';
import '../services/admin_service.dart';
import '../services/identity_service.dart';

/// Painel privado de operação beta. Backend autoriza TODOS os endpoints.
/// Não consulta lista de usuários nem expõe dados de conversas.
class AdminDashboardScreen extends StatefulWidget {
  const AdminDashboardScreen({super.key});
  @override
  State<AdminDashboardScreen> createState() => _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends State<AdminDashboardScreen> {
  int _days = 7;
  int _seq = 0;
  bool _loading = true;
  AdminOverview? _overview;
  String? _error;
  String? _identity;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final seq = ++_seq;
    final id = IdentityService.instance.userId;
    setState(() { _loading = true; _overview = null; _error = null; _identity = id; });
    try {
      if (!await AdminService.instance.checkAccess()) {
        throw const AdminException('Esta conta não está autorizada a administrar a Gamma.');
      }
      final result = await AdminService.instance.overview(_days);
      if (!mounted || seq != _seq) return;
      if (IdentityService.instance.userId != id) {
        throw const AdminException('A conta foi alterada. Abra o painel novamente.');
      }
      setState(() => _overview = result);
    } catch (error) {
      if (!mounted || seq != _seq) return;
      setState(() => _error = error is AdminException ? error.message : 'Falha ao carregar o painel.');
    } finally {
      if (mounted && seq == _seq) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: context.gama.background,
        appBar: AppBar(
          backgroundColor: context.gama.surface,
          title: const Text('Administração Gamma'),
          actions: [IconButton(
            tooltip: 'Atualizar indicadores',
            onPressed: _loading ? null : _reload,
            icon: const Icon(Icons.refresh_rounded),
          )],
          bottom: const TabBar(tabs: [
            Tab(icon: Icon(Icons.analytics_outlined), text: 'Indicadores'),
            Tab(icon: Icon(Icons.manage_accounts_outlined), text: 'Planos e créditos'),
          ]),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? _InfoState(message: _error!, onRetry: _reload)
                : TabBarView(children: [
                    _OverviewTab(
                      overview: _overview!,
                      days: _days,
                      onDays: (days) { setState(() => _days = days); _reload(); },
                    ),
                    _ManagementTab(key: ValueKey(_identity)),
                  ]),
      ),
    );
  }
}

class _OverviewTab extends StatelessWidget {
  final AdminOverview overview;
  final int days;
  final ValueChanged<int> onDays;
  const _OverviewTab({required this.overview, required this.days, required this.onDays});

  @override
  Widget build(BuildContext context) {
    final g = context.gama;
    final recent = overview.daily.length > 14
        ? overview.daily.sublist(overview.daily.length - 14) : overview.daily;
    final maxCount = recent.fold<int>(0, (max, item) => item.requests > max ? item.requests : max);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
      children: [
        Center(child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 980),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text('Visão geral', style: TextStyle(
                fontSize: 22, color: g.textPrimary, fontWeight: FontWeight.w700))),
              DropdownButton<int>(
                value: days,
                items: const [1, 7, 30].map((n) => DropdownMenuItem(value: n, child: Text('$n dias'))).toList(),
                onChanged: (value) { if (value != null) onDays(value); },
              ),
            ]),
            const SizedBox(height: 14),
            LayoutBuilder(builder: (context, constraints) {
              final width = constraints.maxWidth;
              final cardWidth = width < 600 ? (width - 12) / 2 : (width - 36) / 4;
              return Wrap(spacing: 12, runSpacing: 12, children: [
                _Metric('Usuários ativos', '${overview.users}', Icons.people_outline, cardWidth),
                _Metric('Requisições HTTP', '${overview.requests}', Icons.http, cardWidth),
                _Metric('Chamadas registradas', '${overview.calls}', Icons.smart_toy_outlined, cardWidth),
                _Metric('Custos informados', 'US\$ ${overview.reportedUsd.toStringAsFixed(4)}', Icons.paid_outlined, cardWidth),
              ]);
            }),
            const SizedBox(height: 22),
            _Panel(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Atividade diária', style: TextStyle(color: g.textPrimary, fontSize: 17, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Text('Requisições HTTP recebidas; não representam tarefas concluídas.',
                style: TextStyle(color: g.textMuted, fontSize: 12)),
              const SizedBox(height: 16),
              SizedBox(height: 115, child: recent.isEmpty
                ? Center(child: Text('Nenhuma atividade registrada neste período.', style: TextStyle(color: g.textMuted)))
                : Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    for (final day in recent)
                      Expanded(child: Tooltip(message: '${day.day}: ${day.requests} requisições',
                        child: Padding(padding: const EdgeInsets.symmetric(horizontal: 3),
                          child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                            Text('${day.requests}', style: TextStyle(color: g.textMuted, fontSize: 10)),
                            const SizedBox(height: 4),
                            Container(height: 3 + 75 * (maxCount == 0 ? 0 : day.requests / maxCount),
                              decoration: BoxDecoration(color: g.accent, borderRadius: BorderRadius.circular(4))),
                            const SizedBox(height: 5),
                            Text(day.day.length >= 10 ? day.day.substring(8) : day.day,
                              style: TextStyle(color: g.textMuted, fontSize: 10)),
                          ]))),
                      ),
                  ])),
            ])),
            const SizedBox(height: 16),
            _Panel(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Modelos e custos reportados', style: TextStyle(color: g.textPrimary,
                fontSize: 17, fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              if (overview.models.isEmpty)
                Text('Nenhum custo de modelo registrado.', style: TextStyle(color: g.textMuted))
              else for (final model in overview.models) ...[
                Padding(padding: const EdgeInsets.symmetric(vertical: 7), child: Row(children: [
                  Icon(Icons.memory_outlined, color: g.textSecondary, size: 20),
                  const SizedBox(width: 10),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(model.model, maxLines: 2, overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: g.textPrimary, fontWeight: FontWeight.w600)),
                    Text('${model.category} · ${model.calls} chamadas · ${model.unknownCalls} custos desconhecidos',
                      style: TextStyle(color: g.textMuted, fontSize: 12)),
                  ])),
                  const SizedBox(width: 8),
                  Text('US\$ ${model.reportedUsd.toStringAsFixed(4)}',
                    style: TextStyle(color: g.textPrimary, fontWeight: FontWeight.w600)),
                ])),
                Divider(color: g.borderSoft, height: 1),
              ],
              const SizedBox(height: 8),
              Text('Custos sem informação do provedor: ${overview.unknownCosts}. '
                'Valores exibidos não incluem necessariamente todos os serviços ou despesas da Gamma.',
                style: TextStyle(color: g.textSecondary, fontSize: 12, height: 1.4)),
            ])),
            const SizedBox(height: 16),
            _Panel(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Reservas de mídia', style: TextStyle(color: g.textPrimary,
                fontSize: 17, fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              Text('Imagens: ${overview.mediaReservations['image'] ?? 0} · '
                'Vídeos: ${overview.mediaReservations['video'] ?? 0}',
                style: TextStyle(color: g.textSecondary)),
              const SizedBox(height: 6),
              Text('Reserva não é confirmação de geração concluída nem cobrança. '
                'Assinaturas e pagamentos continuam desativados.',
                style: TextStyle(color: g.textMuted, fontSize: 12)),
            ])),
          ]),
        )),
      ],
    );
  }
}

class _Metric extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final double width;
  const _Metric(this.label, this.value, this.icon, this.width);
  @override
  Widget build(BuildContext context) => SizedBox(width: width, child: _Panel(child: Column(
    crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, color: context.gama.accent),
      const SizedBox(height: 9),
      Text(value, maxLines: 1, overflow: TextOverflow.ellipsis,
        style: TextStyle(color: context.gama.textPrimary, fontSize: 21, fontWeight: FontWeight.w700)),
      const SizedBox(height: 4),
      Text(label, style: TextStyle(color: context.gama.textSecondary, fontSize: 12)),
    ])));
}

class _Panel extends StatelessWidget {
  final Widget child;
  const _Panel({required this.child});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(color: context.gama.surfaceCard,
      border: Border.all(color: context.gama.borderSoft),
      borderRadius: BorderRadius.circular(18)),
    child: child,
  );
}

class _InfoState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _InfoState({required this.message, required this.onRetry});
  @override
  Widget build(BuildContext context) => Center(child: Padding(
    padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.admin_panel_settings_outlined, size: 44),
      const SizedBox(height: 14),
      Text(message, textAlign: TextAlign.center),
      const SizedBox(height: 14),
      OutlinedButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh),
        label: const Text('Tentar novamente')),
    ])));
}

class _ManagementTab extends StatefulWidget {
  const _ManagementTab({super.key});
  @override
  State<_ManagementTab> createState() => _ManagementTabState();
}

class _ManagementTabState extends State<_ManagementTab> {
  final _email = TextEditingController();
  final _days = TextEditingController();
  final _delta = TextEditingController();
  final _reason = TextEditingController(text: 'credito_beta_manual');
  AdminAccount? _account;
  String? _loadedEmail;
  String _plan = 'pro';
  bool _busy = false;
  String? _message;
  // Após timeout, repetir a mesma ação reutiliza o ID (idempotência no backend).
  String? _pendingFingerprint;
  String? _pendingId;

  @override
  void dispose() {
    _email.dispose(); _days.dispose(); _delta.dispose(); _reason.dispose();
    super.dispose();
  }

  String get _normalizedEmail => _email.text.trim().toLowerCase();
  bool get _validEmail => RegExp(r'^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$')
      .hasMatch(_normalizedEmail) && !_normalizedEmail.contains('..') && _normalizedEmail.length <= 120;
  bool get _sameAccount => _account != null && _loadedEmail == _normalizedEmail;

  Future<void> _lookup() async {
    if (_busy || !_validEmail) return;
    setState(() { _busy = true; _account = null; _loadedEmail = null; _message = null; });
    try {
      final result = await AdminService.instance.findAccount(_normalizedEmail);
      if (!mounted) return;
      setState(() { _account = result; _loadedEmail = _normalizedEmail; });
    } catch (error) {
      if (mounted) setState(() => _message = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _idFor(String fingerprint) {
    if (_pendingFingerprint == fingerprint && _pendingId != null) return _pendingId!;
    _pendingFingerprint = fingerprint;
    _pendingId = const Uuid().v4();
    return _pendingId!;
  }

  Future<void> _submit({required bool credit}) async {
    if (_busy || !_sameAccount) return;
    final email = _normalizedEmail;
    final days = _days.text.trim().isEmpty ? null : int.tryParse(_days.text.trim());
    final delta = int.tryParse(_delta.text.trim());
    final reason = _reason.text.trim();
    if (!credit && _days.text.trim().isNotEmpty &&
        (days == null || days < 1 || days > 365 || _plan == 'free')) {
      setState(() => _message = 'Validade: informe de 1 a 365 dias para Pro/Creator, ou deixe vazio.');
      return;
    }
    if (credit && (delta == null || delta == 0 || delta.abs() > 100000 ||
        reason.length < 3 || reason.length > 100)) {
      setState(() => _message = 'Informe ajuste inteiro não zero (até 100000) e motivo de 3 a 100 caracteres.');
      return;
    }
    final action = credit ? 'créditos $delta (motivo: $reason)' :
        'plano $_plan${days == null ? ' sem prazo' : ' por $days dias'}';
    final confirmed = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: const Text('Confirmar alteração comercial'),
      content: Text('Conta: $email\nOperação: $action\n\n'
          'Esta operação altera os dados beta da conta. '
          'Não há cobrança real. Confirme apenas se o e-mail estiver correto.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Confirmar')),
      ],
    ));
    if (!mounted || confirmed != true) return;
    final fingerprint = '$email|${credit ? 'credit' : 'plan'}|$action';
    final requestId = _idFor(fingerprint);
    setState(() { _busy = true; _message = null; });
    try {
      if (credit) {
        await AdminService.instance.adjustCredits(
          email: email, delta: delta!, reason: reason, requestId: requestId);
      } else {
        await AdminService.instance.assignPlan(
          email: email, plan: _plan, days: days, requestId: requestId);
      }
      // A alteração foi confirmada pelo servidor: não permitir novo débito
      // só porque a consulta de atualização possa falhar.
      _pendingFingerprint = null;
      _pendingId = null;
      try {
        final result = await AdminService.instance.findAccount(email);
        if (!mounted) return;
        setState(() { _account = result; _message = 'Alteração aplicada e dados atualizados.'; });
      } catch (_) {
        if (!mounted) return;
        setState(() => _message = 'Alteração confirmada pelo servidor, mas a consulta '
            'de atualização falhou. Use Consultar conta para atualizar o saldo. '
            'Não repita a alteração.');
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _message = '$error\nSe a conexão falhou após confirmar, '
          'tente novamente com os mesmos dados nesta tela: o ID será reutilizado.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final g = context.gama;
    return ListView(padding: const EdgeInsets.fromLTRB(16, 20, 16, 40), children: [
      Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 680),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Gerenciar benefícios beta', style: TextStyle(
            color: g.textPrimary, fontSize: 21, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Text('Informe o e-mail Google exato. Não existe listagem de usuários neste painel. '
            'A consulta não comprova que essa conta já se cadastrou.',
            style: TextStyle(color: g.textSecondary, height: 1.4)),
          const SizedBox(height: 18),
          _Panel(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TextField(controller: _email,
              enabled: !_busy,
              keyboardType: TextInputType.emailAddress,
              textCapitalization: TextCapitalization.none,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'E-mail Google do cliente',
                prefixIcon: Icon(Icons.alternate_email), hintText: 'cliente@example.com'),
              onChanged: (_) => setState(() { _account = null; _loadedEmail = null; _message = null; }),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(onPressed: _busy || !_validEmail ? null : _lookup,
              icon: const Icon(Icons.person_search_outlined), label: const Text('Consultar conta')),
            if (_account != null && _sameAccount) ...[
              const SizedBox(height: 12),
              Text('Plano: ${_account!.plan} · Créditos: ${_account!.balance}',
                style: TextStyle(color: g.textPrimary, fontWeight: FontWeight.w600)),
              if (_account!.expiresAt != null)
                Text('Expira: ${_account!.expiresAt}', style: TextStyle(color: g.textSecondary, fontSize: 12)),
            ],
          ])),
          const SizedBox(height: 14),
          _Panel(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Atribuir plano', style: TextStyle(color: g.textPrimary, fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              value: _plan,
              decoration: const InputDecoration(labelText: 'Plano beta'),
              items: const [
                DropdownMenuItem(value: 'free', child: Text('Free')),
                DropdownMenuItem(value: 'pro', child: Text('Pro')),
                DropdownMenuItem(value: 'creator', child: Text('Creator')),
              ],
              onChanged: _busy ? null : (value) { if (value != null) setState(() => _plan = value); },
            ),
            const SizedBox(height: 10),
            TextField(controller: _days, enabled: !_busy,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Duração em dias (opcional)',
                hintText: 'Ex.: 30'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(onPressed: _busy || !_sameAccount ? null : () => _submit(credit: false),
              icon: const Icon(Icons.workspace_premium_outlined), label: const Text('Aplicar plano')),
          ])),
          const SizedBox(height: 14),
          _Panel(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Ajustar créditos de teste', style: TextStyle(color: g.textPrimary,
              fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            TextField(controller: _delta, enabled: !_busy,
              keyboardType: const TextInputType.numberWithOptions(signed: true),
              decoration: const InputDecoration(labelText: 'Quantidade (negativo para retirar)', hintText: 'Ex.: 10'),
            ),
            const SizedBox(height: 10),
            TextField(controller: _reason, enabled: !_busy,
              decoration: const InputDecoration(labelText: 'Motivo do ajuste'),
              maxLength: 100,
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(onPressed: _busy || !_sameAccount ? null : () => _submit(credit: true),
              icon: const Icon(Icons.toll_outlined), label: const Text('Aplicar ajuste')),
          ])),
          if (_busy) const Padding(padding: EdgeInsets.all(18),
            child: Center(child: CircularProgressIndicator())),
          if (_message != null) Padding(padding: const EdgeInsets.only(top: 12),
            child: Text(_message!, style: TextStyle(color: g.textSecondary, height: 1.4))),
          const SizedBox(height: 18),
          Text('Não há pagamentos reais nesta fase. Operações são registradas '
            'com identificadores únicos no servidor para prevenir duplicidades.',
            style: TextStyle(color: g.textMuted, fontSize: 12)),
        ]),
      )),
    ]);
  }
}
