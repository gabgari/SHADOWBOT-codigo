// Smoke test: la app arranca en la consola de NAVEGACIÓN.
//
// Nota: necesita el backend nativo de media_kit (libmpv); en `flutter test`
// sin él, crear el reproductor de la Tapo lanza una excepción.

import 'package:flutter_test/flutter_test.dart';

import 'package:inspect_bot_app/main.dart';

void main() {
  testWidgets('SHADOW BOT arranca en la consola de navegación', (WidgetTester tester) async {
    await tester.pumpWidget(const ShadowBotApp());
    await tester.pump();

    expect(find.text('SHADOW BOT'), findsOneWidget);
    expect(find.text('NAVEGACIÓN'), findsOneWidget);
  });
}
