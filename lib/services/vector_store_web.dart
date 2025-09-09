import 'dart:math' as math;
import '../models/content_entity.dart';
import 'vector_store.dart';

class InMemoryVectorStore extends VectorStore {
  final List<ContentEntity> _contents = [];

  @override
  Future<void> addContent(ContentEntity content) async {
    _contents.add(content);
  }

  @override
  Future<void> addContents(List<ContentEntity> contents) async {
    _contents.addAll(contents);
  }

  @override
  Future<List<ContentEntity>> getAllContents() async {
    return List.from(_contents);
  }

  @override
  Future<List<ContentEntity>> getContentsByType(ContentType type) async {
    return _contents.where((c) => c.contentType == type).toList();
  }

  @override
  Future<List<ContentEntity>> searchSimilar(List<double> queryEmbedding, {int limit = 5}) async {
    if (queryEmbedding.isEmpty) return [];

    final results = <({ContentEntity content, double similarity})>[];

    for (final content in _contents) {
      if (content.embedding == null || content.embedding!.isEmpty) continue;
      
      final similarity = cosineSimilarity(queryEmbedding, content.embedding!);
      results.add((content: content, similarity: similarity));
    }

    results.sort((a, b) => b.similarity.compareTo(a.similarity));
    return results.take(limit).map((r) => r.content).toList();
  }

  @override
  Future<void> clear() async {
    _contents.clear();
  }

  @override
  Future<int> get count async => _contents.length;

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

VectorStore createVectorStore() => InMemoryVectorStore();