import 'dart:io';

import 'package:flutter/material.dart';
import '../widgets/gama_floating_page.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/gama_colors.dart';
import '../services/play_billing_service.dart';

/// Preços são sempre os apresentados pela Google Play para o usuário.
class PlaySubscriptionScreen extends StatefulWidget {
  const PlaySubscriptionScreen({super.key});

  @override
  State<PlaySubscriptionScreen> createState() => _PlaySubscriptionScreenState();
}

class _PlaySubscriptionScreenState extends State<PlaySubscriptionScreen> {
  final GammaPlayBillingService billing = GammaPlayBillingService.instance;

  @override
  void initState() {
    super.initState();
    billing.addListener(_updated);
    if (Platform.isAndroid) billing.loadCatalog();
  }

  void _updated() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    billing.removeListener(_updated);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.gama.background,
      
      body: GamaFloatingPage(
        actions: [
        IconButton(
          tooltip: 'Atualizar produtos',
          onPressed: billing.loading ? null : billing.loadCatalog,
          icon: const Icon(Icons.refresh_rounded),
        ),
      ],
        child: Center(child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 700),
        child: ListView(padding: const EdgeInsets.all(20), children: [
          Text('Escolha seu plano', style: TextStyle(
              color: context.gama.textPrimary, fontSize: 24, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Text('Os valores e as condições mostrados abaixo são fornecidos pela Google Play.',
            style: TextStyle(color: context.gama.textSecondary)),
          const SizedBox(height: 20),
          if (!billing.supported) const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('Assinaturas no aplicativo disponíveis somente no Android.'),
          ) else if (billing.loading) const Center(child: CircularProgressIndicator())
          else if (!billing.checkoutAvailable)
            Card(child: Padding(padding: const EdgeInsets.all(18), child: Text(
              billing.error ?? billing.notice ?? 'Assinaturas ainda não estão disponíveis.',
            )))
          else ...[
            for (final ProductDetails product in billing.products)
              Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Gamma ${billing.planFor(product.id)}',
                    style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 8),
                  Text(product.description.isEmpty ? product.title : product.description),
                  const SizedBox(height: 12),
                  Text(product.price, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: billing.purchasePending ? null : () => billing.purchase(product),
                    child: const Text('Continuar na Google Play'),
                  ),
                ],
              ))),
          ],
          if (billing.purchasePending) const Padding(
            padding: EdgeInsets.only(top: 14),
            child: ListTile(leading: CircularProgressIndicator(),
              title: Text('Aguardando confirmação da compra...')),
          ),
          if (billing.error != null && billing.checkoutAvailable) Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Text(billing.error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
          if (billing.notice != null && billing.checkoutAvailable) Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(billing.notice!),
          ),
          const SizedBox(height: 22),
          OutlinedButton.icon(
            icon: const Icon(Icons.restore),
            label: const Text('Restaurar compras'),
            onPressed: billing.checkoutAvailable && !billing.loading ? billing.restore : null,
          ),
          TextButton.icon(
            icon: const Icon(Icons.open_in_new),
            label: const Text('Gerenciar ou cancelar na Google Play'),
            onPressed: billing.supported ? () => launchUrl(
              Uri.parse('https://play.google.com/store/account/subscriptions'),
              mode: LaunchMode.externalApplication,
            ) : null,
          ),
          const SizedBox(height: 12),
          Text('A assinatura não é habilitada até a verificação no servidor. '
            'Pagamentos pendentes não liberam recursos. Para conferir seus benefícios, '
            'volte à tela Meu plano e consumo e atualize os dados.',
            style: TextStyle(color: context.gama.textSecondary, fontSize: 12)),
        ]),
      ))
      ),
    );
  }
}
