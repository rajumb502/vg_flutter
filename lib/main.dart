import 'package:flutter/material.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const VoiceGuideApp());
}

final geminiChatModel = 'gemini-2.5-flash';
final geminiEmbeddingModel = 'gemini-embedding-001';

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

  @override
  void initState() {
    super.initState();
    print('initState called');
    _loadApiKey();
  }

  void _loadApiKey() {
    SharedPreferences.getInstance().then((prefs) {
      final apiKey = prefs.getString('gemini_api_key');
      print('Loaded API key: ${apiKey != null ? 'Found' : 'Not found'}');
      if (apiKey != null && apiKey.isNotEmpty) {
        setState(() {
          _apiKey = apiKey;
          _model = GenerativeModel(model: geminiChatModel, apiKey: apiKey);
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

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}
