import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis_auth/googleapis_auth.dart' as auth show AuthClient, AccessCredentials, AccessToken;
import 'package:http/http.dart' as http;

class AuthService {
  static const _scopes = [
    'https://www.googleapis.com/auth/gmail.readonly',
    'https://www.googleapis.com/auth/calendar.readonly',
    'https://www.googleapis.com/auth/drive.readonly',
  ];

  GoogleSignIn? _googleSignIn;
  auth.AuthClient? _authClient;
  GoogleSignInAccount? _currentUser;

  auth.AuthClient? get authClient => _authClient;
  bool get isAuthenticated => _currentUser != null;

  Future<void> checkExistingAuth(String clientId) async {
    _googleSignIn = GoogleSignIn(
      clientId: clientId,
      scopes: _scopes,
    );
    
    try {
      _currentUser = await _googleSignIn!.signInSilently();
      if (_currentUser != null) {
        final authHeaders = await _currentUser!.authHeaders;
        _authClient = _AuthenticatedClient(authHeaders);
      }
    } catch (e) {
      print('Silent sign-in failed: $e');
    }
  }

  Future<bool> signIn(String clientId) async {
    _googleSignIn = GoogleSignIn(
      clientId: clientId,
      scopes: _scopes,
    );
    try {
      _currentUser = await _googleSignIn!.signIn();

      if (_currentUser != null) {
        final authHeaders = await _currentUser!.authHeaders;
        _authClient = _AuthenticatedClient(authHeaders);
        return true;
      }
      return false;
    } catch (e) {
      print('Auth error: $e');
      return false;
    }
  }

  void signOut() {
    _googleSignIn?.signOut();
    _authClient?.close();
    _authClient = null;
    _currentUser = null;
  }
}

class _AuthenticatedClient extends http.BaseClient implements auth.AuthClient {
  final Map<String, String> _headers;
  final http.Client _client = http.Client();
  final auth.AccessCredentials _credentials;

  _AuthenticatedClient(this._headers) : _credentials = auth.AccessCredentials(
    auth.AccessToken('Bearer', _headers['Authorization']?.replaceFirst('Bearer ', '') ?? '', DateTime.now().toUtc().add(Duration(hours: 1))),
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
