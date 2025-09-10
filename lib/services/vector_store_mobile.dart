import 'dart:math' as math;
import '../models/content_entity.dart';
import '../objectbox.g.dart';
import 'vector_store.dart';

class ObjectBoxVectorStore extends VectorStore {
  late final Store _store;
  late final Box<ContentEntity> _box;
  bool _initialized = false;

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    
    final store = await openStore();
    _store = store;
    _box = _store.box<ContentEntity>();
    _initialized = true;
  }

  @override
  Future<void> addContent(ContentEntity content) async {
    await _ensureInitialized();
    _box.put(content);
  }

  @override
  Future<void> addContents(List<ContentEntity> contents) async {
    await _ensureInitialized();
    
    // Filter out duplicates by checking sourceId
    final existingSourceIds = <String>{};
    final allExisting = _box.getAll();
    for (final existing in allExisting) {
      existingSourceIds.add(existing.sourceId);
    }
    
    final newContents = contents.where((content) => !existingSourceIds.contains(content.sourceId)).toList();
    
    if (newContents.isNotEmpty) {
      _box.putMany(newContents);
    }
  }

  @override
  Future<List<ContentEntity>> getAllContents() async {
    await _ensureInitialized();
    return _box.getAll();
  }

  @override
  Future<List<ContentEntity>> getContentsByType(ContentType type) async {
    await _ensureInitialized();
    final query = _box.query(ContentEntity_.contentTypeIndex.equals(type.index)).build();
    final results = query.find();
    query.close();
    return results;
  }

  @override
  Future<List<ContentEntity>> searchSimilar(List<double> queryEmbedding, {int limit = 5}) async {
    await _ensureInitialized();
    final allContents = _box.getAll();
    
    if (queryEmbedding.isEmpty) return [];

    final results = <({ContentEntity content, double similarity})>[];

    for (final content in allContents) {
      if (content.embedding == null || content.embedding!.isEmpty) continue;
      
      final similarity = cosineSimilarity(queryEmbedding, content.embedding!);
      results.add((content: content, similarity: similarity));
    }

    results.sort((a, b) => b.similarity.compareTo(a.similarity));
    return results.take(limit).map((r) => r.content).toList();
  }

  @override
  Future<void> clear() async {
    await _ensureInitialized();
    _box.removeAll();
  }

  @override
  Future<int> get count async {
    await _ensureInitialized();
    return _box.count();
  }

  double cosineSimilarity(List<double> a, List<double> b) {
    if (a.length != b.length) return 0.0;

    double dotProduct = 0.0;
    double normA = 0.0;
    double normB = 0.0;

    for (int i = 0; i < a.length; i++) {
      dotProduct += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }

    if (normA == 0.0 || normB == 0.0) return 0.0;
    return dotProduct / (math.sqrt(normA) * math.sqrt(normB));
  }
}

VectorStore createVectorStore() => ObjectBoxVectorStore();