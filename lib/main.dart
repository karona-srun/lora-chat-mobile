import 'package:another_flutter_splash_screen/another_flutter_splash_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'l10n/app_localizations.dart';
import 'screens/group_screen.dart';
import 'screens/connect_screen.dart';
import 'screens/settings_screen.dart';
import 'services/local_database_service.dart';
import 'services/message_background_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  await LocalDatabaseService.instance.ensureInitialized();
  await MessageBackgroundService.ensureInitialized();
  runApp(const SplashWrapper());
}

/// Root widget that shows [another_flutter_splash_screen] then [MeshtasticApp].
class SplashWrapper extends StatelessWidget {
  const SplashWrapper({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: FlutterSplashScreen.fadeIn(
        backgroundColor: Colors.white,
        duration: const Duration(milliseconds: 1500),
        onInit: () async {
          await SharedPreferences.getInstance();
        },
        childWidget: SizedBox(
          height: 200,
          width: 200,
          child: Image.asset('assets/images/logo.png', fit: BoxFit.contain),
        ),
        nextScreen: const MeshtasticApp(),
      ),
    );
  }
}

class MeshtasticApp extends StatefulWidget {
  const MeshtasticApp({super.key});

  @override
  State<MeshtasticApp> createState() => _MeshtasticAppState();
}

class _MeshtasticAppState extends State<MeshtasticApp> {
  ThemeMode _themeMode = ThemeMode.system;
  Locale _locale = const Locale('en');

  @override
  void initState() {
    super.initState();
    _loadPreferences();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      MessageBackgroundService.requestNotificationPermissions();
    });
  }

  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final dark = prefs.getBool('dark_mode');
    final code = prefs.getString('locale');
    setState(() {
      if (dark != null) {
        _themeMode = dark ? ThemeMode.dark : ThemeMode.light;
      }
      if (code != null && (code == 'en' || code == 'km')) {
        _locale = Locale(code);
      }
    });
  }

  void _onThemeChanged(bool dark) {
    setState(() {
      _themeMode = dark ? ThemeMode.dark : ThemeMode.light;
    });
  }

  void _onLanguageChanged(bool isKhmer) {
    setState(() {
      _locale = isKhmer ? const Locale('km') : const Locale('en');
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Lomhor',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.light(
          primary: Colors.black,
          onPrimary: Colors.white,
          secondary: Colors.black,
          onSecondary: Colors.black,
          tertiary: Colors.black,
          onTertiary: Colors.white,
          surface: Colors.white,
          onSurface: Colors.black,
          onSurfaceVariant: Colors.black87,
          outline: Colors.black,
          outlineVariant: Colors.black54,
          surfaceContainerHighest: const Color(0xFFF5F5F5),
          surfaceContainerHigh: const Color(0xFFFAFAFA),
          surfaceContainer: const Color(0xFFF5F5F5),
          surfaceContainerLow: Colors.white,
          surfaceBright: Colors.white,
          surfaceDim: const Color(0xFFEEEEEE),
          inverseSurface: Colors.white,
          onInverseSurface: Colors.black,
          inversePrimary: Colors.white,
          error: Colors.black,
          onError: Colors.white,
          scrim: Colors.black54,
        ),
        dialogTheme: DialogThemeData(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          elevation: 24,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          titleTextStyle: const TextStyle(
            color: Colors.black,
            fontSize: 20,
            fontWeight: FontWeight.w600,
          ),
          contentTextStyle: const TextStyle(
            color: Colors.black87,
            fontSize: 14,
          ),
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.dark(
          primary: Colors.white,
          onPrimary: Colors.black,
          secondary: Colors.white,
          onSecondary: Colors.white,
          tertiary: Colors.white,
          onTertiary: Colors.black,
          surface: Colors.black,
          onSurface: Colors.white,
          onSurfaceVariant: Colors.white70,
          outline: Colors.white,
          outlineVariant: Colors.white54,
          surfaceContainerHighest: const Color(0xFF2D2D2D),
          surfaceContainerHigh: const Color(0xFF262626),
          surfaceContainer: const Color(0xFF2D2D2D),
          surfaceContainerLow: const Color(0xFF1A1A1A),
          surfaceBright: const Color(0xFF383838),
          surfaceDim: Colors.black,
          inverseSurface: Colors.black,
          onInverseSurface: Colors.white,
          inversePrimary: Colors.black,
          error: Colors.white,
          onError: Colors.black,
          scrim: Colors.black87,
        ),
        dialogTheme: DialogThemeData(
          backgroundColor: const Color(0xFF1E1E1E),
          surfaceTintColor: Colors.transparent,
          elevation: 24,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          titleTextStyle: const TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w600,
          ),
          contentTextStyle: const TextStyle(
            color: Colors.white70,
            fontSize: 14,
          ),
        ),
        useMaterial3: true,
      ),
      themeMode: _themeMode,
      locale: _locale,
      supportedLocales: const [Locale('en'), Locale('km')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (context, child) {
        if (child == null) return const SizedBox.shrink();
        return AppLocalizations.wrap(locale: _locale, child: child);
      },
      home: MainScreen(
        onThemeChanged: _onThemeChanged,
        onLanguageChanged: _onLanguageChanged,
      ),
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key, this.onThemeChanged, this.onLanguageChanged});

  final void Function(bool dark)? onThemeChanged;
  final void Function(bool isKhmer)? onLanguageChanged;

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _currentIndex = 0; // Start with Channels & Chats tab
  int _settingsRefreshToken = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(_lifecycleObserver);
  }

  final _AppLifecycleObserver _lifecycleObserver = _AppLifecycleObserver();

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(_lifecycleObserver);
    super.dispose();
  }

  List<Widget> get _screens => [
    const GroupScreen(),
    const ConnectScreen(),
    SettingsScreen(
      key: ValueKey('settings-$_settingsRefreshToken'),
      onThemeChanged: widget.onThemeChanged,
      onLanguageChanged: widget.onLanguageChanged,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      body: IndexedStack(index: _currentIndex, children: _screens),
      bottomNavigationBar: NavigationBar(
        backgroundColor: Colors.transparent,
        indicatorColor: Colors.transparent,
        selectedIndex: _currentIndex,
        onDestinationSelected: (int index) {
          setState(() {
            if (index == 2 && _currentIndex != 2) {
              _settingsRefreshToken++;
            }
            _currentIndex = index;
          });
        },
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.chat_bubble_outline),
            selectedIcon: const Icon(Icons.chat),
            label: l10n.tr('messages'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.link),
            label: l10n.tr('connect'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.settings_outlined),
            selectedIcon: const Icon(Icons.settings),
            label: l10n.tr('settings'),
          ),
        ],
      ),
    );
  }
}

class _AppLifecycleObserver with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final isForeground = state == AppLifecycleState.resumed;
    MessageBackgroundService.setAppForegroundState(isForeground);
  }
}
