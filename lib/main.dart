import 'package:flutter/material.dart';

import 'app.dart';
import 'avatar/avatar_profile.dart';
import 'data/repository_factory.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Optional local avatar tuning file. Missing/invalid -> built-in defaults.
  await AvatarProfile.preload();
  // Opens the local SQLite database; falls back to in-memory history if that fails.
  final RepositoryOpenResult result = await openDefaultRepository();
  runApp(
    AlmusApp(
      repository: result.repository,
      memoryRepository: result.memory,
      persistentHistory: result.persistent,
    ),
  );
}
