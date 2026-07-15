import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Downloads geoip.dat/geosite.dat into a writable dir (`xray.location.asset`).
/// Content-addressed blobs + ETag revalidation for `.../latest/...` URLs.
class GeoManager {
  GeoManager._();
  static final GeoManager instance = GeoManager._();

  static const _minValidBytes = 1000; // a real .dat is MBs; smaller = failed DL

  Directory? _dir;
  Map<String, dynamic> _index = {};
  bool _indexLoaded = false;

  Future<Directory> dir() async {
    final cached = _dir;
    if (cached != null) return cached;
    final base = await getApplicationSupportDirectory();
    final d = Directory('${base.path}/glitch_geo');
    await d.create(recursive: true);
    await Directory('${d.path}/blobs').create(recursive: true);
    _dir = d;
    return d;
  }

  Future<void> _loadIndex(Directory d) async {
    if (_indexLoaded) return;
    final f = File('${d.path}/index.json');
    if (await f.exists()) {
      try {
        final decoded = jsonDecode(await f.readAsString());
        if (decoded is Map) _index = Map<String, dynamic>.from(decoded);
      } catch (_) {
        _index = {};
      }
    }
    _indexLoaded = true;
  }

  Future<void> _saveIndex(Directory d) async {
    try {
      await File('${d.path}/index.json').writeAsString(jsonEncode(_index));
    } catch (e) {
      debugPrint('geo: index save failed: $e');
    }
  }

  /// Ensures both .dat files are present/fresh. Never throws; keeps existing on failure.
  Future<String> provision({
    required String geoipUrl,
    required String geositeUrl,
    required Duration maxAge,
    bool force = false,
  }) async {
    final d = await dir();
    await _loadIndex(d);
    await _provisionOne(d, 'geoip.dat', geoipUrl.trim(), maxAge, force);
    await _provisionOne(d, 'geosite.dat', geositeUrl.trim(), maxAge, force);
    await _saveIndex(d);
    return d.path;
  }

  bool _isMutable(String url) => url.contains('/latest/');

  Future<void> _provisionOne(
    Directory d,
    String name,
    String url,
    Duration maxAge,
    bool force,
  ) async {
    if (url.isEmpty) return;
    File blobFor(String md5hex) => File('${d.path}/blobs/$md5hex.dat');

    final meta = (_index[url] as Map?)?.cast<String, dynamic>();
    final knownMd5 = meta?['md5'] as String?;
    final mutable = _isMutable(url);
    final haveBlob = knownMd5 != null && await blobFor(knownMd5).exists();

    if (!force && haveBlob) {
      if (!mutable) {
        await _materialize(d, name, knownMd5);
        return;
      }
      final fetchedAt = DateTime.tryParse(meta?['fetchedAt'] as String? ?? '');
      if (fetchedAt != null && DateTime.now().difference(fetchedAt) < maxAge) {
        await _materialize(d, name, knownMd5);
        return;
      }
    }

    try {
      final String? etagIn = mutable ? (meta?['etag'] as String?) : null;
      final fetched = await _download(url, etagIn);
      if (fetched == null) {
        // 304 - refresh the timestamp, keep the blob.
        if (meta != null && knownMd5 != null) {
          meta['fetchedAt'] = DateTime.now().toIso8601String();
          _index[url] = meta;
          await _materialize(d, name, knownMd5);
        }
        return;
      }
      final (bytes, etag) = fetched;
      final md5hex = md5.convert(bytes).toString();
      final blob = blobFor(md5hex);
      if (!await blob.exists()) {
        final tmp = File('${blob.path}.tmp');
        await tmp.writeAsBytes(bytes, flush: true);
        await tmp.rename(blob.path);
      }
      _index[url] = {
        'md5': md5hex,
        'etag': etag,
        'fetchedAt': DateTime.now().toIso8601String(),
      };
      await _materialize(d, name, md5hex);
    } catch (e) {
      debugPrint('geo: fetch $name from $url failed: $e');
    }
  }

  // Copies the blob to the active canonical name, unless the active file is
  // already that md5 (tracked under "@active" to avoid rewriting 20MB each run).
  Future<void> _materialize(Directory d, String name, String md5hex) async {
    final activeIdx = (_index['@active'] as Map?)?.cast<String, dynamic>() ?? {};
    final blob = File('${d.path}/blobs/$md5hex.dat');
    final active = File('${d.path}/$name');
    if (activeIdx[name] == md5hex && await active.exists()) return;
    if (!await blob.exists()) return;
    try {
      final tmp = File('${active.path}.tmp');
      await blob.copy(tmp.path);
      await tmp.rename(active.path); // atomic; may throw if engine holds the lock
      activeIdx[name] = md5hex;
      _index['@active'] = activeIdx;
    } catch (e) {
      debugPrint('geo: materialize $name failed (engine may hold it): $e');
    }
  }

  // Downloads url. Returns (bytes, etag) on 200, or null on 304 Not Modified.
  // Throws on other failures / too-small bodies.
  Future<(List<int>, String?)?> _download(String url, String? etag) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      final req = await client.getUrl(Uri.parse(url));
      if (etag != null && etag.isNotEmpty) {
        req.headers.set(HttpHeaders.ifNoneMatchHeader, etag);
      }
      final resp = await req.close();
      if (resp.statusCode == HttpStatus.notModified) return null;
      if (resp.statusCode != HttpStatus.ok) {
        throw HttpException('HTTP ${resp.statusCode}', uri: Uri.parse(url));
      }
      final bytes = await consolidateHttpClientResponseBytes(resp);
      if (bytes.length <= _minValidBytes) {
        throw const HttpException('geo body too small - treated as failed');
      }
      return (bytes, resp.headers.value(HttpHeaders.etagHeader));
    } finally {
      client.close();
    }
  }

  /// Tag from a versioned v2fly URL, or null for `latest`/opaque.
  static String? versionOf(String url) {
    final m = RegExp(r'/download/([^/]+)/').firstMatch(url);
    return m?.group(1);
  }

  /// Newer GitHub release than pinned [url]? null if unknown.
  Future<GeoUpdateInfo?> checkUpdate(String url) async {
    final current = versionOf(url);
    final repo = RegExp(
      r'github\.com/([^/]+/[^/]+)/releases/',
    ).firstMatch(url)?.group(1);
    if (repo == null) return null;
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      // The latest-release redirect exposes the newest tag in its Location.
      final req = await client.getUrl(
        Uri.parse('https://github.com/$repo/releases/latest'),
      );
      req.followRedirects = false;
      final resp = await req.close();
      await resp.drain<void>();
      final loc = resp.headers.value(HttpHeaders.locationHeader);
      final latest = loc == null
          ? null
          : RegExp(r'/tag/([^/]+)$').firstMatch(loc)?.group(1);
      if (latest == null) return null;
      return GeoUpdateInfo(
        current: current,
        latest: latest,
        hasUpdate: current == null || current != latest,
      );
    } catch (e) {
      debugPrint('geo: checkUpdate $url failed: $e');
      return null;
    } finally {
      client.close();
    }
  }
}

class GeoUpdateInfo {
  final String? current; // installed/pinned tag, or null if unknown
  final String? latest; // newest available tag
  final bool hasUpdate;
  const GeoUpdateInfo({
    required this.current,
    required this.latest,
    required this.hasUpdate,
  });
  @override
  String toString() =>
      'GeoUpdateInfo(current: $current, latest: $latest, hasUpdate: $hasUpdate)';
}
