// lib/main.dart
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:linkids/core/services/background_service.dart';
import 'package:linkids/features/home/home_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await BackgroundService.instance.initialize();
  runApp(const LinkidsApp());
}

class LinkidsApp extends StatelessWidget {
  const LinkidsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return WithForegroundTask(
      child: MaterialApp(
        title: 'Linkids',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          fontFamily: 'Inter',
          useMaterial3: true,
        ),
        home: const HomeScreen(),
      ),
    );
  }
}