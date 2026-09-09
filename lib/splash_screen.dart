import 'ui/smart_home_design.dart';
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_service.dart';
import 'dashboard_page.dart';
import 'login_screen.dart';

class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fade;
  late final Animation<double> _scale;
  bool _navigationStarted = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 520),
    )..forward();
    _fade = CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic);
    _scale = Tween<double>(
      begin: 0.96,
      end: 1,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutBack));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _navigate(AuthService authService) async {
    if (_navigationStarted) return;
    _navigationStarted = true;

    // Keep the branding visible briefly, but do not force the user to wait 3 seconds.
    await Future.delayed(const Duration(milliseconds: 380));
    if (!mounted) return;

    final user = authService.currentUser;
    final destination = user != null && user.emailVerified
        ? const DashboardPage()
        : const LoginScreen();

    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 160),
        pageBuilder: (_, __, ___) => destination,
        transitionsBuilder: (_, animation, __, child) => FadeTransition(
          opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
          child: child,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<AuthService>>(authServiceProvider, (previous, next) {
      next.whenData((authService) => unawaited(_navigate(authService)));
    });

    final authState = ref.watch(authServiceProvider);
    authState.whenData((authService) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_navigate(authService));
      });
    });

    return Scaffold(
      body: _SplashBackground(
        child: SafeArea(
          child: Center(
            child: FadeTransition(
              opacity: _fade,
              child: ScaleTransition(
                scale: _scale,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const _SplashLogo(),
                    const SizedBox(height: 30),
                    Text(
                      'Smart Home',
                      style: Theme.of(context).textTheme.headlineLarge
                          ?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 38,
                            letterSpacing: 0.2,
                          ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Fast local control • Firebase sync • BLE backup',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.72),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    SizedBox(height: MediaQuery.sizeOf(context).height * .27),
                    authState.when(
                      data: (_) =>
                          const _LoadingPill(text: 'Preparing dashboard'),
                      loading: () =>
                          const _LoadingPill(text: 'Starting services'),
                      error: (error, _) => Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Text(
                          'Startup error: $error',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SplashBackground extends StatelessWidget {
  const _SplashBackground({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => HomeBackground(
    child: Stack(
      fit: StackFit.expand,
      children: [
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: MediaQuery.sizeOf(context).height * .48,
          child: ShaderMask(
            shaderCallback: (r) => const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.transparent,
                Colors.white,
                Colors.white,
                Colors.transparent,
              ],
              stops: [0, .25, .8, 1],
            ).createShader(r),
            blendMode: BlendMode.dstIn,
            child: ReferenceArt.house,
          ),
        ),
        child,
      ],
    ),
  );
}

class _SplashLogo extends StatelessWidget {
  const _SplashLogo();
  @override
  Widget build(BuildContext context) =>
      const SizedBox(width: 168, height: 168, child: ReferenceArt.logo);
}

class _LoadingPill extends StatelessWidget {
  final String text;
  const _LoadingPill({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: HomeDesign.blue.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: HomeDesign.blue.withValues(alpha: .8)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2.4,
              color: Colors.white,
            ),
          ),
          const SizedBox(width: 12),
          Text(
            text,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
