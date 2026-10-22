import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../utils/error_logger.dart';

/// Agendamento local dos lembretes salvos na tela Agendado.
/// As notificações não dependem do backend nem de o PC estar ligado.
class LocalNotificationService {
  LocalNotificationService._();
  static final LocalNotificationService instance = LocalNotificationService._();

  static const String remindersKey = 'gama_local_reminders';
  static const String channelId = 'gama_reminders';
  static const String channelName = 'Lembretes da Gama';

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized || kIsWeb) return;
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const darwin = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: android,
        iOS: darwin,
        macOS: darwin,
      ),
    );

    tzdata.initializeTimeZones();
    try {
      final zone = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(zone.identifier));
    } catch (error, stack) {
      logSwallowed(error, stack);
      // Fallback UTC: o agendamento continua válido caso o SO não exponha
      // o identificador de fuso por algum motivo.
      tz.setLocalLocation(tz.getLocation('UTC'));
    }
    _initialized = true;
  }

  Future<bool> requestPermission() async {
    await initialize();
    if (kIsWeb) return false;
    try {
      if (Platform.isAndroid) {
        final android = _plugin
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >();
        final notificationAllowed =
            await android?.requestNotificationsPermission() ?? true;
        if (!notificationAllowed) return false;
        return true;
      }
      if (Platform.isIOS) {
        final ios = _plugin
            .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin
            >();
        return await ios?.requestPermissions(
              alert: true,
              badge: true,
              sound: true,
            ) ??
            true;
      }
      if (Platform.isMacOS) {
        final macos = _plugin
            .resolvePlatformSpecificImplementation<
              MacOSFlutterLocalNotificationsPlugin
            >();
        return await macos?.requestPermissions(
              alert: true,
              badge: true,
              sound: true,
            ) ??
            true;
      }
      return true;
    } catch (error, stack) {
      logSwallowed(error, stack);
      return false;
    }
  }

  int _notificationId(String id) {
    // FNV-1a determinístico, ao contrário de String.hashCode, que não é
    // uma garantia persistente entre execuções.
    var hash = 0x811c9dc5;
    for (final byte in utf8.encode(id)) {
      hash ^= byte;
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
    return hash == 0 ? 1 : hash;
  }

  Future<void> schedule({
    required String id,
    required String text,
    required DateTime when,
  }) async {
    if (when.isBefore(DateTime.now().add(const Duration(seconds: 5)))) {
      throw ArgumentError('O horário do lembrete precisa estar no futuro.');
    }
    await initialize();
    final allowed = await requestPermission();
    if (!allowed) throw StateError('Permissão de notificações não concedida.');

    await _plugin.zonedSchedule(
      id: _notificationId(id),
      title: 'Lembrete da Gama',
      body: text,
      scheduledDate: tz.TZDateTime.from(when, tz.local),
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          channelName,
          channelDescription: 'Notificações dos lembretes locais da Gama',
          importance: Importance.high,
          priority: Priority.high,
          icon: '@mipmap/ic_launcher',
        ),
        iOS: DarwinNotificationDetails(),
      ),
      androidScheduleMode: await _androidScheduleMode(requestExact: true),
      payload: id,
    );
  }

  Future<AndroidScheduleMode> _androidScheduleMode({
    required bool requestExact,
  }) async {
    if (!kIsWeb && Platform.isAndroid) {
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      var allowed = await android?.canScheduleExactNotifications() ?? false;
      if (!allowed && requestExact) {
        await android?.requestExactAlarmsPermission();
        allowed = await android?.canScheduleExactNotifications() ?? false;
      }
      return allowed
          ? AndroidScheduleMode.exactAllowWhileIdle
          : AndroidScheduleMode.inexactAllowWhileIdle;
    }
    return AndroidScheduleMode.inexactAllowWhileIdle;
  }

  Future<void> cancel(String id) async {
    if (kIsWeb) return;
    await initialize();
    await _plugin.cancel(id: _notificationId(id));
  }

  Future<void> syncSavedReminders({required bool enabled}) async {
    if (kIsWeb) return;
    await initialize();
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(remindersKey);
    final List<dynamic> reminders;
    try {
      reminders = raw == null ? <dynamic>[] : jsonDecode(raw) as List<dynamic>;
    } catch (error, stack) {
      logSwallowed(error, stack);
      return;
    }

    if (!enabled) {
      // Cancela apenas lembretes da Gama; não apaga futuras notificações de
      // outros recursos que possam usar o mesmo plugin no futuro.
      final reminderIds = <int>{};
      for (final item in reminders.whereType<Map>()) {
        final id = item['id']?.toString() ?? '';
        if (id.isNotEmpty) reminderIds.add(_notificationId(id));
      }
      final pending = await _plugin.pendingNotificationRequests();
      for (final notification in pending) {
        if (reminderIds.contains(notification.id)) {
          await _plugin.cancel(id: notification.id);
        }
      }
      return;
    }

    final liveIds = <int>{};
    for (final item in reminders.whereType<Map>()) {
      final reminder = Map<String, dynamic>.from(item);
      final id = reminder['id']?.toString() ?? '';
      final text = reminder['text']?.toString().trim() ?? '';
      final when = DateTime.tryParse(reminder['when']?.toString() ?? '');
      final done = reminder['done'] == true;
      if (id.isEmpty ||
          text.isEmpty ||
          when == null ||
          done ||
          !when.isAfter(DateTime.now())) {
        continue;
      }
      liveIds.add(_notificationId(id));
      try {
        // syncSavedReminders é executado ao abrir a tela e após mudanças de
        // configuração; a permissão já concedida não gera novo diálogo.
        await _plugin.zonedSchedule(
          id: _notificationId(id),
          title: 'Lembrete da Gama',
          body: text,
          scheduledDate: tz.TZDateTime.from(when, tz.local),
          notificationDetails: const NotificationDetails(
            android: AndroidNotificationDetails(
              channelId,
              channelName,
              channelDescription: 'Notificações dos lembretes locais da Gama',
              importance: Importance.high,
              priority: Priority.high,
              icon: '@mipmap/ic_launcher',
            ),
            iOS: DarwinNotificationDetails(),
          ),
          androidScheduleMode: await _androidScheduleMode(requestExact: false),
          payload: id,
        );
      } catch (error) {
        debugPrint('Não foi possível reagendar o lembrete local: $error');
      }
    }

    // Remove notificações de lembretes apagados/concluídos sem cancelar
    // lembretes futuros que continuaram na lista.
    final pending = await _plugin.pendingNotificationRequests();
    for (final notification in pending) {
      if (!liveIds.contains(notification.id)) {
        await _plugin.cancel(id: notification.id);
      }
    }
  }
}
