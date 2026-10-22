import 'dart:ui';

/// Lectura de un sensor MQ (gas) expresada como porcentaje 0-100.
class GasReading {
  final String key; // mq2
  final String name;
  final String type;
  double value;
  final double limit;

  GasReading({
    required this.key,
    required this.name,
    required this.type,
    required this.value,
    this.limit = 35,
  });

  bool get isWarn => value > limit;
}

/// Posición guardada del brazo pan/tilt (0-100%, ver `AppState.armPresets`).
class ArmPreset {
  final int pan;
  final int tilt;
  const ArmPreset({required this.pan, required this.tilt});
}

class AlertEvent {
  final DateTime time;
  final String text;
  final Color level; // usar AppColors.green/yellow/red
  final String category; // sistema | sensores | red

  AlertEvent({
    required this.time,
    required this.text,
    required this.level,
    required this.category,
  });

  String get timeLabel =>
      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:${time.second.toString().padLeft(2, '0')}';
}
