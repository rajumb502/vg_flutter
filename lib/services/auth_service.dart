import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis_auth/googleapis_auth.dart'
    as auth
    show AuthClient, AccessCredentials, AccessToken;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'simple_logger.dart';

class AuthService {
  static const _scopes = [
    'https://www.googleapis.com/auth/gmail.readonly',
    'https://www.googleapis.com/auth/calendar.readonly',
    'https://www.googleapis.com/auth/drive.readonly',
  ];

  GoogleSignIn? _googleSignIn;
  auth.AuthClient? _authClient;
  GoogleSignInAccount? _currentUser;
  String? _clientId;

  auth.AuthClient? get authClient => _authClient;
  bool get isAuthenticated => _currentUser != null;

  Future<void> checkExistingAuth(String clientId) async {
    _clientId = clientId;
    _googleSignIn ??= GoogleSignIn(clientId: clientId, scopes: _scopes);

    // Check stored auth state first
    final prefs = await SharedPreferences.getInstance();
    final isSignedIn = prefs.getBool('google_signed_in') ?? false;
    
    if (!isSignedIn) {
      SimpleLogger.log('No stored auth state found');
      return;
    }

    try {
      _currentUser = await _googleSignIn!.signInSilently();
      if (_currentUser != null) {
        SimpleLogger.log('Restored user: ${_currentUser!.email}');
        final authHeaders = await _currentUser!.authHeaders;
        _authClient = _AuthenticatedClient(authHeaders);
      } else {
        // Clear stored state if silent sign-in fails
        await prefs.setBool('google_signed_in', false);
        SimpleLogger.log('Failed to restore user, cleared stored state');
      }
    } catch (e) {
      await prefs.setBool('google_signed_in', false);
      SimpleLogger.log('Silent sign-in failed: $e');
    }
  }

  Future<bool> signIn(String clientId) async {
    _clientId = clientId;
    _googleSignIn ??= GoogleSignIn(clientId: clientId, scopes: _scopes);
    try {
      _currentUser = await _googleSignIn!.signIn();

      if (_currentUser != null) {
        final authHeaders = await _currentUser!.authHeaders;
        _authClient = _AuthenticatedClient(authHeaders);
        
        // Store auth state
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('google_signed_in', true);
        
        return true;
      }
      return false;
    } catch (e) {
      SimpleLogger.log('Auth error: $e');
      return false;
    }
  }

  void signOut() async {
    _googleSignIn?.signOut();
    _authClient?.close();
    _authClient = null;
    _currentUser = null;
    
    // Clear stored auth state
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('google_signed_in', false);
  }
}

class _AuthenticatedClient extends http.BaseClient implements auth.AuthClient {
  final Map<String, String> _headers;
  final http.Client _client = http.Client();
  final auth.AccessCredentials _credentials;

  _AuthenticatedClient(this._headers)
    : _credentials = auth.AccessCredentials(
        auth.AccessToken(
          'Bearer',
          _headers['Authorization']?.replaceFirst('Bearer ', '') ?? '',
          DateTime.now().toUtc().add(Duration(hours: 1)),
        ),
        null,
        [],
      );

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers.addAll(_headers);
    return _client.send(request);
  }

  @override
  void close() {
    _client.close();
  }

  @override
  auth.AccessCredentials get credentials => _credentials;
}
