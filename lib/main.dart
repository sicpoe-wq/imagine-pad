import 'package:flutter/material.dart';

import 'screens/home_shell.dart';
import 'services/app_state.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final state = await AppState.create();
  runApp(ImaginePadApp(state: state));
}

class ImaginePadApp extends StatelessWidget {
  final AppState state;
  const ImaginePadApp({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Imagine Pad',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.dark,
      home: HomeShell(state: state),
    );
  }
}
