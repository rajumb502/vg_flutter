import 'package:googleapis/gmail/v1.dart';
import 'package:googleapis_auth/auth_io.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import '../models/content_entity.dart';

class EmailService {
  final String _apiKey;
  late final GenerativeModel _embeddingModel;

  EmailService(this._apiKey) {
    _embeddingModel = GenerativeModel(
      model: 'gemini-embedding-001',
      apiKey: _apiKey,
    );
  }

  Future<List<ContentEntity>> fetchEmails(AuthClient authClient) async {
    final gmail = GmailApi(authClient);
    final messages = await gmail.users.messages.list('me', maxResults: 10);

    final emails = <ContentEntity>[];

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

      // Generate embedding
      final text = '${email.title} ${email.content}';
      final embedding = await _generateEmbedding(text);
      email.embedding = embedding;

      emails.add(email);
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

  Future<List<double>> _generateEmbedding(String text) async {
    try {
      final response = await _embeddingModel.embedContent(Content.text(text));
      return response.embedding.values;
    } catch (e) {
      return List.filled(768, 0.0); // Default embedding size
    }
  }
}
