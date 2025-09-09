import 'package:flutter/material.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'services/auth_service.dart';
import 'services/email_service.dart';
import 'services/vector_store_factory.dart';
import 'services/vector_store.dart';

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
  late final VectorStore _vectorStore;

  @override
  void initState() {
    super.initState();
    _vectorStore = VectorStoreFactory.getInstance();
    _loadApiKey();
  }

  void _loadApiKey() {
    SharedPreferences.getInstance().then((prefs) {
      final apiKey = prefs.getString('gemini_api_key');
      if (apiKey != null && apiKey.isNotEmpty) {
        setState(() {
          _apiKey = apiKey;
          _model = GenerativeModel(model: geminiChatModel, apiKey: apiKey);
          _emailService = EmailService(apiKey);
        });
        // Check for existing Google authentication
        _authService.checkExistingAuth(googleClientId).then((_) {
          setState(() {}); // Refresh UI if auth state changed
        });
      }
    });
  }

  void _sendMessage() async {
    if (_controller.text.trim().isEmpty) return;
    if (_model == null) {
      _showSettingsDialog();
      return;
    }

    final userMessage = _controller.text;
    _controller.clear();

    setState(() {
      _messages.add('You: $userMessage');
      _isLoading = true;
    });

    try {
      final response = await _model!.generateContent([
        Content.text(
          'You are VoiceGuide, an AI assistant for people with visual disabilities. Help with their goals in a simple, clear way. User says: $userMessage',
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

  void _showSettingsDialog() {
    final apiKeyController = TextEditingController(text: _apiKey ?? '');
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Settings'),
        content: TextField(
          controller: apiKeyController,
          decoration: const InputDecoration(
            labelText: 'Gemini API Key',
            hintText: 'Enter your API key',
          ),
          obscureText: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              final apiKey = apiKeyController.text.trim();
              if (apiKey.isNotEmpty) {
                final prefs = await SharedPreferences.getInstance();
                await prefs.setString('gemini_api_key', apiKey);
                setState(() {
                  _apiKey = apiKey;
                  _model = GenerativeModel(
                    model: geminiChatModel,
                    apiKey: apiKey,
                  );
                  _emailService = EmailService(apiKey);
                });
              }
              Navigator.pop(context);
            },
            child: const Text('Save'),
          ),
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
            IconButton(onPressed: _viewStore, icon: const Icon(Icons.storage)),
            IconButton(
              onPressed: () {
                _authService.signOut();
                setState(() {});
              },
              icon: const Icon(Icons.logout),
            ),
          ],
          IconButton(
            onPressed: _showSettingsDialog,
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
    
    setState(() {
      _messages.add('📦 Vector Store Contents: $count items');
      if (contents.isEmpty) {
        _messages.add('Store is empty. Index some emails first!');
      } else {
        for (final content in contents.take(5)) {
          final hasEmbedding = content.embedding != null && content.embedding!.isNotEmpty;
          _messages.add('📄 ${content.title} (${content.contentType.name}) - Embedding: ${hasEmbedding ? "✅" : "❌"}');
        }
        if (contents.length > 5) {
          _messages.add('... and ${contents.length - 5} more items');
        }
      }
    });
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
      final withEmbeddings = emails.where((e) => e.embedding != null && e.embedding!.isNotEmpty).length;
      final withoutEmbeddings = emails.length - withEmbeddings;
      
      setState(() {
        _messages.add('VoiceGuide: Indexed ${emails.length} emails');
        if (withEmbeddings > 0) {
          _messages.add('✅ $withEmbeddings with embeddings');
        }
        if (withoutEmbeddings > 0) {
          _messages.add('⚠️ $withoutEmbeddings without embeddings (API quota/errors)');
        }
        _messages.add('Total stored: $totalCount items');
        for (final email in emails.take(3)) {
          final hasEmbedding = email.embedding != null && email.embedding!.isNotEmpty;
          _messages.add('📧 ${email.title} from ${email.author} ${hasEmbedding ? "✅" : "⚠️"}');
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

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}
