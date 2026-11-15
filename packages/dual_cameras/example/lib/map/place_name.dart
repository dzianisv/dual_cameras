import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

/// Reverse-geocoded place names for the map circle (issue #47, D6/D7).
///
/// Nominatim (public instance, no key, no paid service — the same
/// constraint as the tile source). The usage policy
/// (operations.osmfoundation.org/policies/nominatim) caps use at 1
/// request/second and requires a valid User-Agent, visible attribution,
/// caching, and an off-switch without an app update. This service complies
/// as follows:
///
/// * A lookup fires only on a move of >= 100 m from the last looked-up
///   position (or the first fix), with a hard 1.1 s floor between
///   requests, and is skipped while the fix accuracy is worse than 50 m
///   (that gate lives in the caller — see [MapLocationService]).
/// * Results persist in `place_name_cache.json` (same file precedent as
///   `camera_settings.json`), keyed by lat/lon rounded to 4 decimals
///   (~11 m), capped at 50 entries with FIFO eviction.
/// * The off-switch is `website/nominatim.json`, deployed with the
///   website to https://dzianisv.github.io/dual_cameras/nominatim.json.
///   It is fetched on the first lookup attempt; the verdict is
///   three-state: enabled -> lookups run; fetched disabled -> lookups off
///   for the session; fetch failed -> off for that attempt only, re-fetched
///   on a later attempt (at most once per 60 s). The switch is checked
///   before even cached names are served, so flipping it off stops the
///   label the same session.
/// * Timeout 10 s; any error (non-200, timeout, no network, empty
///   result) -> null, no retry storm.
///
/// Accepted-risk record (D6): these lookups are position-triggered
/// periodic requests, which the policy calls bulk geocoding and strongly
/// discourages. They are acceptable here because StoryCam is a single-user
/// sideloaded app (very few users), with the 100 m gate, 1.1 s floor,
/// persistent cache, and the off-switch keeping usage well below the
/// limits. If the user count ever grows, the lookup moves to a self-hosted
/// Nominatim or a commercial provider — a product-owner decision.
class PlaceNameService {
  PlaceNameService({
    http.Client? client,
    Future<Directory> Function()? documentsDirectory,
    String? appVersion,
    Duration minRequestInterval = const Duration(milliseconds: 1100),
    Duration switchRetryInterval = const Duration(seconds: 60),
    Duration requestTimeout = const Duration(seconds: 10),
    Duration switchTimeout = const Duration(seconds: 5),
  })  : _client = client ?? http.Client(),
        _ownsClient = client == null,
        _documentsDirectory =
            documentsDirectory ?? getApplicationDocumentsDirectory,
        _appVersion = appVersion,
        _minRequestInterval = minRequestInterval,
        _switchRetryInterval = switchRetryInterval,
        _requestTimeout = requestTimeout,
        _switchTimeout = switchTimeout;

  /// The no-update off-switch (D6): flipping `enabled` to false in the
  /// repo stops lookups without an app release.
  static const switchUrl =
      'https://dzianisv.github.io/dual_cameras/nominatim.json';

  static const _cacheFileName = 'place_name_cache.json';

  /// Persistent cache cap (D6): 50 entries, FIFO eviction.
  static const maxCacheEntries = 50;

  /// A lookup fires only on a move of at least this far from the last
  /// looked-up position (D6).
  static const moveGateMeters = 100.0;

  /// Nominatim request timeout (D6).
  static const defaultRequestTimeout = Duration(seconds: 10);

  /// Off-switch fetch timeout (D6).
  static const defaultSwitchTimeout = Duration(seconds: 5);

  final http.Client _client;
  final bool _ownsClient;
  final Future<Directory> Function() _documentsDirectory;
  final Duration _minRequestInterval;
  final Duration _switchRetryInterval;
  final Duration _requestTimeout;
  final Duration _switchTimeout;

  String? _appVersion;

  _SwitchVerdict _switchVerdict = _SwitchVerdict.unknown;
  DateTime? _lastSwitchFetch;

  LatLng? _lastLookupPosition;
  String? _lastLabel;
  DateTime? _lastRequestAt;

  /// Insertion-ordered cache (Dart maps preserve insertion order):
  /// the first key is the oldest-inserted entry, evicted first.
  final Map<String, String> _cache = {};
  bool _cacheLoaded = false;
  File? _cacheFile;

  /// Look up the place name for [position], or null when no name is
  /// known (offline, switch off, lookup failed, or no usable result).
  /// A lookup that implies a >= 100 m move clears the old label on
  /// failure (D7): a missing label is honest, a wrong place name is not.
  Future<String?> lookup(LatLng position) async {
    // The switch is checked before even cached names are served (Stage 2
    // carry-over note 4): flipping it off stops the label the same
    // session.
    if (!await _switchAllowsLookups()) return null;
    await _ensureCacheLoaded();

    final key = _cacheKey(position);
    final cached = _cache[key];
    if (cached != null) {
      _lastLookupPosition = position;
      _lastLabel = cached;
      return cached;
    }

    // Move gate (D6): standing still sends nothing; a small move returns
    // the last label (still valid — we have not moved far).
    if (_lastLookupPosition != null &&
        const Distance().as(
              LengthUnit.Meter,
              _lastLookupPosition!,
              position,
            ) <
            moveGateMeters) {
      return _lastLabel;
    }

    // Hard floor (D6): at least 1.1 s between requests, even if the move
    // threshold is somehow met faster.
    final lastRequest = _lastRequestAt;
    if (lastRequest != null) {
      final elapsed = DateTime.now().difference(lastRequest);
      if (elapsed < _minRequestInterval) {
        await Future.delayed(_minRequestInterval - elapsed);
      }
    }

    _lastRequestAt = DateTime.now();
    final label = await _reverseGeocode(position);
    if (label == null) return null;
    _lastLookupPosition = position;
    _lastLabel = label;
    _cachePut(key, label);
    return label;
  }

  /// Whether lookups may run, per the three-state switch verdict (D6).
  Future<bool> _switchAllowsLookups() async {
    if (_switchVerdict == _SwitchVerdict.disabled) return false;
    if (_switchVerdict == _SwitchVerdict.enabled) return true;
    // Unknown: re-fetch on a later attempt, at most once per 60 s —
    // offline-at-launch must not kill the label until relaunch.
    final now = DateTime.now();
    final lastFetch = _lastSwitchFetch;
    if (lastFetch != null && now.difference(lastFetch) < _switchRetryInterval) {
      return false;
    }
    _lastSwitchFetch = now;
    try {
      final response =
          await _client.get(Uri.parse(switchUrl)).timeout(_switchTimeout);
      if (response.statusCode != 200) return false;
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, Object?>) {
        if (decoded['enabled'] == true) {
          _switchVerdict = _SwitchVerdict.enabled;
          return true;
        }
        if (decoded['enabled'] == false) {
          _switchVerdict = _SwitchVerdict.disabled;
          return false;
        }
      }
      return false;
    } catch (_) {
      // Fetch failed: unknown, not disabled — a later attempt retries.
      return false;
    }
  }

  Future<String?> _reverseGeocode(LatLng position) async {
    try {
      final uri = Uri.https(
        'nominatim.openstreetmap.org',
        '/reverse',
        {
          'format': 'jsonv2',
          'lat': position.latitude.toString(),
          'lon': position.longitude.toString(),
          'zoom': '18',
          'addressdetails': '1',
          'accept-language': _languageCode(),
        },
      );
      final version = await _version();
      final response = await _client.get(
        uri,
        headers: {'User-Agent': 'StoryCam/$version (app.storycam)'},
      ).timeout(_requestTimeout);
      if (response.statusCode != 200) return null;
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, Object?>) return null;
      return _labelFrom(decoded);
    } catch (_) {
      // Timeout, no network, malformed body — null, no retry storm.
      return null;
    }
  }

  /// Device locale's language part (`en_US` -> `en`), fallback `en` (D7).
  String _languageCode() {
    final locale = Platform.localeName;
    final parts = locale.split(RegExp(r'[_-]'));
    if (parts.isEmpty || parts.first.isEmpty) return 'en';
    return parts.first;
  }

  Future<String> _version() async {
    final injected = _appVersion;
    if (injected != null) return injected;
    try {
      final info = await PackageInfo.fromPlatform();
      _appVersion = info.version;
      return info.version;
    } catch (_) {
      return 'unknown';
    }
  }

  /// Label from a Nominatim `jsonv2` result (D7): locality from the
  /// address object, region from state/country; a cleaned `display_name`
  /// fallback when the address yields no locality.
  String? _labelFrom(Map<String, Object?> json) {
    final address = json['address'];
    if (address is Map<String, Object?>) {
      final locality = _firstNonEmpty(address, const [
        'city',
        'town',
        'village',
        'municipality',
        'suburb',
        'county',
      ]);
      if (locality != null) {
        final region = _firstNonEmpty(address, const ['state', 'country']);
        return region != null ? '$locality, $region' : locality;
      }
    }
    final displayName = json['display_name'];
    if (displayName is String) return _cleanDisplayName(displayName);
    return null;
  }

  String? _firstNonEmpty(Map<String, Object?> address, List<String> keys) {
    for (final key in keys) {
      final value = address[key];
      if (value is String && value.trim().isNotEmpty) return value.trim();
    }
    return null;
  }

  /// Drop the leading street-address segments from a `display_name`
  /// (at zoom=18 it starts with e.g. "12, Main Street, …", which is not
  /// a place name) and keep the first two remaining parts as
  /// "locality, region", matching the address-object format.
  String? _cleanDisplayName(String displayName) {
    final parts = displayName
        .split(',')
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();
    var index = 0;
    // House number: a bare number, optionally with a letter ("12", "12A").
    while (index < parts.length && _isHouseNumber(parts[index])) {
      index++;
    }
    // Road: a segment naming a street/road/avenue (…).
    while (index < parts.length && _isRoad(parts[index])) {
      index++;
    }
    final rest = parts.sublist(index);
    if (rest.isEmpty) return null;
    if (rest.length == 1) return rest.first;
    return '${rest[0]}, ${rest[1]}';
  }

  bool _isHouseNumber(String part) =>
      RegExp(r'^\d+[A-Za-z]?(-\d+)?$').hasMatch(part);

  static const _roadWords = {
    'street',
    'st',
    'road',
    'rd',
    'avenue',
    'ave',
    'lane',
    'ln',
    'drive',
    'dr',
    'boulevard',
    'blvd',
    'square',
    'sq',
    'way',
    'court',
    'ct',
    'place',
    'pl',
    'crescent',
    'terrace',
    'highway',
    'hwy',
    'alley',
    'promenade',
    'embankment',
  };

  bool _isRoad(String part) {
    final words = part.toLowerCase().split(RegExp(r'[^a-z]+'));
    return words.any(_roadWords.contains);
  }

  String _cacheKey(LatLng position) =>
      '${position.latitude.toStringAsFixed(4)},'
      '${position.longitude.toStringAsFixed(4)}';

  void _cachePut(String key, String label) {
    // Re-inserting refreshes the insertion order (FIFO is by insertion).
    _cache.remove(key);
    _cache[key] = label;
    while (_cache.length > maxCacheEntries) {
      _cache.remove(_cache.keys.first);
    }
    _persistCache();
  }

  Future<void> _ensureCacheLoaded() async {
    if (_cacheLoaded) return;
    _cacheLoaded = true;
    try {
      final dir = await _documentsDirectory();
      _cacheFile = File('${dir.path}/$_cacheFileName');
      final file = _cacheFile!;
      if (!file.existsSync()) return;
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is Map<String, Object?>) {
        for (final entry in decoded.entries) {
          if (entry.value is String) _cache[entry.key] = entry.value as String;
        }
        while (_cache.length > maxCacheEntries) {
          _cache.remove(_cache.keys.first);
        }
      }
    } catch (_) {
      _cache.clear();
    }
  }

  void _persistCache() {
    try {
      _cacheFile?.writeAsStringSync(jsonEncode(_cache), flush: true);
    } catch (_) {
      // Best effort only — a failed cache save never breaks the label.
    }
  }

  void dispose() {
    if (_ownsClient) _client.close();
  }
}

enum _SwitchVerdict { unknown, enabled, disabled }
