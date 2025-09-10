import 'package:googleapis/gmail/v1.dart';
import 'package:googleapis_auth/auth_io.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/content_entity.dart';
import 'embedding_service.dart';

class EmailService {
  final String _apiKey;
  late final EmbeddingService _embeddingService;

  EmailService(this._apiKey) {
    _embeddingService = EmbeddingService(_apiKey);
  }

  Future<List<ContentEntity>> fetchEmails(AuthClient authClient) async {
    final gmail = GmailApi(authClient);

    // Get last sync time
    final prefs = await SharedPreferences.getInstance();
    final lastSyncTime = prefs.getInt('gmail_last_sync_time');
    String? query;
    if (lastSyncTime != null) {
      final lastSyncDate = DateTime.fromMillisecondsSinceEpoch(lastSyncTime);
      final dateStr = '${lastSyncDate.year}/${lastSyncDate.month.toString().padLeft(2, '0')}/${lastSyncDate.day.toString().padLeft(2, '0')}';
      query = 'after:$dateStr';
    }

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

      final fullText = '${email.title} ${email.content}';
      final chunkEntities = _embeddingService.createChunkedEntities(email, fullText);
      
      for (final chunkEmail in chunkEntities) {
        textsToEmbed.add(chunkEmail.content);
        emailsForEmbedding.add(chunkEmail);
        emails.add(chunkEmail);
      }
    }

    // Generate embeddings in batches with rate limiting
    await _embeddingService.generateEmbeddingsBatch(textsToEmbed, emailsForEmbedding);

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

}
