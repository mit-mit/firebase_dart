import 'dart:convert';
import 'dart:math';

import 'package:clock/clock.dart';
import 'package:firebase_dart/src/auth/error.dart';
import 'package:firebase_dart/src/auth/rpc/error.dart';
import 'package:firebase_dart/src/auth/rpc/identitytoolkit.dart';
import 'package:jose/jose.dart';
import 'package:http/http.dart' as http;

class BackendConnection {
  final Backend backend;

  BackendConnection(this.backend);

  Future<GetAccountInfoResponse> getAccountInfo(
      IdentitytoolkitRelyingpartyGetAccountInfoRequest request) async {
    var jwt = JsonWebToken.unverified(request.idToken); // TODO verify
    var uid = jwt.claims.subject;
    var user = await backend.getUserById(uid);
    return GetAccountInfoResponse()
      ..kind = 'identitytoolkit#GetAccountInfoResponse'
      ..users = [user];
  }

  Future<SignupNewUserResponse> signupNewUser(
      IdentitytoolkitRelyingpartySignupNewUserRequest request) async {
    var user = await backend.createUser(
      email: request.email,
      password: request.password,
    );

    var provider = request.email == null ? 'anonymous' : 'password';

    var idToken =
        await backend.generateIdToken(uid: user.localId, providerId: provider);
    var refreshToken = await backend.generateRefreshToken(user.localId);

    return SignupNewUserResponse()
      ..expiresIn = '3600'
      ..kind = 'identitytoolkit#SignupNewUserResponse'
      ..idToken = idToken
      ..refreshToken = refreshToken;
  }

  Future<VerifyPasswordResponse> verifyPassword(
      IdentitytoolkitRelyingpartyVerifyPasswordRequest request) async {
    var user = await backend.getUserByEmail(request.email);

    if (user.rawPassword == request.password) {
      var refreshToken = await backend.generateRefreshToken(user.localId);
      return VerifyPasswordResponse()
        ..kind = 'identitytoolkit#VerifyPasswordResponse'
        ..localId = user.localId
        ..idToken = request.returnSecureToken == true
            ? await backend.generateIdToken(
                uid: user.localId, providerId: 'password')
            : null
        ..expiresIn = '3600'
        ..refreshToken = refreshToken;
    }

    throw AuthException.invalidPassword();
  }

  Future<CreateAuthUriResponse> createAuthUri(
      IdentitytoolkitRelyingpartyCreateAuthUriRequest request) async {
    var user = await backend.getUserByEmail(request.identifier);

    return CreateAuthUriResponse()
      ..kind = 'identitytoolkit#CreateAuthUriResponse'
      ..allProviders = [for (var p in user.providerUserInfo) p.providerId]
      ..signinMethods = [for (var p in user.providerUserInfo) p.providerId];
  }

  Future<VerifyCustomTokenResponse> verifyCustomToken(
      IdentitytoolkitRelyingpartyVerifyCustomTokenRequest request) async {
    var t = JsonWebToken.unverified(request.token); // TODO
    var uid = t.claims['uid'];
    var user = await backend.getUserById(uid);

    var refreshToken = await backend.generateRefreshToken(user.localId);
    return VerifyCustomTokenResponse()
      ..kind = 'identitytoolkit#VerifyCustomTokenResponse'
      ..idToken = request.returnSecureToken == true
          ? await backend.generateIdToken(
              uid: user.localId, providerId: 'custom')
          : null
      ..expiresIn = '3600'
      ..refreshToken = refreshToken;
  }

  Future<dynamic> _handle(String method, dynamic body) async {
    switch (method) {
      case 'signupNewUser':
        var request =
            IdentitytoolkitRelyingpartySignupNewUserRequest.fromJson(body);
        return signupNewUser(request);
      case 'getAccountInfo':
        var request =
            IdentitytoolkitRelyingpartyGetAccountInfoRequest.fromJson(body);
        return getAccountInfo(request);
      case 'verifyPassword':
        var request =
            IdentitytoolkitRelyingpartyVerifyPasswordRequest.fromJson(body);
        return verifyPassword(request);
      case 'createAuthUri':
        var request =
            IdentitytoolkitRelyingpartyCreateAuthUriRequest.fromJson(body);
        return createAuthUri(request);
      case 'verifyCustomToken':
        var request =
            IdentitytoolkitRelyingpartyVerifyCustomTokenRequest.fromJson(body);
        return verifyCustomToken(request);
      default:
        throw UnsupportedError('Unsupported method $method');
    }
  }

  Future<http.Response> handleRequest(http.Request request) async {
    var method = request.url.pathSegments.last;

    var body = json.decode(request.body);

    try {
      return http.Response(json.encode(await _handle(method, body)), 200,
          headers: {'content-type': 'application/json'});
    } on AuthException catch (e) {
      return http.Response(json.encode(errorToServerResponse(e)), 400,
          headers: {'content-type': 'application/json'});
    }
  }
}

abstract class Backend {
  Future<UserInfo> getUserById(String uid);

  Future<UserInfo> getUserByEmail(String email);

  Future<UserInfo> createUser({String email, String password});

  Future<String> generateIdToken({String uid, String providerId});

  Future<String> generateRefreshToken(String uid);
}

abstract class BaseBackend extends Backend {
  final JsonWebKey tokenSigningKey;

  final String projectId;

  BaseBackend({this.tokenSigningKey, this.projectId});

  Future<UserInfo> storeUser(UserInfo user);

  @override
  Future<UserInfo> createUser({String email, String password}) async {
    var uid = _generateRandomString(24);
    var now = (clock.now().millisecondsSinceEpoch ~/ 1000).toString();
    return storeUser(UserInfo()
      ..createdAt = now
      ..lastLoginAt = now
      ..email = email
      ..rawPassword = password
      ..localId = uid);
  }

  @override
  Future<String> generateIdToken({String uid, String providerId}) async {
    var builder = JsonWebSignatureBuilder()
      ..jsonContent = _jwtPayloadFor(uid, providerId)
      ..addRecipient(tokenSigningKey);
    return builder.build().toCompactSerialization();
  }

  @override
  Future<String> generateRefreshToken(String uid) async {
    var builder = JsonWebSignatureBuilder()
      ..jsonContent = uid
      ..addRecipient(tokenSigningKey);
    return builder.build().toCompactSerialization();
  }

  static final _random = Random(DateTime.now().millisecondsSinceEpoch);

  static String _generateRandomString(int length) {
    var chars =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';

    return Iterable.generate(
        length, (i) => chars[_random.nextInt(chars.length)]).join();
  }

  Map<String, dynamic> _jwtPayloadFor(String uid, String providerId) {
    var now = clock.now().millisecondsSinceEpoch ~/ 1000;
    return {
      'iss': 'https://securetoken.google.com/$projectId',
      if (providerId != null) 'provider_id': providerId,
      'aud': '$projectId',
      'auth_time': now,
      'sub': uid,
      'iat': now,
      'exp': now + 3600,
      if (providerId == 'anonymous')
        'firebase': {'identities': {}, 'sign_in_provider': 'anonymous'}
    };
  }
}