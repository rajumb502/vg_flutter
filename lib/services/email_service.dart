import 'package:googleapis/gmail/v1.dart';
import 'package:googleapis_auth/auth_io.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/content_entity.dart';

class EmailService {
  final String _apiKey;
  late final GenerativeModel _embeddingModel;
  static const int _maxContentLength = 30000; // ~30KB to stay under 36KB limit
  static const Duration _rateLimitDelay = Duration(
    seconds: 15,
  ); // Conservative rate limit
  static const int _maxConcurrentRequests =
      5; // batch process of 5 emails at a time

  EmailService(this._apiKey) {
    _embeddingModel = GenerativeModel(
      model: 'gemini-embedding-001',
      apiKey: _apiKey,
    );
  }

  Future<List<ContentEntity>> fetchEmails(AuthClient authClient) async {
    final gmail = GmailApi(authClient);

    // Get last sync time
    final prefs = await SharedPreferences.getInstance();
    final lastSyncTime = prefs.getInt('gmail_last_sync_time');
    final query = lastSyncTime != null ? 'after:${lastSyncTime ~/ 1000}' : null;

    final messages = await gmail.users.messages.list(
      'me',
      maxResults: 50,
      q: query,
    );

    final emails = <ContentEntity>[];
    final textsToEmbed = <String>[];
    final emailsForEmbedding = <ContentEntity>[];

    // Process emails and collect texts for batch embedding
    for (final message in messages.messages ?? []) {
      final fullMessage = await gmail.users.messages.get('me', message.id!);

      final email = ContentEntity.create(
        sourceId: fullMessage.id!,
        title: _getHeader(fullMessage, 'Subject') ?? 'No Subject',
        author: _getHeader(fullMessage, 'From') ?? 'Unknown',
        content: _extractBody(fullMessage),
        createdDate: DateTime.fromMillisecondsSinceEpoch(
          int.parse(fullMessage.internalDate ?? '0'),
        ),
        contentType: ContentType.email,
      );

      // Truncate content if too large
      final text = _truncateText('${email.title} ${email.content}');
      textsToEmbed.add(text);
      emailsForEmbedding.add(email);
      emails.add(email);
    }

    // Generate embeddings in batches with rate limiting
    await _generateEmbeddingsBatch(textsToEmbed, emailsForEmbedding);

    // Update last sync time
    if (emails.isNotEmpty) {
      final latestTime = emails
          .map((e) => e.createdDate.millisecondsSinceEpoch)
          .reduce((a, b) => a > b ? a : b);
      await prefs.setInt('gmail_last_sync_time', latestTime);
    }

    return emails;
  }

  String? _getHeader(Message message, String name) {
    final headers = message.payload?.headers ?? [];
    for (final header in headers) {
      if (header.name?.toLowerCase() == name.toLowerCase()) {
        return header.value;
      }
    }
    return null;
  }

  String _extractBody(Message message) {
    final payload = message.payload;
    if (payload?.body?.data != null) {
      return payload!.body!.data!;
    }

    final parts = payload?.parts ?? [];
    for (final part in parts) {
      if (part.mimeType == 'text/plain' && part.body?.data != null) {
        return part.body!.data!;
      }
    }

    return 'No content';
  }

  String _truncateText(String text) {
    if (text.length <= _maxContentLength) return text;

    // Truncate and add indicator
    return '${text.substring(0, _maxContentLength)}... [truncated]';
  }

  Future<void> _generateEmbeddingsBatch(
    List<String> texts,
    List<ContentEntity> emails,
  ) async {
    int successCount = 0;
    int failCount = 0;
    bool quotaExceeded = false;

    // Process in smaller batches with controlled concurrency
    for (
      int batchStart = 0;
      batchStart < texts.length && !quotaExceeded;
      batchStart += _maxConcurrentRequests
    ) {
      final batchEnd = (batchStart + _maxConcurrentRequests).clamp(
        0,
        texts.length,
      );
      final batchIndices = List.generate(
        batchEnd - batchStart,
        (i) => batchStart + i,
      );

      // Process batch concurrently
      final futures = batchIndices.map(
        (i) => _generateSingleEmbedding(texts[i], i),
      );
      final results = await Future.wait(futures, eagerError: false);

      // Process results
      for (int j = 0; j < results.length; j++) {
        final i = batchIndices[j];
        final result = results[j];

        if (result.success) {
          emails[i].embedding = result.embedding;
          successCount++;
        } else {
          emails[i].embedding = null;
          failCount++;

          if (result.isQuotaError) {
            print('Quota exceeded, stopping embedding generation');
            quotaExceeded = true;
            break;
          }
        }
      }

      // Rate limiting between batches
      if (batchEnd < texts.length && !quotaExceeded) {
        await Future.delayed(_rateLimitDelay);
      }
    }

    print('Embedding results: $successCount success, $failCount failed');
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
      print('Embedding error for email $index: $e');
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
