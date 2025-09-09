import 'dart:html' as html;
import 'dart:math' as math;
import '../models/content_entity.dart';
import 'vector_store.dart';

class PersistentWebVectorStore extends VectorStore {
  static const String _dbName = 'VectorStoreDB';
  static const String _storeName = 'contents';
  static const int _dbVersion = 1;

  dynamic _db;

  Future<void> _ensureInitialized() async {
    if (_db != null) return;

    _db = await html.window.indexedDB!.open(
      _dbName,
      version: _dbVersion,
      onUpgradeNeeded: (dynamic e) {
        final db = e.target.result;
        if (!db.objectStoreNames!.contains(_storeName)) {
          db.createObjectStore(_storeName, keyPath: 'sourceId');
        }
      },
    );
  }

  @override
  Future<void> addContent(ContentEntity content) async {
    await _ensureInitialized();
    final transaction = _db!.transaction(_storeName, 'readwrite');
    final store = transaction.objectStore(_storeName);
    await store.put(_contentToMap(content));
  }

  @override
  Future<void> addContents(List<ContentEntity> contents) async {
    await _ensureInitialized();
    final transaction = _db!.transaction(_storeName, 'readwrite');
    final store = transaction.objectStore(_storeName);

    for (final content in contents) {
      await store.put(_contentToMap(content));
    }
  }

  @override
  Future<List<ContentEntity>> getAllContents() async {
    await _ensureInitialized();
    final transaction = _db!.transaction(_storeName, 'readonly');
    final store = transaction.objectStore(_storeName);
    final cursor = store.openCursor();

    final contents = <ContentEntity>[];
    await for (final cursorWithValue in cursor) {
      final map = cursorWithValue.value as Map<String, dynamic>;
      contents.add(_mapToContent(map));
      cursorWithValue.next();
    }

    return contents;
  }

  @override
  Future<List<ContentEntity>> getContentsByType(ContentType type) async {
    final allContents = await getAllContents();
    return allContents.where((c) => c.contentType == type).toList();
  }

  @override
  Future<List<ContentEntity>> searchSimilar(
    List<double> queryEmbedding, {
    int limit = 5,
  }) async {
    final allContents = await getAllContents();

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
    final transaction = _db!.transaction(_storeName, 'readwrite');
    final store = transaction.objectStore(_storeName);
    await store.clear();
  }

  @override
  Future<int> get count async {
    await _ensureInitialized();
    final transaction = _db!.transaction(_storeName, 'readonly');
    final store = transaction.objectStore(_storeName);
    return await store.count();
  }

  Map<String, dynamic> _contentToMap(ContentEntity content) {
    return {
      'sourceId': content.sourceId,
      'title': content.title,
      'author': content.author,
      'content': content.content,
      'createdDate': content.createdDate.millisecondsSinceEpoch,
      'contentType': content.contentType.index,
      'embedding': content.embedding,
    };
  }

  ContentEntity _mapToContent(Map<String, dynamic> map) {
    return ContentEntity.create(
      sourceId: map['sourceId'] as String,
      title: map['title'] as String,
      author: map['author'] as String,
      content: map['content'] as String,
      createdDate: DateTime.fromMillisecondsSinceEpoch(
        map['createdDate'] as int,
      ),
      contentType: ContentType.values[map['contentType'] as int],
    )..embedding = (map['embedding'] as List?)?.cast<double>();
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

VectorStore createVectorStore() => PersistentWebVectorStore();
