import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/content_entity.dart';
import 'simple_logger.dart';

class EmbeddingService {
  final String _apiKey;
  GenerativeModel? _embeddingModel;
  static const int _maxContentLength = 20000;

  EmbeddingService(this._apiKey);

  Future<GenerativeModel> _getEmbeddingModel() async {
    if (_embeddingModel != null) return _embeddingModel!;

    final prefs = await SharedPreferences.getInstance();
    final modelName =
        prefs.getString('embedding_model') ?? 'gemini-embedding-001';
    _embeddingModel = GenerativeModel(model: modelName, apiKey: _apiKey);
    return _embeddingModel!;
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
    if (texts.isEmpty) return;

    const maxTokensPerMinute = 25000; // Conservative limit (API limit is 30k)
    const maxBatchSize = 500; // Stay under 20MB limit
    
    int tokensUsedThisMinute = 0;
    DateTime minuteStartTime = DateTime.now();
    
    List<String> batchTexts = [];
    List<ContentEntity> batchEntities = [];
    int batchTokenCount = 0;
    
    for (int i = 0; i < texts.length; i++) {
      final estimatedTokens = (texts[i].length / 4).round();
      
      // Check if we need to wait for next minute window
      final now = DateTime.now();
      if (now.difference(minuteStartTime).inMinutes >= 1) {
        // Reset minute window
        tokensUsedThisMinute = 0;
        minuteStartTime = now;
      }
      
      // If adding this batch would exceed minute limit, wait
      if (tokensUsedThisMinute + batchTokenCount + estimatedTokens > maxTokensPerMinute) {
        // Process current batch first if it has items
        if (batchTexts.isNotEmpty) {
          SimpleLogger.log('Processing batch: ${batchTexts.length} items, ~$batchTokenCount tokens');
          await _processBatch(batchTexts, batchEntities);
          tokensUsedThisMinute += batchTokenCount;
          
          // Reset batch
          batchTexts = [];
          batchEntities = [];
          batchTokenCount = 0;
        }
        
        // Wait for next minute window
        final waitTime = 60 - now.difference(minuteStartTime).inSeconds;
        if (waitTime > 0) {
          SimpleLogger.log('Token limit reached. Waiting ${waitTime}s for next minute window...');
          await Future.delayed(Duration(seconds: waitTime));
          tokensUsedThisMinute = 0;
          minuteStartTime = DateTime.now();
        }
      }
      
      // If batch size limit reached, process batch
      if (batchTexts.length >= maxBatchSize) {
        SimpleLogger.log('Processing batch: ${batchTexts.length} items, ~$batchTokenCount tokens');
        await _processBatch(batchTexts, batchEntities);
        tokensUsedThisMinute += batchTokenCount;
        
        // Reset batch
        batchTexts = [];
        batchEntities = [];
        batchTokenCount = 0;
      }
      
      // Add current item to batch
      batchTexts.add(texts[i]);
      batchEntities.add(entities[i]);
      batchTokenCount += estimatedTokens;
    }
    
    // Process final batch if any items remain
    if (batchTexts.isNotEmpty) {
      SimpleLogger.log('Processing final batch: ${batchTexts.length} items, ~$batchTokenCount tokens');
      await _processBatch(batchTexts, batchEntities);
    }
  }
  
  Future<void> _processBatch(
    List<String> texts,
    List<ContentEntity> entities,
  ) async {
    try {
      final model = await _getEmbeddingModel();
      final requests = texts
          .map(
            (text) => EmbedContentRequest(
              Content.text(text),
              taskType: TaskType.retrievalDocument,
            ),
          )
          .toList();
      final response = await model.batchEmbedContents(requests);

      // Assign embeddings to entities
      for (
        int i = 0;
        i < response.embeddings.length && i < entities.length;
        i++
      ) {
        entities[i].embedding = response.embeddings[i].values;
      }

      SimpleLogger.log(
        'Batch embedding completed: ${response.embeddings.length} embeddings generated',
      );
    } catch (e) {
      SimpleLogger.log('Batch embedding failed: $e');

      // Fallback to individual embedding generation
      SimpleLogger.log('Falling back to individual embedding generation...');
      await _generateEmbeddingsIndividually(texts, entities);
    }
  }

  Future<void> _generateEmbeddingsIndividually(
    List<String> texts,
    List<ContentEntity> entities,
  ) async {
    int successCount = 0;
    int failCount = 0;
    bool quotaExceeded = false;
    final maxRequests = await _maxConcurrentRequests;
    final rateLimitDelay = await _rateLimitDelay;

    for (
      int batchStart = 0;
      batchStart < texts.length && !quotaExceeded;
      batchStart += maxRequests
    ) {
      final batchEnd = (batchStart + maxRequests).clamp(0, texts.length);
      final batchTexts = texts.sublist(batchStart, batchEnd);
      final batchEntities = entities.sublist(batchStart, batchEnd);

      final futures = List.generate(
        batchTexts.length,
        (i) => _generateSingleEmbedding(batchTexts[i], batchStart + i),
      );
      final results = await Future.wait(futures, eagerError: false);

      for (int i = 0; i < results.length; i++) {
        final result = results[i];
        if (result.success) {
          batchEntities[i].embedding = result.embedding;
          successCount++;
        } else {
          batchEntities[i].embedding = null;
          failCount++;
          if (result.isQuotaError) {
            quotaExceeded = true;
            break;
          }
        }
      }

      if (batchEnd < texts.length && !quotaExceeded) {
        await Future.delayed(rateLimitDelay);
      }
    }

    SimpleLogger.log(
      'Individual embedding results: $successCount success, $failCount failed',
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
      final model = await _getEmbeddingModel();
      final response = await model.embedContent(
        Content.text(text),
        taskType: TaskType.retrievalDocument,
      );
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
