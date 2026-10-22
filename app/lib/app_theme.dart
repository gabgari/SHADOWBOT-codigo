import 'package:flutter/material.dart';

/// Identidad SHADOW BOT — ver `firmware/ESTILO/COLORES.jpg`.
///
/// "Oscuridad. Precisión. Control." Software de navegación de ROV terrestre:
/// 85-90% negro/carbón/grafito, 8-12% blanco y gris metálico, 1-3% de gris
/// azulado (entre índigo grisáceo y azul marino militar) como único acento.
/// Nada de colores vivos: el verde apagado marca "en línea / OK", y el ámbar
/// y el rojo (apagados) solo aparecen para advertencias y para
/// detener/emergencia — así el acento azulado no se come los colores de
/// estado.
///
/// Los nombres viejos (`orange`, `military`, `olive`…) se conservan porque
/// todas las pantallas los usan; ahora apuntan a la paleta azulada.
class AppColors {
  AppColors._();

  // ---- Paleta principal (grises con un toque frío) ----
  static const ink = Color(0xFF050608); // fondo absoluto · negro tinta
  static const bg = Color(0xFF0A0C0F); // fondo principal · negro carbón
  static const bgAlt = Color(0xFF07080A);
  static const surface1 = Color(0xFF111419); // superficie · grafito profundo
  static const surface2 = Color(0xFF171B21); // superficie elevada · grafito
  static const surface3 = Color(0xFF272D36); // bordes · gris acero
  static const line = Color(0xFF272D36);
  static const lineSoft = Color(0xFF1B2028);

  static const text1 = Color(0xFFE4E6EA); // texto principal · blanco humo
  static const text2 = Color(0xFF868C99); // texto secundario · gris acero
  static const text3 = Color(0xFF4F5562); // texto tenue · gris oscuro

  static const military = Color(0xFF4E5A7A); // gris índigo militar · acento principal
  static const olive = Color(0xFF93A1C6); // gris azulado claro · brillo / activo (iconos legibles)
  static const militaryDark = Color(0xFF242C42); // azul marino militar · estados / fondo

  // ---- Alias usados en toda la app ----
  static const orange = olive; // "activo / en línea / seleccionado"
  static const orangeDim = Color(0x2E4E5A7A);
  static const orangeDim2 = Color(0x554E5A7A);
  static const onAccent = ink;
  static const green = Color(0xFF7FA57A); // OK / en línea (verde apagado, solo estado)

  static const yellow = Color(0xFFB59A55); // advertencia (ámbar apagado)
  static const red = Color(0xFFB4534B); // detener / emergencia / error
}

class AppRadius {
  AppRadius._();
  static const lg = 10.0; // paneles
  static const md = 8.0; // botones
  static const sm = 6.0; // controles chicos / inputs
}

class AppFonts {
  AppFonts._();
  static const sans = 'Montserrat';
  static const mono = 'JetBrainsMono';
}

class AppText {
  AppText._();

  static const display = TextStyle(fontWeight: FontWeight.w800, color: AppColors.text1);
  static const body = TextStyle(fontWeight: FontWeight.w400, color: AppColors.text1);
  static const mono = TextStyle(fontFamily: AppFonts.mono, color: AppColors.text1);

  static const heroTitle = TextStyle(
    fontSize: 28,
    fontWeight: FontWeight.w700,
    letterSpacing: 6,
    color: AppColors.text1,
  );

  /// Título de panel estilo HUD: mayúsculas, mono, espaciado.
  static const sectionTitle = TextStyle(
    fontFamily: AppFonts.mono,
    fontSize: 11,
    fontWeight: FontWeight.w500,
    color: AppColors.text2,
    letterSpacing: 1.6,
  );

  static const topbarTitle = TextStyle(
    fontFamily: AppFonts.mono,
    fontSize: 14,
    fontWeight: FontWeight.w500,
    color: AppColors.text1,
    letterSpacing: 1.6,
  );

  /// Etiqueta chica de dato (GAS, RSSI…).
  static const label = TextStyle(
    fontFamily: AppFonts.mono,
    fontSize: 9.5,
    fontWeight: FontWeight.w500,
    color: AppColors.text2,
    letterSpacing: 1.2,
  );

  /// Valor de telemetría.
  static const value = TextStyle(
    fontFamily: AppFonts.mono,
    fontSize: 15,
    fontWeight: FontWeight.w500,
    color: AppColors.text1,
  );
}

/// Escala de la interfaz según el tamaño de pantalla: 1.0 en un teléfono
/// acostado (~360-420 dp de alto) y hasta ~1.5 en tablets. Todo lo que mide
/// la consola (anchos de columna, joysticks, márgenes) se multiplica por
/// `context.u`; el texto se escala solo (ver `buildAppTheme` / main.dart).
extension HudScale on BuildContext {
  double get u => hudScaleFor(MediaQuery.sizeOf(this));
}

double hudScaleFor(Size size) => (size.shortestSide / 390).clamp(0.9, 1.5);

ThemeData buildAppTheme() {
  final base = ThemeData(brightness: Brightness.dark, fontFamily: AppFonts.sans);
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    fontFamily: AppFonts.sans,
    scaffoldBackgroundColor: AppColors.bg,
    textTheme: base.textTheme.apply(bodyColor: AppColors.text1, displayColor: AppColors.text1, fontFamily: AppFonts.sans),
    colorScheme: const ColorScheme.dark(
      primary: AppColors.olive,
      onPrimary: AppColors.ink,
      secondary: AppColors.military,
      surface: AppColors.surface1,
      onSurface: AppColors.text1,
      error: AppColors.red,
      outline: AppColors.line,
    ),
    sliderTheme: const SliderThemeData(
      activeTrackColor: AppColors.olive,
      inactiveTrackColor: AppColors.surface3,
      thumbColor: AppColors.text1,
      overlayColor: AppColors.orangeDim,
      trackHeight: 3,
      thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? AppColors.olive : AppColors.text3),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? AppColors.militaryDark : AppColors.surface2),
      trackOutlineColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? AppColors.military : AppColors.line),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? AppColors.militaryDark : AppColors.surface1),
        foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? AppColors.text1 : AppColors.text2),
        side: const WidgetStatePropertyAll(BorderSide(color: AppColors.line)),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.sm))),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: AppColors.surface1,
      selectedColor: AppColors.militaryDark,
      side: const BorderSide(color: AppColors.line),
      labelStyle: const TextStyle(color: AppColors.text1, fontFamily: AppFonts.mono),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.sm)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.ink,
      labelStyle: const TextStyle(color: AppColors.text2),
      hintStyle: const TextStyle(color: AppColors.text3),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        borderSide: const BorderSide(color: AppColors.line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        borderSide: const BorderSide(color: AppColors.military),
      ),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.sm)),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.militaryDark,
        foregroundColor: AppColors.text1,
        elevation: 0,
        side: const BorderSide(color: AppColors.military),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
        textStyle: const TextStyle(fontFamily: AppFonts.mono, fontWeight: FontWeight.w500, letterSpacing: 1.2),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.text1,
        side: const BorderSide(color: AppColors.line),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(foregroundColor: AppColors.olive)),
    dialogTheme: DialogThemeData(
      backgroundColor: AppColors.surface1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.lg), side: const BorderSide(color: AppColors.line)),
    ),
    drawerTheme: const DrawerThemeData(backgroundColor: AppColors.ink),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: AppColors.olive),
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    dividerColor: AppColors.lineSoft,
    iconTheme: const IconThemeData(color: AppColors.text2),
  );
}
