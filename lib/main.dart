import 'package:flutter/material.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vg_flutter/services/simple_logger.dart';
import 'services/auth_service.dart';
import 'services/email_service.dart';
import 'services/drive_service.dart';
import 'services/vector_store_factory.dart';
import 'services/vector_store.dart';
import 'screens/settings_screen.dart';
import 'models/content_entity.dart';
import 'services/embedding_service.dart';

void main() {
  runApp(const VoiceGuideApp());
}

const geminiChatModel = 'gemini-2.5-flash';
const geminiEmbeddingModel = 'gemini-embedding-001';
const googleClientId =
    '734081178634-59heofe6sep82c3qvnf1kbkaic94bu4q.apps.googleusercontent.com'; // Replace with your actual client ID

class VoiceGuideApp extends StatelessWidget {
  const VoiceGuideApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VoiceGuide',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        textTheme: const TextTheme(
          bodyLarge: TextStyle(fontSize: 18),
          bodyMedium: TextStyle(fontSize: 16),
        ),
      ),
      home: const ChatScreen(),
    );
  }
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

enum MessageType { userQuery, llmResponse, systemMessage }

class ChatMessage {
  final String content;
  final bool isUser;
  final MessageType type;
  final DateTime timestamp;

  ChatMessage({
    required this.content,
    required this.isUser,
    required this.type,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _controller = TextEditingController();
  final List<ChatMessage> _messages = [];
  GenerativeModel? _model;
  bool _isLoading = false;
  String? _apiKey;

  final AuthService _authService = AuthService();
  EmailService? _emailService;
  DriveService? _driveService;
  late final VectorStore _vectorStore;

  String _sessionId = '';
  int _conversationCount = 0;

  @override
  void initState() {
    super.initState();
    _vectorStore = VectorStoreFactory.getInstance();
    _sessionId = DateTime.now().millisecondsSinceEpoch.toString();
    _loadApiKey();
    _checkExistingAuth();
  }

  void _checkExistingAuth() async {
    await _authService.checkExistingAuth(googleClientId);
    SimpleLogger.log(
      'Auth check complete. Authenticated: ${_authService.isAuthenticated}',
    );
    setState(() {}); // Refresh UI with auth state
  }

  void _loadApiKey() {
    SharedPreferences.getInstance().then((prefs) {
      final apiKey = prefs.getString('google_api_key');
      if (apiKey != null && apiKey.isNotEmpty) {
        final chatModel = prefs.getString('chat_model') ?? geminiChatModel;
        setState(() {
          _apiKey = apiKey;
          _model = GenerativeModel(model: chatModel, apiKey: apiKey);
          _emailService = EmailService(apiKey);
          _driveService = DriveService(apiKey);
        });
      }
    });
  }

  void _sendMessage() async {
    if (_controller.text.trim().isEmpty) return;
    if (_model == null) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (context) => const SettingsScreen()),
      ).then((_) => _loadApiKey());
      return;
    }

    final userMessage = _controller.text;
    _controller.clear();

    setState(() {
      _messages.add(
        ChatMessage(
          content: userMessage,
          isUser: true,
          type: MessageType.userQuery,
        ),
      );
      _isLoading = true;
    });

    try {
      // Search for relevant content
      final relevantContent = await _searchRelevantContent(userMessage);

      // Build context from relevant content
      final contextText = relevantContent.isNotEmpty
          ? 'Relevant information from your emails and documents:\n${relevantContent.cast<ContentEntity>().map((c) => '- ${c.title}: ${_extractRelevantPortion(c.content, userMessage)}...').join('\n')}\n\n'
          : '';

      // Build conversation context from recent messages
      final conversationMessages = _messages
          .where((m) => m.type != MessageType.systemMessage)
          .toList();
      final recentMessages = conversationMessages.length > 6
          ? conversationMessages.skip(conversationMessages.length - 6)
          : conversationMessages;
      final conversationContext = recentMessages
          .map((m) => '${m.isUser ? "User" : "VoiceGuide"}: ${m.content}')
          .join('\n');

      final contextPrefix = conversationContext.isNotEmpty
          ? 'Recent conversation:\n$conversationContext\n\n'
          : '';

      final response = await _model!.generateContent([
        Content.text(
          '$contextText${contextPrefix}You are VoiceGuide, an AI assistant for people with visual disabilities. Help with their goals in a simple, clear way. Maintain conversation context and refer to previous exchanges when relevant. User says: $userMessage',
        ),
      ]);

      final aiResponse = response.text ?? "I'm sorry, I couldn't process that.";

      setState(() {
        _messages.add(
          ChatMessage(
            content: aiResponse,
            isUser: false,
            type: MessageType.llmResponse,
          ),
        );
        _isLoading = false;
      });

      // Store conversation pair
      _saveConversationPair(userMessage, aiResponse);
    } catch (e) {
      const errorResponse = 'Sorry, I encountered an error. Please try again.';

      setState(() {
        _messages.add(
          ChatMessage(
            content: errorResponse,
            isUser: false,
            type: MessageType.llmResponse,
          ),
        );
        _isLoading = false;
      });

      // Store conversation pair even for errors
      _saveConversationPair(userMessage, errorResponse);
    }
  }

  Widget _buildChatBubble(ChatMessage message) {
    if (message.type == MessageType.systemMessage) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 16),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.orange[100],
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              message.content,
              style: TextStyle(fontSize: 14, color: Colors.orange[800]),
              textAlign: TextAlign.left,
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      child: Row(
        mainAxisAlignment: message.isUser
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        children: [
          if (!message.isUser) ...[
            const CircleAvatar(
              radius: 16,
              backgroundColor: Colors.blue,
              child: Icon(Icons.smart_toy, color: Colors.white, size: 16),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.75,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: message.isUser ? Colors.blue[600] : Colors.grey[200],
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                message.content,
                style: TextStyle(
                  fontSize: 16,
                  color: message.isUser ? Colors.white : Colors.black87,
                ),
              ),
            ),
          ),
          if (message.isUser) ...[
            const SizedBox(width: 8),
            const CircleAvatar(
              radius: 16,
              backgroundColor: Colors.green,
              child: Icon(Icons.person, color: Colors.white, size: 16),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('VoiceGuide Chat'),
        actions: [
          // Vector store button - always visible (local content)
          IconButton(onPressed: _viewStore, icon: const Icon(Icons.storage)),

          if (!_authService.isAuthenticated)
            IconButton(
              onPressed: () async {
                final success = await _authService.signIn(googleClientId);
                if (success) {
                  setState(() {});
                  _messages.add(
                    ChatMessage(
                      content: 'Connected to Google services!',
                      isUser: false,
                      type: MessageType.systemMessage,
                    ),
                  );
                }
              },
              icon: const Icon(Icons.login),
            ),
          if (_authService.isAuthenticated) ...[
            IconButton(onPressed: _indexEmails, icon: const Icon(Icons.email)),
            PopupMenuButton<String>(
              icon: const Icon(Icons.folder),
              onSelected: (value) {
                if (value == 'index') _indexDrive();
                if (value == 'force') _indexDriveForce();
              },
              itemBuilder: (context) => [
                const PopupMenuItem(value: 'index', child: Text('Index Drive')),
                const PopupMenuItem(
                  value: 'force',
                  child: Text('Force Re-index'),
                ),
              ],
            ),
            IconButton(
              onPressed: () {
                _authService.signOut();
                setState(() {});
              },
              icon: const Icon(Icons.logout),
            ),
          ],

          // Generate embeddings button - visible when API key is set
          if (_apiKey != null)
            IconButton(
              onPressed: _generateMissingEmbeddings,
              icon: const Icon(Icons.auto_fix_high),
            ),

          IconButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => const SettingsScreen()),
            ).then((_) => _loadApiKey()),
            icon: const Icon(Icons.settings),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final message = _messages[index];
                return _buildChatBubble(message);
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    decoration: const InputDecoration(
                      hintText: 'Type your message...',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _sendMessage(),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _isLoading ? null : _sendMessage,
                  child: _isLoading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Send'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _viewStore() async {
    try {
      final contents = await _vectorStore.getAllContents();

      final count = await _vectorStore.count;
      final withEmbeddings = contents
          .where((c) => c.embedding != null && c.embedding!.isNotEmpty)
          .length;
      final withoutEmbeddings = contents
          .where((c) => c.embedding == null || c.embedding!.isEmpty)
          .toList();

      final storeInfo = StringBuffer();
      storeInfo.writeln('📦 Vector Store Contents: $count items');
      storeInfo.writeln('✅ With embeddings: $withEmbeddings');
      storeInfo.writeln('❌ Without embeddings: ${withoutEmbeddings.length}');

      if (contents.isEmpty) {
        storeInfo.writeln('Store is empty. Index some emails first!');
      } else {
        storeInfo.writeln('\n--- Sample Contents ---');
        for (final content in contents.take(5)) {
          final hasEmbedding =
              content.embedding != null && content.embedding!.isNotEmpty;
          final title = content.title;
          final contentType = content.contentType.name;
          storeInfo.writeln(
            '📄 $title ($contentType) - ${hasEmbedding ? "✅" : "❌"}',
          );
        }
        if (contents.length > 5) {
          storeInfo.writeln('... and ${contents.length - 5} more items');
        }

        if (withoutEmbeddings.isNotEmpty) {
          storeInfo.writeln('\n--- Missing Embeddings (with sizes) ---');
          for (final content in withoutEmbeddings.take(10)) {
            final contentText = content.content;
            final sizeKB = (contentText.length / 1024).toStringAsFixed(1);
            final tokens = (contentText.length / 3).round();
            final title = content.title;
            storeInfo.writeln('❌ $title: ${sizeKB}KB (~$tokens tokens)');
          }
          if (withoutEmbeddings.length > 10) {
            storeInfo.writeln(
              '... and ${withoutEmbeddings.length - 10} more without embeddings',
            );
          }
        }
      }

      setState(() {
        _messages.add(
          ChatMessage(
            content: storeInfo.toString(),
            isUser: false,
            type: MessageType.systemMessage,
          ),
        );
      });
    } catch (e) {
      setState(() {
        _messages.add(
          ChatMessage(
            content: 'Error viewing store: $e',
            isUser: false,
            type: MessageType.systemMessage,
          ),
        );
      });
    }
  }

  void _indexDriveForce() async {
    _indexDriveInternal(forceReindex: true);
  }

  void _indexDrive() async {
    _indexDriveInternal(forceReindex: false);
  }

  void _indexDriveInternal({required bool forceReindex}) async {
    if (_driveService == null || _authService.authClient == null) {
      setState(() {
        _messages.add(
          ChatMessage(
            content: 'Please sign in first and ensure API key is set.',
            isUser: false,
            type: MessageType.systemMessage,
          ),
        );
      });
      return;
    }

    setState(() {
      _messages.add(
        ChatMessage(
          content: forceReindex
              ? 'Force re-indexing all Drive files...'
              : 'Indexing Drive files...',
          isUser: false,
          type: MessageType.systemMessage,
        ),
      );
      _isLoading = true;
    });

    try {
      setState(() {
        _messages.add(
          ChatMessage(
            content: 'Fetching file list from Drive...',
            isUser: false,
            type: MessageType.systemMessage,
          ),
        );
      });

      final documents = await _driveService!.fetchDriveFiles(
        _authService.authClient!,
        forceReindex: forceReindex,
      );

      setState(() {
        _messages.add(
          ChatMessage(
            content: 'Found ${documents.length} files to process',
            isUser: false,
            type: MessageType.systemMessage,
          ),
        );
      });

      if (documents.isEmpty) {
        setState(() {
          _messages.add(
            ChatMessage(
              content: 'No new files found since last sync',
              isUser: false,
              type: MessageType.systemMessage,
            ),
          );
          _isLoading = false;
        });
        return;
      }

      await _vectorStore.addContents(documents);
      final totalCount = await _vectorStore.count;

      final indexInfo = StringBuffer();
      indexInfo.writeln('Indexed ${documents.length} Drive files');
      indexInfo.writeln('Total stored: $totalCount items');
      for (final doc in documents.take(3)) {
        indexInfo.writeln('📄 ${doc.title}');
      }
      indexInfo.writeln('Starting background embedding generation...');

      setState(() {
        _messages.add(
          ChatMessage(
            content: indexInfo.toString(),
            isUser: false,
            type: MessageType.systemMessage,
          ),
        );
        _isLoading = false;
      });

      // Start background embedding generation
      _generateMissingEmbeddings();
    } catch (e) {
      setState(() {
        _messages.add(
          ChatMessage(
            content: 'Error indexing Drive files: $e',
            isUser: false,
            type: MessageType.systemMessage,
          ),
        );
        _isLoading = false;
      });
    }
  }

  void _indexEmails() async {
    if (_emailService == null || _authService.authClient == null) {
      setState(() {
        _messages.add(
          ChatMessage(
            content: 'Please sign in first and ensure API key is set.',
            isUser: false,
            type: MessageType.systemMessage,
          ),
        );
      });
      return;
    }

    setState(() {
      _messages.add(
        ChatMessage(
          content: 'Indexing emails...',
          isUser: false,
          type: MessageType.systemMessage,
        ),
      );
      _isLoading = true;
    });

    try {
      final emails = await _emailService!.fetchEmails(_authService.authClient!);

      // Always store emails, even if embeddings failed
      await _vectorStore.addContents(emails);
      final totalCount = await _vectorStore.count;

      // Count how many have embeddings
      final withEmbeddings = emails
          .where((e) => e.embedding != null && e.embedding!.isNotEmpty)
          .length;
      final withoutEmbeddings = emails.length - withEmbeddings;

      final emailInfo = StringBuffer();
      emailInfo.writeln('Indexed ${emails.length} emails');
      if (withEmbeddings > 0) {
        emailInfo.writeln('✅ $withEmbeddings with embeddings');
      }
      if (withoutEmbeddings > 0) {
        emailInfo.writeln(
          '⚠️ $withoutEmbeddings without embeddings (API quota/errors)',
        );
      }
      emailInfo.writeln('Total stored: $totalCount items');
      for (final email in emails.take(3)) {
        final hasEmbedding =
            email.embedding != null && email.embedding!.isNotEmpty;
        emailInfo.writeln(
          '📧 ${email.title} from ${email.author} ${hasEmbedding ? "✅" : "⚠️"}',
        );
      }

      setState(() {
        _messages.add(
          ChatMessage(
            content: emailInfo.toString(),
            isUser: false,
            type: MessageType.systemMessage,
          ),
        );
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _messages.add(
          ChatMessage(
            content: 'Error indexing emails: $e',
            isUser: false,
            type: MessageType.systemMessage,
          ),
        );
        _isLoading = false;
      });
    }
  }

  Future<List<ContentEntity>> _searchRelevantContent(String query) async {
    if (_apiKey == null) return [];

    try {
      // Generate embedding for the user query
      final prefs = await SharedPreferences.getInstance();
      final embeddingModel =
          prefs.getString('embedding_model') ?? 'gemini-embedding-001';
      final model = GenerativeModel(model: embeddingModel, apiKey: _apiKey!);

      final queryEmbedding = await model.embedContent(
        Content.text(query),
        taskType: TaskType.retrievalQuery,
      );

      // Search vector store for similar content (including chat history)
      final results = await _vectorStore.searchSimilar(
        queryEmbedding.embedding.values,
        limit: 5, // Increased to include chat history
      );

      // Prioritize recent chat history for context
      final chatHistory = results
          .where((r) => r.contentType == ContentType.chatHistory)
          .take(2)
          .toList();
      final otherContent = results
          .where((r) => r.contentType != ContentType.chatHistory)
          .take(3)
          .toList();

      return [...chatHistory, ...otherContent];
    } catch (e) {
      SimpleLogger.log('Error searching content: $e');
      return [];
    }
  }

  void _generateMissingEmbeddings() async {
    try {
      final allContents = await _vectorStore.getAllContents();
      final missingEmbeddings = allContents
          .where((c) => c.embedding == null || c.embedding!.isEmpty)
          .toList();

      if (missingEmbeddings.isEmpty) {
        setState(() {
          _messages.add(
            ChatMessage(
              content: '✅ All content already has embeddings',
              isUser: false,
              type: MessageType.systemMessage,
            ),
          );
        });
        return;
      }

      setState(() {
        _messages.add(
          ChatMessage(
            content:
                '🔄 Generating embeddings for ${missingEmbeddings.length} items...',
            isUser: false,
            type: MessageType.systemMessage,
          ),
        );
      });

      // Content is already chunked from Drive service, so just use it directly
      final textsToEmbed = missingEmbeddings.map((e) => e.content).toList();
      final embeddingService = EmbeddingService(_apiKey!);

      await embeddingService.generateEmbeddingsBatch(
        textsToEmbed,
        missingEmbeddings,
      );

      // Update the vector store with new embeddings
      await _vectorStore.addContents(missingEmbeddings);

      final withEmbeddings = missingEmbeddings
          .where((e) => e.embedding != null && e.embedding!.isNotEmpty)
          .length;

      final embeddingInfo = StringBuffer();
      embeddingInfo.writeln('✅ Generated embeddings for $withEmbeddings items');
      if (withEmbeddings < missingEmbeddings.length) {
        embeddingInfo.writeln(
          '⚠️ ${missingEmbeddings.length - withEmbeddings} items still missing embeddings (quota limits)',
        );
      }

      setState(() {
        _messages.add(
          ChatMessage(
            content: embeddingInfo.toString(),
            isUser: false,
            type: MessageType.systemMessage,
          ),
        );
      });
    } catch (e) {
      setState(() {
        _messages.add(
          ChatMessage(
            content: '❌ Background embedding generation failed: $e',
            isUser: false,
            type: MessageType.systemMessage,
          ),
        );
      });
    }
  }

  String _extractRelevantPortion(String content, String query) {
    const maxTokens = 500; // ~1500 characters at 3 chars per token
    const maxChars = maxTokens * 3;

    if (content.length <= maxChars) return content;

    // Find query words in content
    final queryWords = query
        .toLowerCase()
        .split(' ')
        .where((w) => w.length > 2)
        .toList();
    final contentLower = content.toLowerCase();

    int bestStart = 0;
    int maxMatches = 0;

    // Sliding window to find portion with most query word matches
    for (int i = 0; i <= content.length - maxChars; i += 100) {
      final window = contentLower.substring(
        i,
        (i + maxChars).clamp(0, content.length),
      );
      int matches = 0;

      for (final word in queryWords) {
        if (window.contains(word)) matches++;
      }

      if (matches > maxMatches) {
        maxMatches = matches;
        bestStart = i;
      }
    }

    // Extract the most relevant portion
    final endPos = (bestStart + maxChars).clamp(0, content.length);
    return content.substring(bestStart, endPos);
  }

  void _saveConversationPair(String userQuery, String aiResponse) async {
    try {
      // Generate summary for better search
      final summary = await _generateConversationSummary(userQuery, aiResponse);

      final chatEntity = ContentEntity.create(
        sourceId: '${_sessionId}_${_conversationCount++}',
        title:
            'Chat: ${userQuery.length > 50 ? '${userQuery.substring(0, 50)}...' : userQuery}',
        content: summary,
        createdDate: DateTime.now(),
        contentType: ContentType.chatHistory,
      );

      await _vectorStore.addContents([chatEntity]);
    } catch (e) {
      // Fallback: store raw conversation if summary fails
      final conversationContent = 'User: $userQuery\n\nVoiceGuide: $aiResponse';

      final chatEntity = ContentEntity.create(
        sourceId: '${_sessionId}_${_conversationCount++}',
        title:
            'Chat: ${userQuery.length > 50 ? '${userQuery.substring(0, 50)}...' : userQuery}',
        content: conversationContent,
        createdDate: DateTime.now(),
        contentType: ContentType.chatHistory,
      );

      await _vectorStore.addContents([chatEntity]);
    }
  }

  Future<String> _generateConversationSummary(
    String userQuery,
    String aiResponse,
  ) async {
    if (_model == null) {
      return 'User asked: $userQuery\nTopic: ${_extractKeyTopics(userQuery, aiResponse)}';
    }

    try {
      final summaryPrompt =
          'Summarize this conversation in 2-3 sentences focusing on the user\'s goal and key information provided:\n\nUser: $userQuery\n\nAssistant: $aiResponse';

      final response = await _model!.generateContent([
        Content.text(summaryPrompt),
      ]);
      return response.text ??
          'User asked: $userQuery\nTopic: ${_extractKeyTopics(userQuery, aiResponse)}';
    } catch (e) {
      return 'User asked: $userQuery\nTopic: ${_extractKeyTopics(userQuery, aiResponse)}';
    }
  }

  String _extractKeyTopics(String userQuery, String aiResponse) {
    final combined = '$userQuery $aiResponse'.toLowerCase();
    final keywords = [
      'job',
      'email',
      'document',
      'file',
      'search',
      'help',
      'find',
      'create',
      'write',
      'read',
    ];
    final foundTopics = keywords
        .where((k) => combined.contains(k))
        .take(3)
        .join(', ');
    return foundTopics.isNotEmpty ? foundTopics : 'general assistance';
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}
