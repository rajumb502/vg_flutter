import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/content_entity.dart';
import 'simple_logger.dart';

class EmbeddingService {
  final String _apiKey;
  late final GenerativeModel _embeddingModel;
  static const int _maxContentLength = 20000;

  EmbeddingService(this._apiKey) {
    _initEmbeddingModel();
  }

  void _initEmbeddingModel() async {
    final prefs = await SharedPreferences.getInstance();
    final modelName =
        prefs.getString('embedding_model') ?? 'gemini-embedding-001';
    _embeddingModel = GenerativeModel(model: modelName, apiKey: _apiKey);
  }

  List<String> chunkText(String text) {
    if (text.length <= _maxContentLength) return [text];

    final chunks = <String>[];
    for (int i = 0; i < text.length; i += _maxContentLength) {
      final end = (i + _maxContentLength).clamp(0, text.length);
      chunks.add(text.substring(i, end));
    }
    return chunks;
  }

  List<ContentEntity> createChunkedEntities(
    ContentEntity original,
    String fullText,
  ) {
    final chunks = chunkText(fullText);
    final entities = <ContentEntity>[];

    for (int i = 0; i < chunks.length; i++) {
      final chunkEntity = ContentEntity.create(
        sourceId: '${original.sourceId}_chunk_$i',
        title: chunks.length > 1
            ? '${original.title} (Part ${i + 1}/${chunks.length})'
            : original.title,
        author: original.author,
        content: chunks[i],
        createdDate: original.createdDate,
        contentType: original.contentType,
      );
      entities.add(chunkEntity);
    }
    return entities;
  }

  Future<void> generateEmbeddingsBatch(
    List<String> texts,
    List<ContentEntity> entities,
  ) async {
    int successCount = 0;
    int failCount = 0;
    bool quotaExceeded = false;
    final maxRequests = await _maxConcurrentRequests;
    final rateLimitDelay = await _rateLimitDelay;

    // Group chunks by original entity to keep them together
    final entityGroups = <String, List<int>>{};
    for (int i = 0; i < entities.length; i++) {
      final baseId = entities[i].sourceId.split('_chunk_')[0];
      entityGroups[baseId] ??= [];
      entityGroups[baseId]!.add(i);
    }

    final allIndices = <int>[];
    for (final group in entityGroups.values) {
      allIndices.addAll(group);
    }

    for (
      int batchStart = 0;
      batchStart < allIndices.length && !quotaExceeded;
      batchStart += maxRequests
    ) {
      final batchEnd = (batchStart + maxRequests).clamp(0, allIndices.length);
      final batchIndices = allIndices.sublist(batchStart, batchEnd);

      final futures = batchIndices.map(
        (i) => _generateSingleEmbedding(texts[i], i),
      );
      final results = await Future.wait(futures, eagerError: false);

      for (int j = 0; j < results.length; j++) {
        final i = batchIndices[j];
        final result = results[j];

        if (result.success) {
          entities[i].embedding = result.embedding;
          successCount++;
        } else {
          entities[i].embedding = null;
          failCount++;

          if (result.isQuotaError) {
            SimpleLogger.log('Quota exceeded, stopping embedding generation');
            quotaExceeded = true;
            break;
          }
        }
      }

      if (batchEnd < allIndices.length && !quotaExceeded) {
        await Future.delayed(rateLimitDelay);
      }
    }

    SimpleLogger.log(
      'Embedding results: $successCount success, $failCount failed',
    );
  }

  Future<Duration> get _rateLimitDelay async {
    final prefs = await SharedPreferences.getInstance();
    final seconds = prefs.getInt('rate_limit_seconds') ?? 15;
    return Duration(seconds: seconds);
  }

  Future<int> get _maxConcurrentRequests async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt('max_concurrent_requests') ?? 3;
  }

  Future<EmbeddingResult> _generateSingleEmbedding(
    String text,
    int index,
  ) async {
    try {
      final response = await _embeddingModel.embedContent(Content.text(text));
      return EmbeddingResult(
        success: true,
        embedding: response.embedding.values,
      );
    } catch (e) {
      SimpleLogger.log('Embedding error for item $index: $e');
      final isQuotaError =
          e.toString().contains('429') ||
          e.toString().contains('RESOURCE_EXHAUSTED');
      return EmbeddingResult(success: false, isQuotaError: isQuotaError);
    }
  }
}

class EmbeddingResult {
  final bool success;
  final List<double>? embedding;
  final bool isQuotaError;

  EmbeddingResult({
    required this.success,
    this.embedding,
    this.isQuotaError = false,
  });
}
