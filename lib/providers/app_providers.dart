import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/rcheevos_bindings.dart';
import '../services/cover_art_service.dart';
import '../services/emulator_service.dart';
import '../services/game_database.dart';
import '../services/game_library_service.dart';
import '../services/link_cable_service.dart';
import '../services/ra_runtime_service.dart';
import '../services/remove_ads_purchase_service.dart';
import '../services/rcheevos_client.dart';
import '../services/retro_achievements_service.dart';
import '../services/settings_service.dart';

class AppProviders extends StatelessWidget {
  final GameDatabase gameDatabase;
  final Widget child;

  const AppProviders({
    super.key,
    required this.gameDatabase,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<GameDatabase>.value(value: gameDatabase),
        ChangeNotifierProvider<RemoveAdsPurchaseService>.value(
          value: RemoveAdsPurchaseService.instance,
        ),
        ChangeNotifierProvider(create: (_) => SettingsService()..load()),
        ChangeNotifierProvider(
          create: (_) => GameLibraryService(gameDatabase)..initialize(),
        ),
        ChangeNotifierProvider(create: (_) => EmulatorService()),
        ChangeNotifierProvider(create: (_) => CoverArtService()),
        ChangeNotifierProvider(create: (_) => LinkCableService()),
        ChangeNotifierProvider(
          create: (_) => RetroAchievementsService()..initialize(),
        ),
        ChangeNotifierProvider(create: (_) => RARuntimeService()),
        ChangeNotifierProvider(
          create: (_) {
            final bindings =
                RcheevosBindings(); 
            return RcheevosClient(bindings);
          },
        ),
      ],
      child: child,
    );
  }
}
