import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/theme.dart';
import 'src/ui/home_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Dracula.background,
    systemNavigationBarIconBrightness: Brightness.light,
  ));
  runApp(const SosNumbersApp());
}

class SosNumbersApp extends StatelessWidget {
  const SosNumbersApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Emergency Numbers',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: const HomePage(),
    );
  }
}
