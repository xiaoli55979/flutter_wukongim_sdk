import 'package:flutter/material.dart';
import 'debug_example.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'WuKongIM SDK Demo',
      theme: ThemeData(primarySwatch: Colors.blue, useMaterial3: true),
      home: const DebugWuKongIMExample(),
    );
  }
}
