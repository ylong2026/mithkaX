//
//  rule_model.dart
//
//  Data model for ad-filter rules. The model is deliberately free of any
//  Flutter, chat or TDLib import: the filter engine has to stay testable and
//  reusable from the notification path, which runs before any chat view
//  exists.
//

import 'package:flutter/foundation.dart';

/// What part of a message a rule is tested against.
enum AdRuleKind {
  /// Plain substring match against the message text.
  keyword,

  /// Regular expression match against the message text.
  regex,

  /// Match against the host of every URL found in the message, so a rule for
  /// `example.com` also catches `https://www.example.com/promo`.
  domain,

  /// Match against the numeric sender id.
  sender;

  String get wireName => name;

  static AdRuleKind? fromWireName(Object? value) {
    if (value is! String) return null;
    for (final kind in values) {
      if (kind.name == value) return kind;
    }
    return null;
  }
}

/// One filter rule.
///
/// Rules are immutable and compared by [dedupeKey] so the same rule pulled
/// from a remote list twice does not accumulate.
@immutable
class AdRule {
  const AdRule({
    required this.kind,
    required this.pattern,
    this.caseSensitive = false,
    this.source,
  });

  final AdRuleKind kind;
  final String pattern;

  /// Only honoured by [AdRuleKind.keyword] and [AdRuleKind.regex]; domains and
  /// sender ids are canonical by construction.
  final bool caseSensitive;

  /// Where the rule came from, e.g. the remote list URL. Local rules leave
  /// this null. It is metadata only and never takes part in matching.
  final String? source;

  /// Identity used for de-duplication across refreshes.
  String get dedupeKey => '${kind.wireName}:${caseSensitive ? 's' : 'i'}:'
      '${kind == AdRuleKind.sender ? _normalizedSender() : (caseSensitive ? pattern : pattern.toLowerCase())}';

  String _normalizedSender() {
    // Sender ids are compared numerically; leading zeros must not create
    // distinct entries for the same account.
    final parsed = int.tryParse(pattern.trim());
    return parsed?.toString() ?? pattern.trim().toLowerCase();
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'kind': kind.wireName,
        'pattern': pattern,
        if (caseSensitive) 'caseSensitive': true,
        if (source != null) 'source': source,
      };

  /// Returns null instead of throwing when [raw] is malformed, so one bad
  /// entry in a remote list can never take the whole refresh down.
  static AdRule? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final kind = AdRuleKind.fromWireName(raw['kind']);
    final pattern = raw['pattern'];
    if (kind == null || pattern is! String) return null;
    final trimmed = pattern.trim();
    if (trimmed.isEmpty) return null;
    if (kind == AdRuleKind.sender && int.tryParse(trimmed) == null) {
      return null;
    }
    return AdRule(
      kind: kind,
      pattern: trimmed,
      caseSensitive: raw['caseSensitive'] == true,
      source: raw['source'] is String ? raw['source'] as String : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AdRule && other.dedupeKey == dedupeKey;

  @override
  int get hashCode => dedupeKey.hashCode;

  @override
  String toString() => 'AdRule(${kind.wireName}: $pattern)';
}
