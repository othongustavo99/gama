import 'package:flutter/material.dart';

import '../core/gama_colors.dart';

class ScheduledScreen extends StatelessWidget {
  const ScheduledScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: GamaColors.background,
      appBar: AppBar(
        backgroundColor: GamaColors.surface,
        title: const Text('Agendado'),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: GamaColors.accentSoft,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(
                  Icons.schedule_rounded,
                  color: GamaColors.accent,
                  size: 32,
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                'Lembretes e tarefas agendadas',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: GamaColors.textPrimary,
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                'Em breve você poderá pedir à Gamma para lembrar de algo '
                'em um horário e ver tudo listado aqui.',
                textAlign: TextAlign.center,
                style: TextStyle(color: GamaColors.textMuted, height: 1.4),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
