//
//  rule_loader.dart
//
//  Fetches and parses remote ad-filter rule lists.
//
//  Accepted formats:
//
//  1. Plain text, one rule per line. `#` and `//` start comments.
//  2. JSON — either a flat array of strings (each still parsed with the text
//     grammar) or an array/object of rule objects using the same shape as
//     `AdRule.toJson()`.
//
//  The text grammar understands the prefixes the keyword blocker already
//  taught users (`re:`, `regex:`, `/pattern/i`) plus two new ones:
//
//  * `domain:example.com` — match any link pointing at that host.
//  * `sender:123456`      — match a numeric sender id.
//
//  A line with no recognised prefix is a plain keyword, so an existing keyword
//  list works unchanged as an ad list.
//

import 'dart:convert';
import 'dart:io';

import 'rule_model.dart';

/// Outcome of one parse/refresh pass.
class AdRuleLoadResult {
  const AdRuleLoadResult({
    required this.rules,
    required this.added,
    required this.skipped,
    required this.invalid,
  });

  /// Every rule known after the pass, already de-duplicated and in a stable
  /// order.
  final List<AdRule> rules;

  /// How many of those were not present before.
  final int added;

  /// Lines ignored as blanks or comments.
  final int skipped;

  /// Lines that could not be understood or compiled.
  final int invalid;
}

class AdRuleLoader {
  AdRuleLoader._();

  static const Duration kRequestTimeout = Duration(seconds: 20);

  /// Downloads [url] and merges the parsed rules into [current].
  ///
  /// Throws [FormatException] for an unusable URL and [HttpException] for a
  /// non-2xx response, mirroring `KeywordBlocker.refreshFromUrl` so callers
  /// can share one error path.
  static Future<AdRuleLoadResult> loadFromUrl(
    String url, {
    List<AdRule> current = const <AdRule>[],
  }) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      throw const FormatException('Invalid ad filter rules URL');
    }
    final client = HttpClient()..connectionTimeout = kRequestTimeout;
    try {
      final request = await client.getUrl(uri).timeout(kRequestTimeout);
      request.headers.set(HttpHeaders.acceptHeader, 'text/plain,application/json,*/*');
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('HTTP ${response.statusCode}', uri: uri);
      }
      final body = await utf8.decodeStream(response);
      return parse(body, current: current, source: url.trim());
    } finally {
      client.close(force: true);
    }
  }

  /// Parses [body] and merges it into [current].
  static AdRuleLoadResult parse(
    String body, {
    List<AdRule> current = const <AdRule>[],
    String? source,
  }) {
    final trimmed = body.trim();
    final parsed = trimmed.startsWith('[') || trimmed.startsWith('{')
        ? _parseJson(trimmed, source: source)
        : _parseLines(trimmed, source: source);

    final merged = <AdRule>[...current];
    final seen = <String>{
      for (final rule in current) rule.dedupeKey,
    };
    var added = 0;
    for (final rule in parsed.rules) {
      if (seen.add(rule.dedupeKey)) {
        merged.add(rule);
        ++added;
      }
    }
    return AdRuleLoadResult(
      rules: List<AdRule>.unmodifiable(merged),
      added: added,
      skipped: parsed.skipped,
      invalid: parsed.invalid,
    );
  }

  static _ParsedBatch _parseLines(String body, {String? source}) {
    final rules = <AdRule>[];
    var skipped = 0;
    var invalid = 0;
    for (final rawLine in body.split(RegExp(r'\r?\n'))) {
      final line = rawLine.trim();
      if (line.isEmpty) {
        ++skipped;
        continue;
      }
      if (line.startsWith('#') || line.startsWith('//')) {
        ++skipped;
        continue;
      }
      final rule = _ruleFromLine(line, source: source);
      if (rule == null) {
        ++invalid;
        continue;
      }
      rules.add(rule);
    }
    return _ParsedBatch(rules, skipped, invalid);
  }

  static _ParsedBatch _parseJson(String body, {String? source}) {
    final rules = <AdRule>[];
    var skipped = 0;
    var invalid = 0;
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      // Not JSON after all — fall back to the line grammar rather than
      // failing the refresh outright.
      return _parseLines(body, source: source);
    }

    Object? payload = decoded;
    List<Object?> allowEntries = const <Object?>[];
    if (decoded is Map) {
      payload = decoded['rules'] ?? decoded['ads'] ?? decoded['items'];
      final allowList = decoded['allow'];
      if (allowList is List) allowEntries = allowList;
    }
    if (payload is! List) {
      return _ParsedBatch(const <AdRule>[], 0, 1);
    }

    for (final entry in payload) {
      if (entry is String) {
        final line = entry.trim();
        if (line.isEmpty || line.startsWith('#') || line.startsWith('//')) {
          ++skipped;
          continue;
        }
        final rule = _ruleFromLine(line, source: source);
        if (rule == null) {
          ++invalid;
        } else {
          rules.add(rule);
        }
        continue;
      }
      final rule = AdRule.fromJson(entry);
      if (rule == null) {
        ++invalid;
        continue;
      }
      rules.add(
        rule.source == null && source != null
            ? AdRule(
                kind: rule.kind,
                pattern: rule.pattern,
                caseSensitive: rule.caseSensitive,
                source: source,
              )
            : rule,
      );
    }
    for (final entry in allowEntries) {
      AdRule? rule;
      if (entry is String) {
        final line = entry.trim();
        if (line.isEmpty || line.startsWith('#') || line.startsWith('//')) {
          ++skipped;
          continue;
        }
        rule = _ruleFromLine(line, source: source)?.copyWith(allow: true);
      } else {
        rule = AdRule.fromJson(entry)?.copyWith(allow: true);
      }
      if (rule == null) {
        ++invalid;
      } else {
        rules.add(rule);
      }
    }
    return _ParsedBatch(rules, skipped, invalid);
  }

  /// Turns one text line into a rule, or null when it is unusable.
  static AdRule? _ruleFromLine(String line, {String? source}) {
    final lower = line.toLowerCase();

    if (lower.startsWith('allow:')) {
      // An exception rule: a match is never blocked. Parsed as a normal rule
      // then flagged as an allow-list entry.
      final inner = _ruleFromLine(line.substring('allow:'.length), source: source);
      return inner?.copyWith(allow: true);
    }

    if (lower.startsWith('domain:')) {
      final host = line.substring('domain:'.length).trim();
      if (host.isEmpty) return null;
      return AdRule(kind: AdRuleKind.domain, pattern: host, source: source);
    }

    if (lower.startsWith('sender:')) {
      final id = line.substring('sender:'.length).trim();
      if (int.tryParse(id) == null) return null;
      return AdRule(kind: AdRuleKind.sender, pattern: id, source: source);
    }

    if (lower.startsWith('re:') || lower.startsWith('regex:')) {
      final pattern = line.substring(line.indexOf(':') + 1).trim();
      if (pattern.isEmpty) return null;
      return AdRule(kind: AdRuleKind.regex, pattern: pattern, source: source);
    }

    if (line.length >= 2 && line.startsWith('/')) {
      final lastSlash = line.lastIndexOf('/');
      if (lastSlash > 0) {
        final pattern = line.substring(1, lastSlash);
        final flags = line.substring(lastSlash + 1);
        if (pattern.isNotEmpty) {
          return AdRule(
            kind: AdRuleKind.regex,
            pattern: pattern,
            caseSensitive: !flags.contains('i'),
            source: source,
          );
        }
      }
    }

    return AdRule(kind: AdRuleKind.keyword, pattern: line, source: source);
  }
}

class _ParsedBatch {
  const _ParsedBatch(this.rules, this.skipped, this.invalid);

  final List<AdRule> rules;
  final int skipped;
  final int invalid;
}
