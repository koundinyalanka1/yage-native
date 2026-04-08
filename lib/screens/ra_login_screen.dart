import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/retro_achievements_service.dart';
import '../utils/theme.dart';
import '../utils/tv_detector.dart';
import '../widgets/tv_focusable.dart';

class RALoginScreen extends StatefulWidget {
  const RALoginScreen({super.key});

  @override
  State<RALoginScreen> createState() => _RALoginScreenState();
}

class _RALoginScreenState extends State<RALoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _usernameFocusNode = FocusNode();

  bool _obscurePassword = true;
  bool _isSubmitting = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _prefillCredentials();
    if (TvDetector.isTV) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_usernameFocusNode.canRequestFocus) {
          _usernameFocusNode.requestFocus();
        }
      });
      Future.delayed(const Duration(milliseconds: 150), () {
        if (_usernameFocusNode.canRequestFocus) {
          _usernameFocusNode.requestFocus();
        }
      });
    }
  }

  Future<void> _prefillCredentials() async {
    final raService = context.read<RetroAchievementsService>();
    final username = raService.username;
    final password = await raService.getStoredPassword();
    if (!mounted) return;
    if (username != null) _usernameController.text = username;
    if (password != null) _passwordController.text = password;
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _usernameFocusNode.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });

    final raService = context.read<RetroAchievementsService>();
    final result = await raService.login(
      _usernameController.text,
      _passwordController.text,
    );

    if (!mounted) return;

    if (result.success) {
      if (!mounted) return;
      Navigator.pop(context, true);
      ScaffoldMessenger.of(context)..clearSnackBars()..showSnackBar(
        SnackBar(
          content: Text(
            'Welcome, ${result.profile?.username ?? 'Player'}!',
          ),
          duration: const Duration(seconds: 3),
        ),
      );
    } else {
      setState(() {
        _isSubmitting = false;
        _errorMessage = result.errorMessage;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColorTheme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('RetroAchievements'),
        leading: TvFocusable(
          onTap: () => Navigator.pop(context),
          borderRadius: BorderRadius.circular(8),
          child: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.pop(context),
          ),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 8),
              Center(
                child: Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [colors.primary, colors.accent],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: colors.primary.withAlpha(80),
                        blurRadius: 16,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  child: const Center(
                    child: Icon(
                      Icons.emoji_events,
                      size: 36,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'RetroAchievements Login',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: colors.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Sign in with your RetroAchievements\n'
                'username and password.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: colors.textSecondary,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 32),
              TextFormField(
                controller: _usernameController,
                focusNode: _usernameFocusNode,
                autofocus: TvDetector.isTV,
                enabled: !_isSubmitting,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: 'Username',
                  hintText: 'Your RetroAchievements username',
                  prefixIcon: Icon(
                    Icons.person_outline,
                    color: colors.accent,
                  ),
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Username is required';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _passwordController,
                enabled: !_isSubmitting,
                obscureText: _obscurePassword,
                textInputAction: TextInputAction.done,
                onFieldSubmitted: (_) => _submit(),
                decoration: InputDecoration(
                  labelText: 'Password',
                  hintText: 'Your RetroAchievements password',
                  prefixIcon: Icon(
                    Icons.lock_outline,
                    color: colors.accent,
                  ),
                  suffixIcon: TvFocusable(
                    onTap: () {
                      setState(() => _obscurePassword = !_obscurePassword);
                    },
                    borderRadius: BorderRadius.circular(20),
                    child: IconButton(
                      icon: Icon(
                        _obscurePassword
                            ? Icons.visibility_off
                            : Icons.visibility,
                        color: colors.textMuted,
                      ),
                      onPressed: () {
                        setState(() => _obscurePassword = !_obscurePassword);
                      },
                    ),
                  ),
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Password is required';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colors.backgroundLight,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: colors.surfaceLight,
                    width: 1,
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.info_outline,
                      size: 18,
                      color: colors.accent,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Use your retroachievements.org credentials.\n'
                        'Your password is stored securely on-device\n'
                        'and never sent to any third party.',
                        style: TextStyle(
                          fontSize: 12,
                          color: colors.textSecondary,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              if (_errorMessage != null) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: colors.error.withAlpha(25),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: colors.error.withAlpha(80),
                      width: 1,
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.error_outline,
                        size: 20,
                        color: colors.error,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _errorMessage!,
                          style: TextStyle(
                            fontSize: 13,
                            color: colors.error,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],
              TvFocusable(
                onTap: _isSubmitting ? null : _submit,
                borderRadius: BorderRadius.circular(14),
                child: SizedBox(
                  height: 50,
                  child: ElevatedButton(
                    onPressed: _isSubmitting ? null : _submit,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: colors.primary,
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: colors.primary.withAlpha(100),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: _isSubmitting
                        ? SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              color: colors.textPrimary,
                            ),
                          )
                        : const Text(
                            'Sign In',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
