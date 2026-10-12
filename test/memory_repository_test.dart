import 'package:almus_ai/data/memory_conversation_repository.dart';

import 'repository_contract.dart';

void main() {
  runRepositoryContract('In-memory', () async => MemoryConversationRepository());
}
