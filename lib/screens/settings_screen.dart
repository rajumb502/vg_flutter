import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _rateLimitController = TextEditingController();
  final _maxRequestsController = TextEditingController();
  final _maxFileSizeController = TextEditingController();
  final _apiKeyController = TextEditingController();
  final _chatModelController = TextEditingController();
  final _embeddingModelController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _rateLimitController.text = (prefs.getInt('rate_limit_seconds') ?? 15).toString();
    _maxRequestsController.text = (prefs.getInt('max_concurrent_requests') ?? 3).toString();
    _maxFileSizeController.text = (prefs.getInt('max_file_size_mb') ?? 2).toString();
    _apiKeyController.text = prefs.getString('google_api_key') ?? '';
    _chatModelController.text = prefs.getString('chat_model') ?? 'gemini-2.5-flash';
    _embeddingModelController.text = prefs.getString('embedding_model') ?? 'gemini-embedding-001';
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('rate_limit_seconds', int.tryParse(_rateLimitController.text) ?? 15);
    await prefs.setInt('max_concurrent_requests', int.tryParse(_maxRequestsController.text) ?? 3);
    await prefs.setInt('max_file_size_mb', int.tryParse(_maxFileSizeController.text) ?? 2);
    await prefs.setString('google_api_key', _apiKeyController.text.trim());
    await prefs.setString('chat_model', _chatModelController.text.trim());
    await prefs.setString('embedding_model', _embeddingModelController.text.trim());
    
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Settings saved')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            TextField(
              controller: _apiKeyController,
              decoration: const InputDecoration(
                labelText: 'Google API Key',
                helperText: 'Your Google Gemini API key',
              ),
              obscureText: true,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _rateLimitController,
              decoration: const InputDecoration(
                labelText: 'Rate Limit (seconds)',
                helperText: 'Delay between API requests',
              ),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _maxRequestsController,
              decoration: const InputDecoration(
                labelText: 'Max Concurrent Requests',
                helperText: 'Number of parallel embedding requests',
              ),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _maxFileSizeController,
              decoration: const InputDecoration(
                labelText: 'Max File Size (MB)',
                helperText: 'Skip files larger than this size',
              ),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _chatModelController,
              decoration: const InputDecoration(
                labelText: 'Chat Model',
                helperText: 'Gemini model for chat responses',
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _embeddingModelController,
              decoration: const InputDecoration(
                labelText: 'Embedding Model',
                helperText: 'Gemini model for text embeddings',
              ),
            ),
            const SizedBox(height: 32),
            ElevatedButton(
              onPressed: _saveSettings,
              child: const Text('Save Settings'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _rateLimitController.dispose();
    _maxRequestsController.dispose();
    _maxFileSizeController.dispose();
    _apiKeyController.dispose();
    _chatModelController.dispose();
    _embeddingModelController.dispose();
    super.dispose();
  }
}