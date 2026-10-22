import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:provider/provider.dart';

import 'app_theme.dart';
import 'services/vision_service.dart';
import 'screens/camera_fullscreen_screen.dart';
import 'screens/root_shell.dart';
import 'screens/splash_screen.dart';
import 'services/device_config.dart';
import 'state/app_state.dart';
import 'state/assistant_state.dart';
import 'state/auto_route.dart';
import 'state/bot_link.dart';
import 'state/gamepad_link.dart';

void main() {
  // Registra el backend nativo (libmpv) que usa `TapoCamService` para el
  // stream RTSP de la Tapo C110 — sin esto, `Player()` explota al crearse.
  MediaKit.ensureInitialized();
  WidgetsFlutterBinding.ensureInitialized();
  // Consola de ROV: siempre horizontal (teléfono o tablet) y a pantalla
  // completa, sin barras del sistema (reaparecen deslizando del borde).
  SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const ShadowBotApp());
}

class ShadowBotApp extends StatefulWidget {
  const ShadowBotApp({super.key});

  @override
  State<ShadowBotApp> createState() => _ShadowBotAppState();
}

class _ShadowBotAppState extends State<ShadowBotApp> {
  late final DeviceConfig _deviceConfig;
  late final AppState _appState;
  late final AssistantState _assistantState;
  late final BotLink _botLink;
  late final GamepadLink _gamepad;
  late final AutoRoute _autoRoute;
  final _messenger = GlobalKey<ScaffoldMessengerState>();
  StreamSubscription<VisionNotice>? _visionSub;

  @override
  void initState() {
    super.initState();
    _deviceConfig = DeviceConfig();
    _appState = AppState(deviceConfig: _deviceConfig);
    _assistantState = AssistantState(appState: _appState);
    _deviceConfig.load();
    _appState.start();
    _botLink = BotLink(appState: _appState)..start();
    // Modo autónomo de EXPLORACIÓN: trazar ruta / regreso inteligente.
    _autoRoute = AutoRoute(botLink: _botLink);
    // Mando de PS4 conectado al teléfono (extra; ver GamepadLink).
    _gamepad = GamepadLink(appState: _appState, botLink: _botLink, assistant: _assistantState, autoRoute: _autoRoute, navigatorKey: _navKey)..start();
    _visionSub = _appState.vision.notices.listen(_onVisionNotice);
    _openPreview();
  }

  /// Avisos de la PC de visión: PC caída (SnackBar), persona / fisura /
  /// óxido (SnackBar discreto) o FUEGO (SnackBar rojo + vibración del
  /// teléfono y del mando + alerta en Alertas).
  void _onVisionNotice(VisionNotice n) {
    if (n.alarm) {
      _appState.addAlert(AppColors.red, n.text, category: 'sensores');
      HapticFeedback.vibrate();
      Future.delayed(const Duration(milliseconds: 350), HapticFeedback.vibrate);
      Future.delayed(const Duration(milliseconds: 700), HapticFeedback.vibrate);
      _gamepad.rumble(600, 255);
    } else if (!n.soft) {
      _appState.addAlert(AppColors.yellow, n.text, category: 'sistema');
    }
    // Persona / fisura / óxido: aviso discreto (solo el SnackBar, sin vibrar).
    _messenger.currentState
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(n.alarm ? '🔥 ${n.text}' : n.text,
            style: TextStyle(fontFamily: AppFonts.mono, fontWeight: FontWeight.w700, color: n.alarm ? Colors.white : AppColors.text1)),
        backgroundColor: n.alarm ? const Color(0xFFB4231B) : AppColors.surface2,
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: n.alarm ? 5 : (n.soft ? 3 : 4)),
      ));
  }

  // Solo para revisar el diseño sin tocar la pantalla (capturas en
  // desarrollo, versión web): ?preview=<sección> o ?preview=fullscreen.
  final _navKey = GlobalKey<NavigatorState>();
  bool _showSplash = true;
  void _openPreview() {
    final preview = kIsWeb ? Uri.base.queryParameters['preview'] ?? '' : '';
    if (preview.isEmpty) return;
    _showSplash = false;
    if (preview == 'fullscreen') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = _navKey.currentContext;
        if (ctx != null) openCameraFullscreen(ctx, AiCameraSource.esp32cam);
      });
    } else {
      _appState.showScreen(preview);
    }
  }

  @override
  void dispose() {
    _visionSub?.cancel();
    _gamepad.dispose();
    _autoRoute.dispose();
    _botLink.dispose();
    _assistantState.dispose();
    _appState.dispose();
    _deviceConfig.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: _deviceConfig),
        ChangeNotifierProvider.value(value: _appState),
        ChangeNotifierProvider.value(value: _appState.tapoCamService),
        ChangeNotifierProvider.value(value: _appState.media),
        ChangeNotifierProvider.value(value: _assistantState),
        ChangeNotifierProvider.value(value: _botLink),
        ChangeNotifierProvider.value(value: _gamepad),
        ChangeNotifierProvider.value(value: _autoRoute),
      ],
      child: MaterialApp(
        navigatorKey: _navKey,
        scaffoldMessengerKey: _messenger,
        title: 'SHADOWBOT',
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(),
        // En tablets todo el texto crece junto con la consola (ver HudScale).
        builder: (context, child) {
          final mq = MediaQuery.of(context);
          final scale = hudScaleFor(mq.size);
          return MediaQuery(
            data: mq.copyWith(textScaler: TextScaler.linear(mq.textScaler.scale(1) * (scale > 1 ? 1 + (scale - 1) * 0.55 : 1))),
            // Arranque: el logo entre humo negro, encima de la consola que
            // ya va cargando debajo (ver SmokeSplash).
            child: Stack(
              children: [
                child!,
                if (_showSplash) Positioned.fill(child: SmokeSplash(onDone: () => setState(() => _showSplash = false))),
              ],
            ),
          );
        },
        home: const RootShell(),
      ),
    );
  }
}
