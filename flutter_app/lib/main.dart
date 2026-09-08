import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'screens/pairing_screen.dart';
import 'screens/dashboard_screen.dart';
import 'api/homevault_api.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final host = prefs.getString('host');
  final token = prefs.getString('token');
  runApp(HomeVaultApp(paired: host != null && token != null));
}

class HomeVaultApp extends StatelessWidget {
  final bool paired;
  const HomeVaultApp({super.key, required this.paired});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HomeVault',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF3B82F6),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF0B0F17),
        cardTheme: CardThemeData(
          color: const Color(0xFF141A24),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
      home: paired ? const DashboardScreen() : const PairingScreen(),
    );
  }
}
