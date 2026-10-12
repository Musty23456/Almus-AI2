import 'package:almus_ai/data/volatile_memory_repository.dart';

import 'memory_repository_contract.dart';

void main() {
  runMemoryRepositoryContract(
    'In-memory',
    () async => VolatileMemoryRepository(),
  );
}
