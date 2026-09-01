//
//  regex_engine.dart
//
//  Compiles ad-filter rules once and evaluates them against message text.
//
//  Two things drive the design here:
//
//  * Rules come from a remote list the user does not control, so a pattern
//    may be invalid or catastrophically slow. Every pattern is compiled
//    defensively and matched with a length guard; a bad rule is dropped, it
//    never throws.
//  * `matches()` is called for every message of a loaded transcript on each
//    incoming message, so the hot path must not allocate. Domain extraction
//    reuses one pre-compiled scanner and rules are walked in a flat loop.
//

import 'rule_model.dart';

/// Upper bound on the text handed to a user-supplied regular expression.
///
/// Dart's RegExp is a backtracking engine, so a pathological pattern against
/// a very long message can stall the isolate. Real ad copy is short; anything
/// past this is truncated before matching. Plain keyword and domain checks are
/// linear and therefore still run against the full text.
const int kAdFilterRegexTextLimit = 4000;

/// Pulls the hosts out of a message body.
///
/// Handles `https://host/...`, `http://host`, bare `www.host/...`, and
/// Telegram's schemeless `t.me/foo` links, which are the single most common
/// shape of a promoted-channel ad.
final RegExp _urlScanner = RegExp(
  r'(?:(?:https?://)?(?:www\.)?|t\.me/)([a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+)(?:[:/?#]|$)',
  caseSensitive: false,
);

/// A compiled rule with its case-folding already applied.
class _CompiledRule {
  const _CompiledRule.keyword(this.rule, this.needle)
      : regex = null,
        senderId = null;

  const _CompiledRule.regex(this.rule, this.regex)
      : needle = null,
        senderId = null;

  const _CompiledRule.domain(this.rule, this.needle)
      : regex = null,
        senderId = null;

  const _CompiledRule.sender(this.rule, this.senderId)
      : needle = null,
        regex = null;

  final AdRule rule;

  /// Lower-cased keyword or domain, null for regex/sender rules.
  final String? needle;

  final RegExp? regex;
  final int? senderId;
}

/// Holds the compiled form of a rule set.
///
/// An engine is immutable; [AdRuleEngine.withRules] returns a new one so the
/// service can swap rule sets atomically without a matching call ever seeing a
/// half-built engine.
class AdRuleEngine {
  const AdRuleEngine._(
    this._rules,
    this._needsFoldedText,
    this._needsRegexText,
    this._needsHosts,
  );

  static const AdRuleEngine empty =
      AdRuleEngine._(<_CompiledRule>[], false, false, false);

  final List<_CompiledRule> _rules;

  /// Precomputed at compile time: `matches()` runs once per message, so the
  /// "does this rule set need a folded copy / truncated copy / host scan"
  /// question must not be re-answered on every call.
  final bool _needsFoldedText;
  final bool _needsRegexText;
  final bool _needsHosts;

  int get length => _rules.length;

  bool get isEmpty => _rules.isEmpty;

  /// Compiles [rules], silently dropping anything that cannot compile.
  factory AdRuleEngine.withRules(Iterable<AdRule> rules) {
    final compiled = <_CompiledRule>[];
    var needsFolded = false;
    var needsRegex = false;
    var needsHosts = false;
    for (final rule in rules) {
      final entry = _compile(rule);
      if (entry == null) continue;
      compiled.add(entry);
      if (entry.senderId != null) continue;
      if (entry.regex != null) {
        needsRegex = true;
      } else if (rule.kind == AdRuleKind.domain) {
        needsHosts = true;
      } else if (!rule.caseSensitive) {
        needsFolded = true;
      }
    }
    return AdRuleEngine._(
      List<_CompiledRule>.unmodifiable(compiled),
      needsFolded,
      needsRegex,
      needsHosts,
    );
  }

  static _CompiledRule? _compile(AdRule rule) {
    final pattern = rule.pattern.trim();
    if (pattern.isEmpty) return null;

    switch (rule.kind) {
      case AdRuleKind.sender:
        final id = int.tryParse(pattern);
        if (id == null || id <= 0) return null;
        return _CompiledRule.sender(rule, id);

      case AdRuleKind.domain:
        // Stored folded: hosts are case-insensitive by definition, so the
        // rule's own caseSensitive flag has no meaning here.
        final host = _canonicalHost(pattern);
        if (host.isEmpty) return null;
        return _CompiledRule.domain(rule, host);

      case AdRuleKind.regex:
        final regex = _safeRegex(pattern, caseSensitive: rule.caseSensitive);
        if (regex == null) return null;
        return _CompiledRule.regex(rule, regex);

      case AdRuleKind.keyword:
        return _CompiledRule.keyword(
          rule,
          rule.caseSensitive ? pattern : pattern.toLowerCase(),
        );
    }
  }

  /// Tests one message. [senderId] may be null for messages without a
  /// resolvable sender; sender rules simply never match then.
  bool matches(String text, {int? senderId}) {
    if (_rules.isEmpty) return false;
    final hasText = text.isNotEmpty;

    // Fold once, not once per rule.
    final folded = _needsFoldedText ? text.toLowerCase() : '';
    final truncated = _needsRegexText && hasText
        ? (text.length > kAdFilterRegexTextLimit
            ? text.substring(0, kAdFilterRegexTextLimit)
            : text)
        : '';
    final hosts = _needsHosts && hasText ? _extractHosts(text) : const <String>[];

    for (final entry in _rules) {
      final senderIdOfRule = entry.senderId;
      if (senderIdOfRule != null) {
        if (senderId != null && senderId == senderIdOfRule) return true;
        continue;
      }

      final regex = entry.regex;
      if (regex != null) {
        if (hasText && regex.hasMatch(truncated)) return true;
        continue;
      }

      final needle = entry.needle;
      if (needle == null) continue;

      if (entry.rule.kind == AdRuleKind.domain) {
        for (final host in hosts) {
          if (host == needle || host.endsWith('.$needle')) return true;
        }
        continue;
      }

      if (!hasText) continue;
      if (entry.rule.caseSensitive) {
        if (text.contains(needle)) return true;
      } else if (folded.contains(needle)) {
        return true;
      }
    }
    return false;
  }

  /// Lower-cased hosts appearing in [text].
  static List<String> _extractHosts(String text) {
    final hosts = <String>[];
    for (final match in _urlScanner.allMatches(text)) {
      final host = match.group(1);
      if (host == null || host.isEmpty) continue;
      final canonical = _canonicalHost(host);
      if (canonical.isNotEmpty) hosts.add(canonical);
    }
    return hosts;
  }

  /// Strips a leading `www.` and folds to lower case.
  ///
  /// Also drops a trailing dot so a fully-qualified `example.com.` matches a
  /// rule written as `example.com`.
  static String _canonicalHost(String value) {
    var host = value.trim().toLowerCase();
    while (host.startsWith('www.')) {
      host = host.substring(4);
    }
    if (host.endsWith('.')) host = host.substring(0, host.length - 1);
    return host;
  }

  /// Hard cap on a single rule pattern.
  ///
  /// Guards against pathological input from a remote list that could blow up
  /// either compile time or, against a long message, backtracking time.
  static const int kAdFilterMaxPatternLength = 256;

  static RegExp? _safeRegex(String pattern, {required bool caseSensitive}) {
    var pat = pattern;
    var cs = caseSensitive;
    // Dart's RegExp has no inline flag syntax, so PCRE-style `(?i)` / `(?-i)`
    // (used by filters such as Nagram) would throw and the rule would be
    // dropped. Normalise them: `(?i)` flips to case-insensitive, `(?i:…)` and
    // `(?-i:…)` become plain non-capturing groups.
    if (pat.startsWith('(?i)')) {
      pat = pat.substring(4);
      cs = false;
    } else if (pat.startsWith('(?-i)')) {
      pat = pat.substring(5);
      cs = true;
    }
    pat = pat.replaceAll('(?i:', '(?:').replaceAll('(?-i:', '(?:');
    if (pat.isEmpty || pat.length > kAdFilterMaxPatternLength) return null;
    try {
      return RegExp(pat, caseSensitive: cs);
    } catch (_) {
      // Remote lists are user-supplied; an invalid pattern must not crash the
      // app or abort the whole refresh.
      return null;
    }
  }
}
