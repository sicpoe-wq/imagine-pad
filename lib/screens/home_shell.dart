import 'package:flutter/material.dart';

import '../services/app_state.dart';
import 'create_screen.dart';
import 'edit_screen.dart';
import 'history_screen.dart';
import 'settings_screen.dart';

class HomeShell extends StatefulWidget {
  final AppState state;
  const HomeShell({super.key, required this.state});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    state.refreshUsage();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) state.refreshUsage();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: state.tab,
      builder: (context, tab, _) => Scaffold(
        body: IndexedStack(
          index: tab,
          children: [
            CreateScreen(state: state),
            EditScreen(state: state),
            HistoryScreen(state: state),
            SettingsScreen(state: state),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: tab,
          onDestinationSelected: (i) {
            state.tab.value = i;
            if (i <= AppState.tabEdit) state.refreshUsage();
          },
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.auto_awesome_outlined),
              selectedIcon: Icon(Icons.auto_awesome),
              label: 'Create',
            ),
            NavigationDestination(
              icon: Icon(Icons.auto_fix_high_outlined),
              selectedIcon: Icon(Icons.auto_fix_high),
              label: 'Edit',
            ),
            NavigationDestination(
              icon: Icon(Icons.photo_library_outlined),
              selectedIcon: Icon(Icons.photo_library),
              label: 'History',
            ),
            NavigationDestination(
              icon: Icon(Icons.tune_outlined),
              selectedIcon: Icon(Icons.tune),
              label: 'Settings',
            ),
          ],
        ),
      ),
    );
  }
}
