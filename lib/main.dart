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

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _controller = TextEditingController();
  final List<String> _messages = [];
  GenerativeModel? _model;
  bool _isLoading = false;
  String? _apiKey;

  final AuthService _authService = AuthService();
  EmailService? _emailService;
  DriveService? _driveService;
  late final VectorStore _vectorStore;

  @override
  void initState() {
    super.initState();
    _vectorStore = VectorStoreFactory.getInstance();
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
      _messages.add('You: $userMessage');
      _isLoading = true;
    });

    try {
      // Search for relevant content
      final relevantContent = await _searchRelevantContent(userMessage);

      // Build context from relevant content
      final contextText = relevantContent.isNotEmpty
          ? 'Relevant information from your emails and documents:\n${relevantContent.cast<ContentEntity>().map((c) => '- ${c.title}: ${c.content.substring(0, 200)}...').join('\n')}\n\n'
          : '';

      final response = await _model!.generateContent([
        Content.text(
          '${contextText}You are VoiceGuide, an AI assistant for people with visual disabilities. Help with their goals in a simple, clear way. User says: $userMessage',
        ),
      ]);

      setState(() {
        _messages.add(
          'VoiceGuide: ${response.text ?? "I'm sorry, I couldn't process that."}',
        );
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _messages.add(
          'VoiceGuide: Sorry, I encountered an error. Please try again.',
        );
        _isLoading = false;
      });
    }
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
                  _messages.add('VoiceGuide: Connected to Google services!');
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
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(
                    _messages[index],
                    style: const TextStyle(fontSize: 16),
                  ),
                );
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
    final contents = await _vectorStore.getAllContents();
    final count = await _vectorStore.count;
    final withEmbeddings = contents.where((c) => c.embedding != null && c.embedding!.isNotEmpty).length;
    final withoutEmbeddings = contents.where((c) => c.embedding == null || c.embedding!.isEmpty).toList();

    setState(() {
      _messages.add('📦 Vector Store Contents: $count items');
      _messages.add('✅ With embeddings: $withEmbeddings');
      _messages.add('❌ Without embeddings: ${withoutEmbeddings.length}');
      
      if (contents.isEmpty) {
        _messages.add('Store is empty. Index some emails first!');
      } else {
        _messages.add('\n--- Sample Contents ---');
        for (final content in contents.take(5)) {
          final hasEmbedding = content.embedding != null && content.embedding!.isNotEmpty;
          _messages.add('📄 ${content.title} (${content.contentType.name}) - ${hasEmbedding ? "✅" : "❌"}');
        }
        if (contents.length > 5) {
          _messages.add('... and ${contents.length - 5} more items');
        }
        
        if (withoutEmbeddings.isNotEmpty) {
          _messages.add('\n--- Missing Embeddings (with sizes) ---');
          for (final content in withoutEmbeddings.take(10)) {
            final sizeKB = (content.content.length / 1024).toStringAsFixed(1);
            final tokens = (content.content.length / 4).round(); // Rough estimate: 4 chars per token
            _messages.add('❌ ${content.title}: ${sizeKB}KB (~$tokens tokens)');
          }
          if (withoutEmbeddings.length > 10) {
            _messages.add('... and ${withoutEmbeddings.length - 10} more without embeddings');
          }
        }
      }
    });
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
          'VoiceGuide: Please sign in first and ensure API key is set.',
        );
      });
      return;
    }

    setState(() {
      _messages.add(
        forceReindex
            ? 'VoiceGuide: Force re-indexing all Drive files...'
            : 'VoiceGuide: Indexing Drive files...',
      );
      _isLoading = true;
    });

    try {
      setState(() {
        _messages.add('VoiceGuide: Fetching file list from Drive...');
      });

      final documents = await _driveService!.fetchDriveFiles(
        _authService.authClient!,
        forceReindex: forceReindex,
      );

      setState(() {
        _messages.add('VoiceGuide: Found ${documents.length} files to process');
      });

      if (documents.isEmpty) {
        setState(() {
          _messages.add('VoiceGuide: No new files found since last sync');
          _isLoading = false;
        });
        return;
      }

      await _vectorStore.addContents(documents);
      final totalCount = await _vectorStore.count;

      setState(() {
        _messages.add('VoiceGuide: Indexed ${documents.length} Drive files');
        _messages.add('Total stored: $totalCount items');
        for (final doc in documents.take(3)) {
          _messages.add('📄 ${doc.title}');
        }
        _messages.add('Starting background embedding generation...');
        _isLoading = false;
      });

      // Start background embedding generation
      _generateMissingEmbeddings();
    } catch (e) {
      setState(() {
        _messages.add('VoiceGuide: Error indexing Drive files: $e');
        _isLoading = false;
      });
    }
  }

  void _indexEmails() async {
    if (_emailService == null || _authService.authClient == null) {
      setState(() {
        _messages.add(
          'VoiceGuide: Please sign in first and ensure API key is set.',
        );
      });
      return;
    }

    setState(() {
      _messages.add('VoiceGuide: Indexing emails...');
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

      setState(() {
        _messages.add('VoiceGuide: Indexed ${emails.length} emails');
        if (withEmbeddings > 0) {
          _messages.add('✅ $withEmbeddings with embeddings');
        }
        if (withoutEmbeddings > 0) {
          _messages.add(
            '⚠️ $withoutEmbeddings without embeddings (API quota/errors)',
          );
        }
        _messages.add('Total stored: $totalCount items');
        for (final email in emails.take(3)) {
          final hasEmbedding =
              email.embedding != null && email.embedding!.isNotEmpty;
          _messages.add(
            '📧 ${email.title} from ${email.author} ${hasEmbedding ? "✅" : "⚠️"}',
          );
        }
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _messages.add('VoiceGuide: Error indexing emails: $e');
        _isLoading = false;
      });
    }
  }

  Future<List<ContentEntity>> _searchRelevantContent(String query) async {
    if (_emailService == null) return [];

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

      // Search vector store for similar content
      final results = await _vectorStore.searchSimilar(
        queryEmbedding.embedding.values,
        limit: 3,
      );

      return results;
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
          _messages.add('✅ All content already has embeddings');
        });
        return;
      }

      setState(() {
        _messages.add(
          '🔄 Generating embeddings for ${missingEmbeddings.length} items...',
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

      setState(() {
        _messages.add('✅ Generated embeddings for $withEmbeddings items');
        if (withEmbeddings < missingEmbeddings.length) {
          _messages.add(
            '⚠️ ${missingEmbeddings.length - withEmbeddings} items still missing embeddings (quota limits)',
          );
        }
      });
    } catch (e) {
      setState(() {
        _messages.add('❌ Background embedding generation failed: $e');
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}
