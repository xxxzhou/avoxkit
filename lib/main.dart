import 'package:flutter/material.dart';

void main() {
  runApp(const AvoxkitApp());
}

class AvoxkitApp extends StatelessWidget {
  const AvoxkitApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Avoxkit',
      theme: ThemeData(colorSchemeSeed: const Color(0xFF3D5AFE), useMaterial3: true),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Avoxkit', style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 8),
            Text('Free · Local · No account', style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 24),
            const Text('Engineering skeleton — features land milestone by milestone (see docs/architecture.md).'),
          ],
        ),
      ),
      bottomNavigationBar: const SafeArea(
        child: Padding(
          padding: EdgeInsets.only(bottom: 12),
          child: Text('Powered by avox', textAlign: TextAlign.center),
        ),
      ),
    );
  }
}
