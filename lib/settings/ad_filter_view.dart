//
//  ad_filter_view.dart
//
//  Ad filter settings: rule list URL, automatic refresh, and the refresh
//  interval. Rule editing itself lives in the keyword blocker screen — this
//  screen only owns where the ad list comes from and how often it is pulled.
//

import 'package:flutter/material.dart';
import 'package:mithka/l10n/app_localizations.dart';

import '../ad_filter/ad_filter_service.dart';
import '../components/app_icons.dart';
import '../components/app_interactive_surface.dart';
import '../components/toast.dart';
import '../components/ui_components.dart';
import '../theme/app_theme.dart';

/// Preset intervals offered in the picker, in minutes.
const List<int> kAdFilterIntervalChoices = <int>[15, 30, 60, 180, 720];

/// 已知类目 id → 中文标签。必须与 rules 仓 `categories.json` 的 id 对齐。
/// 未知类目（如外部源未打标的规则）直接显示其原始 id，避免误导。
const Map<String, String> kAdFilterCategoryLabels = <String, String>{
  'airport': '机场 / VPN / 代理 / 翻墙',
  'gambling': '赌博 / 博彩 / 棋牌',
  'adult': '黄色 / 卖片 / 约炮',
  'phishing_scam': '诈骗 / 杀猪盘 / 刷单',
  'selling': '卖货 / 微商 / 招代理',
  'finance_illegal': '非法贷款 / 套现',
  'proxy_service': '代办 / 代充 / 解封',
  'spam_link': '推广链接 / 拉群',
};

/// 类目在开关列表里的展示顺序：已知类目优先，未分类置底。
const List<String> kAdFilterCategoryOrder = <String>[
  'airport',
  'gambling',
  'adult',
  'phishing_scam',
  'selling',
  'finance_illegal',
  'proxy_service',
  'spam_link',
];

/// 类目开关的展示顺序：按已知顺序排，未知类目按字母补在中段，未分类永远置底。
List<String> orderedCategories(Map<String, int> breakdown) {
  final known =
      kAdFilterCategoryOrder.where((id) => breakdown.containsKey(id)).toList();
  final unknown = breakdown.keys
      .where((id) => id != 'uncategorized' && !kAdFilterCategoryOrder.contains(id))
      .toList()
    ..sort();
  final ordered = <String>[...known, ...unknown];
  if (breakdown.containsKey('uncategorized')) ordered.add('uncategorized');
  return ordered;
}

class AdFilterView extends StatefulWidget {
  const AdFilterView({super.key});

  @override
  State<AdFilterView> createState() => _AdFilterViewState();
}

class _AdFilterViewState extends State<AdFilterView> {
  final _urlController = TextEditingController();
  final _service = AdFilterService.shared;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    _urlController.text = _service.rulesUrl;
    _service.addListener(_onChanged);
  }

  @override
  void dispose() {
    _service.removeListener(_onChanged);
    _urlController.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _refresh() async {
    // Commit the field first: tapping "refresh" after typing a URL is the
    // obvious intent, and losing the edit would be surprising.
    _service.setRulesUrl(_urlController.text);
    if (_service.rulesUrl.isEmpty) return;
    setState(() => _refreshing = true);
    try {
      final added = await _service.refreshFromUrl();
      if (!mounted) return;
      showToast(
        context,
        added > 0
            ? AppStrings.t(AppStringKeys.adFilterRulesAdded, {
                'value1': added,
              })
            : AppStrings.t(AppStringKeys.adFilterRulesUpToDate),
      );
    } catch (_) {
      if (!mounted) return;
      showToast(context, AppStrings.t(AppStringKeys.adFilterRefreshFailed));
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: AppStrings.t(AppStringKeys.adFilterTitle),
      onBack: () => Navigator.of(context).pop(),
      child: SettingsListView(
        children: [
          _urlCard(),
          const SizedBox(height: AppSpacing.lg),
          SettingsSection(
            titleKey: AppStringKeys.adFilterAutoRefresh,
            rows: [
              SettingsSwitchRow(
                title: AppStringKeys.adFilterEnabled,
                value: _service.isEnabled,
                leading: const SettingsLeadingIcon(icon: HeroAppIcons.ban),
                onChanged: _service.setEnabled,
              ),
              SettingsSwitchRow(
                title: AppStringKeys.adFilterAutoRefresh,
                value: _service.isAutoRefreshEnabled,
                leading: const SettingsLeadingIcon(icon: HeroAppIcons.link),
                onChanged: _service.setAutoRefresh,
              ),
              SettingsRow(
                title: AppStringKeys.adFilterRefreshInterval,
                value: AppStrings.t(AppStringKeys.adFilterMinutes, {
                  'value1': _service.intervalMinutes,
                }),
                onTap: _pickInterval,
              ),
              SettingsRow(
                title: AppStringKeys.adFilterRefreshNow,
                // `value` is a non-nullable String, so a blank cell stands in
                // for "no status to show" while a refresh is in flight.
                value: _refreshing ? '' : _statusText(),
                showChevron: !_refreshing,
                onTap: _refreshing ? null : _refresh,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          _categorySection(),
          const SizedBox(height: AppSpacing.lg),
          SettingsNote(text: AppStringKeys.adFilterDescription),
        ],
      ),
    );
  }

  /// 按类别过滤：列出已加载规则里出现的类目，每个一个开关。
  /// 关闭某类目后，该类的屏蔽规则从引擎移除，这类广告不再被隐藏。
  Widget _categorySection() {
    final breakdown = _service.categoryBreakdown;
    final ordered = orderedCategories(breakdown);
    return SettingsSection(
      titleKey: AppStringKeys.adFilterCategorySection,
      rows: [
        if (ordered.isEmpty)
          SettingsNote(text: AppStringKeys.adFilterCategoryEmpty)
        else ...[
          SettingsNote(text: AppStringKeys.adFilterCategoryHint),
          for (final id in ordered)
            SettingsSwitchRow(
              title: _categoryLabel(id),
              value: _service.isCategoryEnabled(id),
              leading: const SettingsLeadingIcon(icon: HeroAppIcons.filter),
              onChanged: (enabled) => _service.setCategoryEnabled(id, enabled),
              subtitle: AppStrings.t(AppStringKeys.adFilterRuleCount, {
                'value1': breakdown[id] ?? 0,
              }),
            ),
        ],
      ],
    );
  }

  String _categoryLabel(String id) {
    if (id == 'uncategorized') {
      return AppStrings.t(AppStringKeys.adFilterCategoryOther);
    }
    return kAdFilterCategoryLabels[id] ?? id;
  }

  String _statusText() {
    final lastSync = _service.lastSyncAt;
    if (lastSync == null) {
      return AppStrings.t(AppStringKeys.adFilterNeverUpdated);
    }
    final stamp =
        '${lastSync.year}-${_two(lastSync.month)}-${_two(lastSync.day)} '
        '${_two(lastSync.hour)}:${_two(lastSync.minute)}';
    return AppStrings.t(AppStringKeys.adFilterLastUpdated, {
      'value1': stamp,
    });
  }

  static String _two(int value) => value.toString().padLeft(2, '0');

  Future<void> _pickInterval() async {
    final choice = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => _IntervalPicker(
        current: _service.intervalMinutes,
      ),
    );
    if (choice == null) return;
    _service.setIntervalMinutes(choice);
  }

  Widget _urlCard() {
    final c = context.colors;
    return SettingsPanel(
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
      child: Row(
        children: [
          AppIcon(HeroAppIcons.link, size: 19, color: AppTheme.brand),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: _urlController,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _refreshing ? null : _refresh(),
              style: TextStyle(fontSize: 15, color: c.textPrimary),
              decoration: InputDecoration(
                border: InputBorder.none,
                isCollapsed: true,
                hintText: AppStrings.t(AppStringKeys.adFilterRulesUrl),
                hintStyle: TextStyle(color: c.textTertiary),
              ),
            ),
          ),
          const SizedBox(width: 10),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _refreshing ? null : _refresh,
            child: Container(
              height: 34,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: _refreshing ? c.searchFill : AppTheme.brand,
                borderRadius: BorderRadius.circular(AppRadius.lg),
              ),
              child: _refreshing
                  ? const SizedBox(
                      width: 15,
                      height: 15,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(
                      AppStrings.t(AppStringKeys.adFilterRefreshNow),
                      style: TextStyle(
                        fontSize: 14,
                        color: AppTheme.onBrand,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _IntervalPicker extends StatelessWidget {
  const _IntervalPicker({required this.current});

  final int current;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SafeArea(
      child: Container(
        decoration: BoxDecoration(
          color: c.background,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final minutes in kAdFilterIntervalChoices)
              AppInteractiveSurface(
                semanticLabel: AppStrings.t(AppStringKeys.adFilterMinutes, {
                  'value1': minutes,
                }),
                onTap: () => Navigator.of(context).pop(minutes),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 15,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          AppStrings.t(AppStringKeys.adFilterMinutes, {
                            'value1': minutes,
                          }),
                          style: TextStyle(fontSize: 16, color: c.textPrimary),
                        ),
                      ),
                      if (minutes == current)
                        AppIcon(HeroAppIcons.check, size: 17, color: AppTheme.brand),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
