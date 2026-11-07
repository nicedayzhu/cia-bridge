import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

class PatchTitleInfo {
  const PatchTitleInfo({
    required this.titleId,
    required this.name,
    this.publisher,
    this.region,
    this.productCode,
    required this.source,
  });

  final String titleId;
  final String name;
  final String? publisher;
  final String? region;
  final String? productCode;
  final PatchTitleInfoSource source;

  String get details {
    final values = <String>[
      if (region?.isNotEmpty == true) region!,
      if (publisher?.isNotEmpty == true) publisher!,
      if (productCode?.isNotEmpty == true) productCode!,
    ];
    return values.join(' · ');
  }

  Map<String, Object?> toJson() => {
    'titleId': titleId,
    'name': name,
    'publisher': publisher,
    'region': region,
    'productCode': productCode,
  };

  factory PatchTitleInfo.fromJson(
    Map<String, Object?> json, {
    required PatchTitleInfoSource source,
  }) => PatchTitleInfo(
    titleId: (json['titleId'] as String).toUpperCase(),
    name: json['name'] as String,
    publisher: json['publisher'] as String?,
    region: json['region'] as String?,
    productCode: json['productCode'] as String?,
    source: source,
  );
}

enum PatchTitleInfoSource { bundled, cache, online }

class PatchTitleInfoService {
  PatchTitleInfoService({
    AssetBundle? bundle,
    HttpClient Function()? clientFactory,
  }) : _bundle = bundle ?? rootBundle,
       _clientFactory = clientFactory ?? HttpClient.new;

  final AssetBundle _bundle;
  final HttpClient Function() _clientFactory;
  Future<Map<String, String>>? _bundledTitles;

  Future<PatchTitleInfo?> resolve(
    String rawTitleId, {
    required String dataDirectory,
    bool allowNetwork = true,
  }) async {
    final titleId = rawTitleId.toUpperCase();
    final cached = await _readCache(titleId, dataDirectory);
    if (cached != null) return cached;

    final bundled = await (_bundledTitles ??= _loadBundledTitles());
    final bundledName = bundled[titleId];
    if (bundledName != null && bundledName.trim().isNotEmpty) {
      return PatchTitleInfo(
        titleId: titleId,
        name: bundledName.trim(),
        source: PatchTitleInfoSource.bundled,
      );
    }
    if (!allowNetwork) return null;

    final online = await _lookupOnline(titleId);
    if (online != null) await _writeCache(online, dataDirectory);
    return online;
  }

  Future<Map<String, String>> _loadBundledTitles() async {
    final raw = await _bundle.loadString('assets/data/title_database.json');
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    return decoded.map((key, value) => MapEntry(key, value as String));
  }

  Future<PatchTitleInfo?> _readCache(
    String titleId,
    String dataDirectory,
  ) async {
    try {
      final file = _cacheFile(titleId, dataDirectory);
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      return PatchTitleInfo.fromJson(
        Map<String, Object?>.from(decoded as Map),
        source: PatchTitleInfoSource.cache,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeCache(PatchTitleInfo info, String dataDirectory) async {
    try {
      final file = _cacheFile(info.titleId, dataDirectory);
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(jsonEncode(info.toJson()), flush: true);
      if (await file.exists()) await file.delete();
      await temporary.rename(file.path);
    } catch (_) {
      // Metadata caching is an enhancement and must never block patch sending.
    }
  }

  File _cacheFile(String titleId, String dataDirectory) => File(
    '$dataDirectory${Platform.pathSeparator}title-info'
    '${Platform.pathSeparator}$titleId.json',
  );

  Future<PatchTitleInfo?> _lookupOnline(String titleId) async {
    final client = _clientFactory()
      ..connectionTimeout = const Duration(seconds: 4);
    try {
      final uri = Uri.https('api.nlib.cc', '/ctr/$titleId', {
        'fields': 'name,publisher,region,product_code',
        'related': '0',
      });
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 5));
      request.headers
        ..set(HttpHeaders.acceptHeader, 'application/json')
        ..set(HttpHeaders.userAgentHeader, 'CIA-Bridge/0.3');
      final response = await request.close().timeout(
        const Duration(seconds: 5),
      );
      if (response.statusCode != HttpStatus.ok) return null;
      if (response.contentLength > 256 * 1024) return null;

      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(const Duration(seconds: 5))) {
        bytes.add(chunk);
        if (bytes.length > 256 * 1024) return null;
      }
      final decoded = jsonDecode(utf8.decode(bytes.takeBytes()));
      final map = Map<String, Object?>.from(decoded as Map);
      final name = map['name'] as String?;
      if (name == null || name.trim().isEmpty) return null;
      return PatchTitleInfo(
        titleId: titleId,
        name: name.trim(),
        publisher: map['publisher'] as String?,
        region: map['region'] as String?,
        productCode: map['product_code'] as String?,
        source: PatchTitleInfoSource.online,
      );
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }
}
