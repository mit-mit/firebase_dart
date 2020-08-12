import 'dart:io';

import 'package:firebase_dart/core.dart';
import 'package:firebase_dart/src/storage.dart';
import 'package:firebase_dart/src/storage/backend/backend.dart';
import 'package:firebase_dart/src/storage/backend/memory_backend.dart';
import 'package:firebase_dart/src/storage/metadata.dart';
import 'package:firebase_dart/src/storage/service.dart';
import 'package:firebase_dart/src/storage/impl/location.dart';
import 'package:hive/hive.dart';
import 'package:test/test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http;

import '../auth/util.dart';

void main() async {
  Hive.init(Directory.systemTemp.path);

  var app = await Firebase.initializeApp(options: getOptions());
  var tester = Tester(app);
  var storage = FirebaseStorageImpl(app, app.options.storageBucket,
      httpClient: tester.httpClient);
  var root = storage.ref();
  var child = root.child('hello');

  group('FirebaseStorage', () {
    group('FirebaseStorage.getReferenceFromUrl', () {
      test('FirebaseStorage.getReferenceFromUrl: root', () async {
        var ref = await storage.getReferenceFromUrl('gs://test-bucket/');
        expect(ref.toString(), 'gs://test-bucket/');
      });
      test(
          'FirebaseStorage.getReferenceFromUrl: keeps characters after ? on a gs:// string',
          () async {
        var ref = await storage
            .getReferenceFromUrl('gs://test-bucket/this/ismyobject?hello');
        expect(ref.toString(), 'gs://test-bucket/this/ismyobject?hello');
      });
      test(
          'FirebaseStorage.getReferenceFromUrl: doesn\'t URL-decode on a gs:// string',
          () async {
        var ref = await storage.getReferenceFromUrl('gs://test-bucket/%3F');
        expect(ref.toString(), 'gs://test-bucket/%3F');
      });
      test(
          'FirebaseStorage.getReferenceFromUrl: ignores URL params and fragments on an http URL',
          () async {
        var ref = await storage.getReferenceFromUrl(
            'http://firebasestorage.googleapis.com/v0/b/test-bucket/o/my/object.txt?ignoreme#please');
        expect(ref.toString(), 'gs://test-bucket/my/object.txt');
      });
      test(
          'FirebaseStorage.getReferenceFromUrl: URL-decodes and ignores fragment on an http URL',
          () async {
        var ref = await storage.getReferenceFromUrl(
            'http://firebasestorage.googleapis.com/v0/b/test-bucket/o/%3F?ignore');
        expect(ref.toString(), 'gs://test-bucket/?');
      });
      test(
          'FirebaseStorage.getReferenceFromUrl: ignores URL params and fragments on an https URL',
          () async {
        var ref = await storage.getReferenceFromUrl(
            'http://firebasestorage.googleapis.com/v0/b/test-bucket/o/my/object.txt?ignoreme#please');
        expect(ref.toString(), 'gs://test-bucket/my/object.txt');
      });
      test(
          'FirebaseStorage.getReferenceFromUrl: URL-decodes and ignores fragment on an https URL',
          () async {
        var ref = await storage.getReferenceFromUrl(
            'http://firebasestorage.googleapis.com/v0/b/test-bucket/o/%3F?ignore');
        expect(ref.toString(), 'gs://test-bucket/?');
      });
      test('FirebaseStorage.getReferenceFromUrl: Strips trailing slash',
          () async {
        var ref = await storage.getReferenceFromUrl('gs://test-bucket/foo/');
        expect(ref.toString(), 'gs://test-bucket/foo');
      });
    });
  });

  group('StorageReference', () {
    group('StorageReference.getParent', () {
      test('StorageReference.getParent: Returns null at root', () async {
        expect(root.getParent(), isNull);
      });
      test('StorageReference.getParent: Returns root one level down', () async {
        expect(child.getParent(), root);
        expect(child.getParent().toString(), 'gs://test-bucket/');
      });
      test('StorageReference.getParent: Works correctly with empty levels',
          () async {
        var ref = await storage.getReferenceFromUrl('gs://test-bucket/a///');
        expect(ref.getParent().toString(), 'gs://test-bucket/a/');
      });
    });

    group('StorageReference.getRoot', () {
      test('StorageReference.getRoot: Returns self at root', () async {
        expect(root.getRoot(), root);
      });
      test('StorageReference.getRoot: Returns root multiple levels down',
          () async {
        var ref = await storage.getReferenceFromUrl('gs://test-bucket/a/b/c/d');
        expect(ref.getRoot(), root);
      });
    });
    group('StorageReference.getBucket', () {
      test('StorageReference.getBucket: Returns bucket name', () async {
        expect(await root.getBucket(), 'test-bucket');
      });
    });
    group('StorageReference.path', () {
      test('StorageReference.path: Returns full path without leading slash',
          () async {
        var ref =
            await storage.getReferenceFromUrl('gs://test-bucket/full/path');
        expect(ref.path, 'full/path');
      });
    });
    group('StorageReference.getName', () {
      test('StorageReference.getName: Works at top level', () async {
        var ref =
            await storage.getReferenceFromUrl('gs://test-bucket/toplevel.txt');
        expect(await ref.getName(), 'toplevel.txt');
      });
      test('StorageReference.getName: Works at not the top level', () async {
        var ref = await storage
            .getReferenceFromUrl('gs://test-bucket/not/toplevel.txt');
        expect(await ref.getName(), 'toplevel.txt');
      });
    });
    group('StorageReference.child', () {
      test('StorageReference.child: works with a simple string', () async {
        expect(root.child('a').toString(), 'gs://test-bucket/a');
      });
      test('StorageReference.child: drops a trailing slash', () async {
        expect(root.child('ab/').toString(), 'gs://test-bucket/ab');
      });
      test('StorageReference.child: compresses repeated slashes', () async {
        expect(root.child('//a///b/////').toString(), 'gs://test-bucket/a/b');
      });
      test(
          'StorageReference.child: works chained multiple times with leading slashes',
          () async {
        expect(root.child('a').child('/b').child('c').child('d/e').toString(),
            'gs://test-bucket/a/b/c/d/e');
      });
      test('StorageReference.child: throws on null instead of path', () async {
        expect(() => root.child(null), throwsArgumentError);
      });
    });
    group('StorageReference.getDownloadUrl', () {
      var ref = child.child('world.txt');
      tester.backend.metadata[Location.fromUrl(ref.toString())] =
          StorageMetadataImpl(
              bucket: ref.getStorage().storageBucket,
              path: ref.path,
              downloadTokens: ['a,b,c']);

      test('StorageReference.getDownloadUrl: file exists', () async {
        var url = await ref.getDownloadURL();
        expect(
            url,
            Uri.parse(
                'https://firebasestorage.googleapis.com/v0/b/test-bucket/o/hello%2Fworld.txt?alt=media&token=a'));
      });
      test('StorageReference.getDownloadUrl: file does not exist', () async {
        var ref = child.child('everyone.txt');
        expect(() => ref.getDownloadURL(),
            throwsA(StorageException.objectNotFound(ref.path)));
      });
    });
  });
}

FirebaseOptions getOptions(
    {String appId = 'my_app_id',
    String apiKey = 'apiKey',
    String projectId = 'my_project',
    String storageBucket = 'test-bucket'}) {
  return FirebaseOptions(
      appId: appId,
      apiKey: apiKey,
      projectId: projectId,
      messagingSenderId: 'ignore',
      storageBucket: storageBucket);
}

class Tester {
  final MemoryBackend backend = MemoryBackend();

  http.Client _httpClient;

  BackendConnection _connection;

  http.Client get httpClient => _httpClient;

  Tester(FirebaseApp app) {
    _httpClient = ProxyClient({
      RegExp('.*'): http.MockClient((r) {
        try {
          return _connection.handleRequest(r);
        } catch (e) {
          throw StorageException.internalError('');
        }
      })
    });

    connect();
  }

  void connect() {
    _connection = BackendConnection(backend);
  }

  void disconnect() {
    _connection = null;
  }
}