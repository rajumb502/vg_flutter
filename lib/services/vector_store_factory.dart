import 'vector_store.dart';
import 'vector_store_web.dart' if (dart.library.io) 'vector_store_mobile.dart';

class VectorStoreFactory {
  static VectorStore? _instance;
  
  static VectorStore getInstance() {
    _instance ??= createVectorStore();
    return _instance!;
  }
}