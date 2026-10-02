import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dashboard_page.dart';
import 'provisioning_page.dart';
import 'wifi_config_page.dart';
import 'io_modules_page.dart';
import 'splash_screen.dart';
import 'login_screen.dart';
import 'auth_service.dart';
import 'ellie/local_llm_service.dart';
import 'app_logger.dart';


const String appVersion = '3.3.1';



void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Account setup happens behind the first Flutter frame; native AI and feature
  // permissions are initialized only when the corresponding feature is used.
  runApp(const ProviderScope(child: MyApp()));
}

class MyApp extends ConsumerStatefulWidget {
  const MyApp({super.key});
  @override
  ConsumerState<MyApp> createState() => _MyAppState();
}

class _MyAppState extends ConsumerState<MyApp> {
  @override
  void initState() {
    super.initState();
    unawaited(_restoreTheme());
  }

  Future<void> _restoreTheme() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString('appearance_theme');
      if (!mounted || ref.read(themeModeProvider) != ThemeMode.system) return;
      for (final mode in ThemeMode.values) {
        if (mode.name == saved) ref.read(themeModeProvider.notifier).state = mode;
      }
    } catch (_) {
      // Unavailable preferences should not delay starting the app.
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(authUserProvider, (previous, next) {
      final account = next.asData;
      if (account == null) return;
      if (previous?.asData != null && previous!.asData!.value?.uid == account.value?.uid) return;
      unawaited(LocalLlmService.instance.resetForAccountChange(account.value?.uid)
          .catchError((Object error, StackTrace stack) => logDebug('Assistant session reset failed: $error')));
    });
    return MaterialApp(
      title: 'Smart Home',
      debugShowCheckedModeBanner: false,
      theme: lightTheme,
      darkTheme: darkTheme,
      themeMode: ref.watch(themeModeProvider),
      home: const SplashScreen(),
      routes: {
        '/login': (_) => const LoginScreen(),
        '/provision': (_) => const ProvisionPage(),
        '/wifiConfig': (_) => const WifiConfigPage(),
        '/ioModules': (_) => const IoModulesPage(),
      },
    );
  }
}
