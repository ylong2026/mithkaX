import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../ad_filter/ad_filter_service.dart';
import '../components/app_icons.dart';
import '../components/ui_components.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_motion.dart';
import '../theme/app_theme.dart';
import '../theme/theme_controller.dart';
import 'ad_filter_view.dart';
import 'blocked_user_service.dart';
import 'country_message_filter.dart';
import 'country_message_filter_view.dart';
import 'keyword_blocker_view.dart';

class BlockingSettingsView extends StatelessWidget {
  const BlockingSettingsView({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<ThemeController>();
    final country = CountryMessageFilter.shared;
    return SettingsPageScaffold(
      title: AppStringKeys.settingsContentFilters.l10n(context),
      onBack: () => Navigator.of(context).pop(),
      child: ListenableBuilder(
        // The ad filter refreshes on its own timer, so the rule count shown
        // here has to track it as well as the country filter.
        listenable: Listenable.merge(<Listenable>[
          country,
          AdFilterService.shared,
        ]),
        builder: (context, _) => SettingsListView(
          children: [
            _card(context, [
              SettingsSwitchRow(
                title: AppStringKeys.appearanceHideBlockedUserMessages,
                value: theme.hideBlockedUserMessages,
                leading: const SettingsLeadingIcon(icon: HeroAppIcons.eyeSlash),
                onChanged: (value) {
                  theme.hideBlockedUserMessages = value;
                  BlockedUserService.shared.enabled = value;
                  if (value) {
                    BlockedUserService.shared.loadBlockedUsers();
                  }
                },
              ),
              SettingsRow(
                title: AppStringKeys.keywordBlockerTitle,
                leading: const SettingsLeadingIcon(icon: HeroAppIcons.ban),
                onTap: () => Navigator.of(context).push(
                  AppPageRoute<void>(
                    pageBuilder: (_, _, _) => const KeywordBlockerView(),
                  ),
                ),
              ),
              SettingsRow(
                title: AppStringKeys.adFilterTitle,
                value: AppStrings.t(AppStringKeys.adFilterRuleCount, {
                  'value1': AdFilterService.shared.ruleCount,
                }),
                leading: const SettingsLeadingIcon(icon: HeroAppIcons.filter),
                onTap: () => Navigator.of(context).push(
                  AppPageRoute<void>(
                    pageBuilder: (_, _, _) => const AdFilterView(),
                  ),
                ),
              ),
            ]),
            SettingsSection(
              titleKey: AppStringKeys.blockingCountry,
              rows: [
                SettingsRow(
                  title: AppStringKeys.blockingCountry,
                  value: country.selectedCountries.isEmpty
                      ? AppStringKeys.blockingCountryOff
                      : AppStrings.t(AppStringKeys.blockingCountrySelected, {
                          'value1': country.selectedCountries.length,
                        }),
                  leading: const SettingsLeadingIcon(icon: HeroAppIcons.globe),
                  onTap: () => Navigator.of(context).push(
                    AppPageRoute<void>(
                      pageBuilder: (_, _, _) =>
                          const CountryMessageFilterView(),
                    ),
                  ),
                ),
              ],
            ),
            const SettingsNote(text: AppStringKeys.blockingCountryDescription),
            SettingsSection(
              titleKey: AppStringKeys.blockingExemptions,
              dividerInset: AppMetric.settingsTextDividerInset,
              rows: [
                SettingsSwitchRow(
                  title: AppStringKeys.blockingExemptCommonPrivateGroup,
                  value: country.exemptCommonPrivateGroup,
                  onChanged: country.setExemptCommonPrivateGroup,
                ),
                SettingsSwitchRow(
                  title: AppStringKeys.blockingExemptThreeCommonGroups,
                  value: country.exemptThreeCommonGroups,
                  onChanged: country.setExemptThreeCommonGroups,
                ),
                SettingsSwitchRow(
                  title: AppStringKeys.blockingExemptPlainText,
                  value: country.exemptPlainText,
                  onChanged: country.setExemptPlainText,
                ),
                SettingsSwitchRow(
                  title: AppStringKeys.blockingExemptNonDefaultAvatar,
                  value: country.exemptNonDefaultAvatar,
                  onChanged: country.setExemptNonDefaultAvatar,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _card(BuildContext context, List<Widget> children) =>
      SettingsCard.rows(rows: children);
}
