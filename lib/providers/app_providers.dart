import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/rcheevos_bindings.dart';
import '../services/bios_service.dart';
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
import '../utils/tv_detector.dart';

/// Provider setup for the application.
///
/// [gameDatabase] must be opened before this widget is built (see main.dart).
class AppProviders extends StatelessWidget {
  final GameDatabase gameDatabase;
  final Widget child;
  final bool deferStartupLoads;

  const AppProviders({
    super.key,
    required this.gameDatabase,
    required this.child,
    this.deferStartupLoads = false,
  });

  void _runAfterTvLaunch(String label, Future<void> Function() task) {
    unawaited(
      Future<void>.delayed(const Duration(seconds: 2), () async {
        try {
          await task();
        } catch (e) {
          debugPrint('AppProviders: deferred $label failed — $e');
        }
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        // Expose the opened database so services like CheatSession can
        // persist data without going through GameLibraryService.
        Provider<GameDatabase>.value(value: gameDatabase),
        ChangeNotifierProvider<RemoveAdsPurchaseService>.value(
          value: RemoveAdsPurchaseService.instance,
        ),
        ChangeNotifierProvider(
          create: (_) {
            final service = SettingsService();
            if (deferStartupLoads) {
              _runAfterTvLaunch('settings load', service.load);
            } else {
              unawaited(service.load());
            }
            return service;
          },
        ),
        // BiosService owns the libretro system directory; both EmulatorService
        // and the BIOS settings tab observe it for live status updates.
        ChangeNotifierProvider(
          create: (_) {
            final service = BiosService();
            if (!TvDetector.isTV) {
              unawaited(service.deployOpenBiosFallback());
            }
            return service;
          },
        ),
        ChangeNotifierProvider(
          create: (_) {
            final service = GameLibraryService(gameDatabase);
            if (deferStartupLoads) {
              _runAfterTvLaunch('library load', service.initialize);
            } else {
              unawaited(service.initialize());
            }
            return service;
          },
        ),
        ChangeNotifierProvider(create: (_) => EmulatorService()),
        ChangeNotifierProvider(create: (_) => CoverArtService()),
        ChangeNotifierProvider(create: (_) => LinkCableService()),
        // RA service initialization is deferred - it loads credentials async
        ChangeNotifierProvider(
          create: (_) {
            final service = RetroAchievementsService();
            if (deferStartupLoads) {
              _runAfterTvLaunch('RetroAchievements init', service.initialize);
            } else {
              unawaited(service.initialize());
            }
            return service;
          },
        ),
        // Mode enforcement only — no longer depends on RA service.
        ChangeNotifierProvider(create: (_) => RARuntimeService()),
        // Native rcheevos client — bindings loaded lazily on first use
        // to avoid blocking app startup with DynamicLibrary.open()
        ChangeNotifierProvider(
          create: (_) {
            final bindings =
                RcheevosBindings(); // Don't load() here - lazy load later
            return RcheevosClient(bindings);
          },
        ),
      ],
      child: child,
    );
  }
}
