import 'ui/smart_home_design.dart';
import 'dart:ui' as ui;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_service.dart';
import 'dashboard_page.dart';

class _LoginColors {
  static const purple = HomeDesign.blue;
  static const deepPurple = Color(0xFF34236F);
  static const cyan = Color(0xFF4DDCFF);
  static const green = Color(0xFF4DFFA0);
  static const red = Color(0xFFFF5252);
  static const amber = Color(0xFFFFB347);
}

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen>
    with SingleTickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _nameController = TextEditingController();
  final _espCodeController = TextEditingController();

  late final AnimationController _introController;
  late final Animation<double> _fadeAnimation;
  late final Animation<Offset> _slideAnimation;

  bool _isLogin = true;
  bool _isLoading = false;
  bool _passwordVisible = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _introController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    )..forward();
    _fadeAnimation = CurvedAnimation(
      parent: _introController,
      curve: Curves.easeOutCubic,
    );
    _slideAnimation =
        Tween<Offset>(begin: const Offset(0, 0.018), end: Offset.zero).animate(
          CurvedAnimation(parent: _introController, curve: Curves.easeOutCubic),
        );
  }

  @override
  void dispose() {
    _introController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _nameController.dispose();
    _espCodeController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final authService = await ref.read(authServiceProvider.future);
      final email = _emailController.text.trim();
      final password = _passwordController.text.trim();

      if (_isLogin) {
        final user = await authService.signInWithEmailPassword(
          email: email,
          password: password,
        );
        if (user != null && mounted) {
          HapticFeedback.lightImpact();
          Navigator.of(context).pushReplacement(
            PageRouteBuilder(
              pageBuilder: (_, __, ___) => const DashboardPage(),
              transitionsBuilder: (_, animation, __, child) =>
                  FadeTransition(opacity: animation, child: child),
            ),
          );
        }
      } else {
        final user = await authService.registerWithEmailPassword(
          email: email,
          password: password,
          displayName: _nameController.text.trim(),
          esp32Code: _espCodeController.text.trim(),
        );
        if (user != null && mounted) {
          HapticFeedback.lightImpact();
          _showVerificationDialog();
        }
      }
    } on FirebaseAuthException catch (e) {
      if (mounted) setState(() => _errorMessage = _getFirebaseErrorMessage(e));
    } catch (e) {
      if (mounted) setState(() => _errorMessage = _cleanError(e));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  String _cleanError(Object error) {
    final message = error.toString().replaceFirst('Exception: ', '').trim();
    return message.isEmpty
        ? 'Something went wrong. Please try again.'
        : message;
  }

  String _getFirebaseErrorMessage(FirebaseAuthException e) {
    switch (e.code) {
      case 'user-not-found':
      case 'invalid-credential':
        return 'Email or password is incorrect.';
      case 'wrong-password':
        return 'Wrong password provided.';
      case 'email-already-in-use':
        return 'Email already in use.';
      case 'weak-password':
        return 'Password is too weak.';
      case 'invalid-email':
        return 'Invalid email address.';
      case 'too-many-requests':
        return 'Too many requests. Please try again later.';
      case 'network-request-failed':
        return 'Network error. Check your internet connection.';
      default:
        return e.message ?? 'An error occurred. Please try again.';
    }
  }

  void _toggleMode() {
    HapticFeedback.selectionClick();
    setState(() {
      _isLogin = !_isLogin;
      _errorMessage = null;
      _formKey.currentState?.reset();
    });
  }

  Future<void> _showVerificationDialog() async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        title: const Text('Verify your email'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _LoginColors.purple.withOpacity(0.12),
              ),
              child: const Icon(
                Icons.mark_email_read_rounded,
                size: 34,
                color: _LoginColors.purple,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'We sent a verification link to:',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              _emailController.text.trim(),
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                color: _LoginColors.purple,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Text(
              'Verify your email, then sign in again.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Theme.of(context).hintColor),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              setState(() => _isLogin = true);
            },
            child: const Text('Go to Login'),
          ),
          FilledButton(
            onPressed: () async {
              try {
                final authService = await ref.read(authServiceProvider.future);
                await authService.resendVerificationEmail();
                if (mounted) {
                  _showSnack(
                    'Verification email resent',
                    color: _LoginColors.purple,
                  );
                }
              } catch (e) {
                if (mounted) {
                  _showSnack(_cleanError(e), color: _LoginColors.red);
                }
              }
            },
            child: const Text('Resend'),
          ),
        ],
      ),
    );
  }

  void _showSnack(String message, {required Color color}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  Future<void> _showForgotPasswordDialog() async {
    final emailController = TextEditingController(
      text: _emailController.text.trim(),
    );
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        title: const Text('Reset password'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.lock_reset_rounded,
              size: 52,
              color: _LoginColors.purple,
            ),
            const SizedBox(height: 16),
            const Text(
              'Enter your email and we will send a reset link.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 18),
            _SmartTextField(
              controller: emailController,
              label: 'Email address',
              hint: 'your@email.com',
              icon: Icons.email_outlined,
              keyboardType: TextInputType.emailAddress,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(context);
              try {
                final authService = await ref.read(authServiceProvider.future);
                await authService.resetPassword(emailController.text.trim());
                if (mounted) {
                  _showSnack(
                    'Password reset email sent',
                    color: _LoginColors.green,
                  );
                }
              } catch (e) {
                if (mounted)
                  _showSnack(_cleanError(e), color: _LoginColors.red);
              }
            },
            child: const Text('Send'),
          ),
        ],
      ),
    );
    emailController.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final isWide = size.width >= 840;

    return Scaffold(
      body: _LoginBackground(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.manual,
              padding: EdgeInsets.symmetric(
                horizontal: isWide ? 48 : 18,
                vertical: 12,
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1020),
                child: FadeTransition(
                  opacity: _fadeAnimation,
                  child: SlideTransition(
                    position: _slideAnimation,
                    child: isWide
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              const Expanded(child: _HeroPanel()),
                              const SizedBox(width: 28),
                              Expanded(child: _buildAuthCard(context)),
                            ],
                          )
                        : Column(
                            children: [
                              const _CompactHeader(),
                              const SizedBox(height: 16),
                              _buildAuthCard(context),
                            ],
                          ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAuthCard(BuildContext context) {
    return Padding(
      padding: EdgeInsets.zero,
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _isLogin ? 'Welcome back' : 'Create account',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 29, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              _isLogin
                  ? 'Control your home instantly.'
                  : 'Pair your ESP32 and start controlling devices.',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 17, color: Color(0xFF98AED3)),
            ),
            const SizedBox(height: 25),
            _ModeSwitch(isLogin: _isLogin, onChanged: _toggleMode),
            const SizedBox(height: 22),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 90),
              reverseDuration: const Duration(milliseconds: 70),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeOutCubic,
              transitionBuilder: (child, animation) =>
                  FadeTransition(opacity: animation, child: child),
              child: _isLogin ? _buildLoginFields() : _buildRegisterFields(),
            ),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 90),
              child: _errorMessage == null
                  ? const SizedBox.shrink()
                  : Padding(
                      key: ValueKey(_errorMessage),
                      padding: const EdgeInsets.only(top: 16),
                      child: _ErrorBox(message: _errorMessage!),
                    ),
            ),
            const SizedBox(height: 24),
            HomePrimaryButton(
              label: _isLogin ? 'Sign In' : 'Create Account',
              onPressed: _isLoading ? null : _submit,
              busy: _isLoading,
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  _isLogin ? 'No account yet?' : 'Already registered?',
                  style: TextStyle(
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withOpacity(0.58),
                  ),
                ),
                TextButton(
                  onPressed: _isLoading ? null : _toggleMode,
                  child: Text(_isLogin ? 'Sign up' : 'Sign in'),
                ),
              ],
            ),
            if (_isLogin) ...[
              const SizedBox(height: 22),
              const Row(
                children: [
                  Expanded(child: Divider()),
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      'OR JUST KNOW',
                      style: TextStyle(
                        fontSize: 8,
                        letterSpacing: 2,
                        color: Color(0xFF7B94BA),
                      ),
                    ),
                  ),
                  Expanded(child: Divider()),
                ],
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  for (final item in const [
                    (Icons.bolt, 'Low latency', 'Real-time control'),
                    (Icons.bluetooth, 'BLE backup', 'Offline ready'),
                    (
                      Icons.cloud_outlined,
                      'Firebase auth',
                      'Secure & reliable',
                    ),
                  ])
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        child: HomeCard(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 12,
                          ),
                          child: Row(
                            children: [
                              Icon(
                                item.$1,
                                size: 21,
                                color: HomeDesign.cyan,
                                shadows: const [
                                  Shadow(color: HomeDesign.blue, blurRadius: 9),
                                ],
                              ),
                              const SizedBox(width: 5),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      item.$2,
                                      style: const TextStyle(fontSize: 8.5),
                                    ),
                                    const SizedBox(height: 3),
                                    Text(
                                      item.$3,
                                      style: const TextStyle(
                                        fontSize: 7,
                                        color: Color(0xFF8CA3C6),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 23),
              TextButton(
                onPressed: _isLoading ? null : _showForgotPasswordDialog,
                child: const Text('Forgot password?'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildLoginFields() {
    return Column(
      key: const ValueKey('loginFields'),
      children: [
        _SmartTextField(
          controller: _emailController,
          label: 'Email address',
          hint: 'your@email.com',
          icon: Icons.email_outlined,
          keyboardType: TextInputType.emailAddress,
          validator: _validateEmail,
        ),
        const SizedBox(height: 16),
        _SmartTextField(
          controller: _passwordController,
          label: 'Password',
          hint: 'Min 6 characters',
          icon: Icons.lock_outline_rounded,
          obscureText: !_passwordVisible,
          suffixIcon: IconButton(
            onPressed: () =>
                setState(() => _passwordVisible = !_passwordVisible),
            icon: Icon(
              _passwordVisible
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
            ),
          ),
          validator: _validatePassword,
          onFieldSubmitted: (_) => _submit(),
        ),
      ],
    );
  }

  Widget _buildRegisterFields() {
    return Column(
      key: const ValueKey('registerFields'),
      children: [
        _SmartTextField(
          controller: _nameController,
          label: 'Full name',
          hint: 'Muhammed Ahmed',
          icon: Icons.person_outline_rounded,
          textInputAction: TextInputAction.next,
          validator: (value) => (value == null || value.trim().length < 2)
              ? 'Please enter your name'
              : null,
        ),
        const SizedBox(height: 16),
        _SmartTextField(
          controller: _emailController,
          label: 'Email address',
          hint: 'your@email.com',
          icon: Icons.email_outlined,
          keyboardType: TextInputType.emailAddress,
          validator: _validateEmail,
        ),
        const SizedBox(height: 16),
        _SmartTextField(
          controller: _passwordController,
          label: 'Password',
          hint: 'Min 6 characters',
          icon: Icons.lock_outline_rounded,
          obscureText: !_passwordVisible,
          suffixIcon: IconButton(
            onPressed: () =>
                setState(() => _passwordVisible = !_passwordVisible),
            icon: Icon(
              _passwordVisible
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
            ),
          ),
          validator: _validatePassword,
        ),
        const SizedBox(height: 16),
        _SmartTextField(
          controller: _espCodeController,
          label: 'ESP32 unique code',
          hint: 'ESP32-XXXXXXXXXXXX-...',
          icon: Icons.memory_rounded,
          textCapitalization: TextCapitalization.characters,
          validator: (value) {
            final code = value?.trim() ?? '';
            if (code.isEmpty) return 'Please enter your ESP32 code';
            if (!code.toUpperCase().startsWith('ESP32-'))
              return 'Code should start with ESP32-';
            if (code.length < 12) return 'Code looks too short';
            return null;
          },
          onFieldSubmitted: (_) => _submit(),
        ),
      ],
    );
  }

  String? _validateEmail(String? value) {
    final email = value?.trim() ?? '';
    if (email.isEmpty) return 'Please enter your email';
    final valid = RegExp(r'^[\w\-.]+@([\w-]+\.)+[\w-]{2,}$').hasMatch(email);
    if (!valid) return 'Please enter a valid email';
    return null;
  }

  String? _validatePassword(String? value) {
    final password = value ?? '';
    if (password.isEmpty) return 'Please enter your password';
    if (password.length < 6) return 'Password must be at least 6 characters';
    return null;
  }
}

class _LoginBackground extends StatelessWidget {
  const _LoginBackground({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => HomeBackground(child: child);
}

class _GlassCard extends StatelessWidget {
  final Widget child;
  const _GlassCard({required this.child});

  @override
  Widget build(BuildContext context) =>
      HomeCard(padding: const EdgeInsets.all(22), child: child);
}

class _HeroPanel extends StatelessWidget {
  const _HeroPanel();
  @override
  Widget build(BuildContext context) => const HomeHero(
    title: 'Smart Home',
    subtitle: 'Fast local control. Bluetooth backup. A home that listens.',
    height: 360,
  );
}

class _CompactHeader extends StatelessWidget {
  const _CompactHeader();
  @override
  Widget build(BuildContext context) => SizedBox(
    height: 195,
    child: Stack(
      clipBehavior: Clip.none,
      fit: StackFit.expand,
      children: [
        Positioned(
          left: -18,
          right: -18,
          top: 0,
          bottom: 0,
          child: ShaderMask(
            blendMode: BlendMode.dstIn,
            shaderCallback: (r) => const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.transparent,
                Colors.white,
                Colors.white,
                Colors.transparent,
              ],
              stops: [0, .2, .7, 1],
            ).createShader(r),
            child: ReferenceArt.house,
          ),
        ),
        Column(
          children: [
            const SizedBox(height: 17),
            Icon(
              Icons.home_outlined,
              size: 70,
              color: const Color(0xFF7CB5FF),
              shadows: const [
                Shadow(color: HomeDesign.blue, blurRadius: 15),
                Shadow(color: HomeDesign.violet, blurRadius: 25),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              'SMARTER\nBRIGHTER HOME',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                letterSpacing: 2.4,
                color: Color(0xFFCCD9FF),
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

class _ModeSwitch extends StatelessWidget {
  const _ModeSwitch({required this.isLogin, required this.onChanged});
  final bool isLogin;
  final VoidCallback onChanged;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: ReferenceChoice(
          label: 'Sign In',
          icon: Icons.person,
          selected: isLogin,
          onTap: () {
            if (!isLogin) onChanged();
          },
        ),
      ),
      Expanded(
        child: ReferenceChoice(
          label: 'Sign Up',
          icon: Icons.person_add_alt_1,
          selected: !isLogin,
          onTap: () {
            if (isLogin) onChanged();
          },
        ),
      ),
    ],
  );
}

class _SmartTextField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String hint;
  final IconData icon;
  final TextInputType? keyboardType;
  final bool obscureText;
  final Widget? suffixIcon;
  final String? Function(String?)? validator;
  final TextInputAction textInputAction;
  final TextCapitalization textCapitalization;
  final ValueChanged<String>? onFieldSubmitted;

  const _SmartTextField({
    required this.controller,
    required this.label,
    required this.hint,
    required this.icon,
    this.keyboardType,
    this.obscureText = false,
    this.suffixIcon,
    this.validator,
    this.textInputAction = TextInputAction.next,
    this.textCapitalization = TextCapitalization.none,
    this.onFieldSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      keyboardType: keyboardType,
      obscureText: obscureText,
      validator: validator,
      textInputAction: textInputAction,
      textCapitalization: textCapitalization,
      onFieldSubmitted: onFieldSubmitted,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: Icon(icon),
        suffixIcon: suffixIcon,
        filled: true,
        fillColor: Theme.of(context).colorScheme.surface.withOpacity(0.72),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 17,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(
            color: Theme.of(context).dividerColor.withOpacity(0.25),
          ),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(
            color: Theme.of(context).dividerColor.withOpacity(0.25),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: const BorderSide(color: _LoginColors.purple, width: 1.6),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: const BorderSide(color: _LoginColors.red),
        ),
      ),
    );
  }
}

class _ErrorBox extends StatelessWidget {
  final String message;
  const _ErrorBox({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _LoginColors.red.withOpacity(0.10),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _LoginColors.red.withOpacity(0.22)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.error_outline_rounded,
            color: _LoginColors.red,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                color: _LoginColors.red,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
