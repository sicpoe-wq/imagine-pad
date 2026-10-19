import 'package:flutter/material.dart';

import '../services/app_state.dart';
import 'create_screen.dart';
import 'history_screen.dart';
import 'settings_screen.dart';

class HomeShell extends StatelessWidget {
  final AppState state;
  const HomeShell({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: state.tab,
      builder: (context, tab, _) => Scaffold(
        body: IndexedStack(index: tab, children: [
          CreateScreen(state: state),
          HistoryScreen(state: state),
          SettingsScreen(state: state),
        ]),
        bottomNavigationBar: NavigationBar(
          selectedIndex: tab,
          onDestinationSelected: (i) => state.tab.value = i,
          destinations: const [
            NavigationDestination(
                icon: Icon(Icons.auto_awesome_outlined),
                selectedIcon: Icon(Icons.auto_awesome),
                label: 'Create'),
            NavigationDestination(
                icon: Icon(Icons.photo_library_outlined),
                selectedIcon: Icon(Icons.photo_library),
                label: 'History'),
            NavigationDestination(
                icon: Icon(Icons.tune_outlined),
                selectedIcon: Icon(Icons.tune),
                label: 'Settings'),
          ],
        ),
      ),
    );
  }
}
