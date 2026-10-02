import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'auth_service.dart';
import 'dashboard_page.dart';
import 'login_screen.dart';
import 'ui/smart_home_design.dart';

/// Shows the first frame immediately and waits only for required account setup.
class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});
  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen> {
  bool _navigationScheduled = false;

  void _openApp(AuthService service) {
    if (_navigationScheduled) return;
    _navigationScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final user = service.currentUser;
      final destination = user != null && user.emailVerified
          ? const DashboardPage()
          : const LoginScreen();
      Navigator.of(context).pushReplacement(PageRouteBuilder<void>(
        transitionDuration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero : const Duration(milliseconds: 120),
        pageBuilder: (_, __, ___) => destination,
        transitionsBuilder: (_, animation, __, child) => FadeTransition(opacity: animation, child: child),
      ));
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(authServiceProvider);
    state.whenData(_openApp);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: HomeBackground(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(28),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const SizedBox(width: 100, height: 100, child: HomeBrandMark()),
                  const SizedBox(height: 24),
                  const Text('Smart Home', style: TextStyle(fontSize: 32, fontWeight: FontWeight.w700, letterSpacing: -.7)),
                  const SizedBox(height: 10),
                  Text('Your home, connected.', textAlign: TextAlign.center, style: TextStyle(fontSize: 16, color: scheme.onSurfaceVariant)),
                  const SizedBox(height: 38),
                  state.when(
                    data: (_) => const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)),
                    loading: () => const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)),
                    error: (_, __) => Column(children: [
                      const Text('Could not start the app. Check your connection and try again.', textAlign: TextAlign.center),
                      const SizedBox(height: 16),
                      HomePrimaryButton(label: 'Try again', icon: Icons.refresh, onPressed: () {
                        _navigationScheduled = false;
                        ref.invalidate(firebaseInitializationProvider);
                        ref.invalidate(authServiceProvider);
                      }),
                    ]),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
