import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';

import '../utils/error_logger.dart';

class LocationService {
  LocationService._();

  static final LocationService instance = LocationService._();

  final Geocoding _geocoding = Geocoding();

  /// Obtém uma localidade aproximada somente após uma solicitação que dependa
  /// da localização. Não inicia rastreamento contínuo nem salva a posição.
  Future<String?> currentLocationContext() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever ||
          permission == LocationPermission.unableToDetermine) {
        return null;
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.low,
          timeLimit: Duration(seconds: 12),
        ),
      );

      try {
        final placemarks = await _geocoding.placemarkFromCoordinates(
          position.latitude,
          position.longitude,
        );
        if (placemarks.isNotEmpty) {
          final place = placemarks.first;
          final parts = <String>{};
          for (final value in [
            place.locality,
            place.subAdministrativeArea,
            place.administrativeArea,
            place.country,
          ]) {
            final cleaned = value?.trim();
            if (cleaned != null && cleaned.isNotEmpty) parts.add(cleaned);
          }
          if (parts.isNotEmpty) return parts.join(', ');
        }
      } catch (error, stack) {
        logSwallowed(error, stack);
        // Usa coordenadas arredondadas se a geocodificação não estiver disponível.
      }

      return 'coordenadas aproximadas ${position.latitude.toStringAsFixed(2)}, '
          '${position.longitude.toStringAsFixed(2)}';
    } catch (error, stack) {
      logSwallowed(error, stack);
      // Permissão negada, GPS desligado ou falha não bloqueia o chat.
      return null;
    }
  }
}
