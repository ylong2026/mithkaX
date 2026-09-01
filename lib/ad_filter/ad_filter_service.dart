//
//  ad_filter_service.dart
//
//  Service object behind the ad filter: owns the rule set, persists it, and
//  keeps it fresh from a remote list.
//
//  The service never imports anything from the chat layer. It is handed plain
//  text plus an optional sender id, which keeps it usable from the
//  notification path (which runs before any chat view exists) and keeps the
//  dependency graph one-directional.
//

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'regex_engine.dart';
import 'rule_loader.dart';
import 'rule_model.dart';

/// Refresh cadence bounds. The lower bound is a courtesy limit so a typo'd
/// interval cannot turn into a request loop against someone's server.
const int kAdFilterMinIntervalMinutes = 5;
const int kAdFilterMaxIntervalMinutes = 1440;

class AdFilterService extends ChangeNotifier {
  AdFilterService._();

  static final AdFilterService shared = AdFilterService._();

  static const _keyRules = 'adFilterRules';
  static const _keyUrl = 'adFilterRulesUrl';
  static const _keyEnabled = 'adFilterEnabled';
  static const _keyAutoRefresh = 'adFilterAutoRefresh';
  static const _keyInterval = 'adFilterRefreshMinutes';
  static const _keyLastSync = 'adFilterLastSyncAt';
  static const _keyLastError = 'adFilterLastError';

  SharedPreferences? _prefs;
  Timer? _refreshTimer;

  List<AdRule> _rules = const <AdRule>[];
  AdRuleEngine _engine = AdRuleEngine.empty;
  String _rulesUrl = '';
  bool _enabled = true;
  bool _autoRefresh = true;
  int _intervalMinutes = 30;
  DateTime? _lastSyncAt;
  String? _lastError;
  bool _refreshing = false;

  // ---- Read surface -------------------------------------------------------

  List<AdRule> get rules => List<AdRule>.unmodifiable(_rules);

  int get ruleCount => _rules.length;

  String get rulesUrl => _rulesUrl;

  bool get isEnabled => _enabled;

  bool get isAutoRefreshEnabled => _autoRefresh;

  int get intervalMinutes => _intervalMinutes;

  DateTime? get lastSyncAt => _lastSyncAt;

  String? get lastError => _lastError;

  bool get isRefreshing => _refreshing;

  /// True once there is something to match against.
  bool get isActive => _enabled && !_engine.isEmpty;

  /// The compiled engine, exposed for the appearance preview, which renders
  /// sample transcripts without going through a chat view model.
  AdRuleEngine get engine => _engine;

  // ---- Lifecycle ----------------------------------------------------------

  void initialize(SharedPreferences prefs) {
    _prefs = prefs;
    _rules = _decodeRules(prefs.getString(_keyRules));
    _rulesUrl = prefs.getString(_keyUrl)?.trim() ?? '';
    _enabled = prefs.getBool(_keyEnabled) ?? true;
    _autoRefresh = prefs.getBool(_keyAutoRefresh) ?? true;
    _intervalMinutes = _sanitizeInterval(prefs.getInt(_keyInterval));
    final syncMs = prefs.getInt(_keyLastSync);
    _lastSyncAt =
        syncMs == null ? null : DateTime.fromMillisecondsSinceEpoch(syncMs);
    _lastError = prefs.getString(_keyLastError);
    _rebuild();
    notifyListeners();
    // Desktop secondary windows are separate engines that each call
    // `initialize()` with their own `SharedPreferences`. The one-shot start-up
    // pull is guarded so opening a second window does not fire a duplicate
    // request at the rule server; each window still keeps its own refresh
    // timer, because their engines hold independent in-memory state.
    if (_autoRefresh && _rulesUrl.isNotEmpty && !_didInitialRefresh) {
      _didInitialRefresh = true;
      // Nothing in the widget tree depends on the first refresh, so it is
      // fire-and-forget: a slow or unreachable rule server must never delay
      // first frame.
      unawaited(refreshFromUrl());
    }
    startAutoRefresh();
  }

  static bool _didInitialRefresh = false;

  /// Starts (or restarts) the periodic refresh timer.
  ///
  /// Safe to call more than once; the previous timer is cancelled first so a
  /// changed interval takes effect immediately.
  void startAutoRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
    if (!_autoRefresh || _rulesUrl.isEmpty) return;

    // The periodic timer is the "every 30 minutes" half of the feature. An
    // immediate first pass is skipped here because `initialize()` already
    // kicked one off when a URL is configured.
    _refreshTimer = Timer.periodic(
      Duration(minutes: _intervalMinutes),
      (_) => unawaited(refreshFromUrl()),
    );
  }

  void stopAutoRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
  }

  @override
  void dispose() {
    stopAutoRefresh();
    super.dispose();
  }

  // ---- Matching -----------------------------------------------------------

  /// Whether [text] from the given [senderId] should be hidden.
  ///
  /// Returns false when the filter is off or has no rules, so the call site
  /// pays a single boolean check in the common case.
  bool shouldBlock({required String text, int? senderId}) {
    if (!_enabled || _engine.isEmpty) return false;
    return _engine.matches(text, senderId: senderId);
  }

  // ---- Configuration ------------------------------------------------------

  void setEnabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    _prefs?.setBool(_keyEnabled, value);
    if (!value) {
      stopAutoRefresh();
    } else if (_autoRefresh) {
      startAutoRefresh();
    }
    notifyListeners();
  }

  void setAutoRefresh(bool value) {
    if (_autoRefresh == value) return;
    _autoRefresh = value;
    _prefs?.setBool(_keyAutoRefresh, value);
    if (value) {
      startAutoRefresh();
      if (_rulesUrl.isNotEmpty) unawaited(refreshFromUrl());
    } else {
      stopAutoRefresh();
    }
    notifyListeners();
  }

  void setIntervalMinutes(int value) {
    final next = _sanitizeInterval(value);
    if (_intervalMinutes == next) return;
    _intervalMinutes = next;
    _prefs?.setInt(_keyInterval, next);
    if (_autoRefresh) startAutoRefresh();
    notifyListeners();
  }

  void setRulesUrl(String value) {
    final next = value.trim();
    if (_rulesUrl == next) return;
    _rulesUrl = next;
    _prefs?.setString(_keyUrl, next);
    if (_autoRefresh && _enabled) startAutoRefresh();
    notifyListeners();
  }

  // ---- Rules --------------------------------------------------------------

  void addRule(AdRule rule) {
    if (_rules.any((existing) => existing.dedupeKey == rule.dedupeKey)) return;
    _rules = [..._rules, rule];
    _persistRules();
  }

  void removeRule(AdRule rule) {
    final next =
        _rules.where((existing) => existing.dedupeKey != rule.dedupeKey).toList();
    if (next.length == _rules.length) return;
    _rules = next;
    _persistRules();
  }

  void clearRules() {
    if (_rules.isEmpty) return;
    _rules = const <AdRule>[];
    _persistRules();
  }

  /// Pulls the remote list and merges it in.
  ///
  /// Returns the number of newly added rules. Throws on a bad URL, a transport
  /// failure or a non-2xx response; [lastError] is updated either way so the
  /// settings screen can explain the last failure after a restart.
  Future<int> refreshFromUrl() async {
    if (_rulesUrl.isEmpty) {
      throw const FormatException('No ad filter rules URL configured');
    }
    if (_refreshing) return 0;
    _refreshing = true;
    notifyListeners();
    try {
      final result = await AdRuleLoader.loadFromUrl(
        _rulesUrl,
        current: _rules,
      );
      _rules = result.rules;
      _lastSyncAt = DateTime.now();
      _lastError = null;
      _persistRules();
      _prefs?.setInt(_keyLastSync, _lastSyncAt!.millisecondsSinceEpoch);
      _prefs?.remove(_keyLastError);
      notifyListeners();
      return result.added;
    } catch (error) {
      _lastError = error.toString();
      _prefs?.setString(_keyLastError, _lastError);
      notifyListeners();
      rethrow;
    } finally {
      _refreshing = false;
      notifyListeners();
    }
  }

  // ---- Persistence --------------------------------------------------------

  void _persistRules() {
    _prefs?.setString(
      _keyRules,
      jsonEncode(_rules.map((rule) => rule.toJson()).toList()),
    );
    _rebuild();
    notifyListeners();
  }

  void _rebuild() {
    _engine = AdRuleEngine.withRules(_rules);
  }

  static List<AdRule> _decodeRules(String? raw) {
    if (raw == null || raw.isEmpty) return const <AdRule>[];
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return const <AdRule>[];
    }
    if (decoded is! List) return const <AdRule>[];
    final out = <AdRule>[];
    final seen = <String>{};
    for (final entry in decoded) {
      final rule = AdRule.fromJson(entry);
      if (rule == null) continue;
      if (seen.add(rule.dedupeKey)) out.add(rule);
    }
    return List<AdRule>.unmodifiable(out);
  }

  static int _sanitizeInterval(Object? value) {
    final parsed = value is int
        ? value
        : value is String
            ? int.tryParse(value)
            : null;
    if (parsed == null) return 30;
    return parsed.clamp(kAdFilterMinIntervalMinutes, kAdFilterMaxIntervalMinutes);
  }
}
