# MithkaX 广告过滤功能（本项目新增部分）

> 这是 **fork 自 [iebb/mithka](https://github.com/iebb/mithka) 的私有分支** `ylong2026/mithkaX`。
> 本文件只记录**我们加在上面的广告过滤功能**，不含上游 Mithka 本身的说明
> （上游说明见它自己的 README，同步时不会动这个文件，避免冲突）。
> 规则库 + 机器人那边见 `https://github.com/ylong2026/mithkaX-rules`。

---

## 1. 这功能到底是干什么的

一个**远程规则库驱动的 Telegram 广告/垃圾消息过滤器**：

- 你在 Telegram 里把广告/垃圾**转发给机器人** → 机器人（你自己的后端，用你的 AI Key）
  分类、去重、生成安全正则 → 入库到 `mithkaX-rules` 公开仓库的 `rules.json`。
- 本 App（MithkaX）在「设置 → 拦截 → 广告过滤」里填 `rules.json` 的 raw URL，
  定时（默认 30 分钟）或手动拉取，本地缓存后在**聊天消息 / 通知 / 会话列表**三处过滤。
- 支持**按类别开关**（机场 / 赌博 / 卖货 …… 哪类不想拦就关哪类）。
- 支持**白名单（allow）**：命中白名单的消息永不屏蔽，即使某条 block 规则也命中。

设计目标：**公众只转发、绝不碰线上规则**；所有入库由 Owner 复核，从源头防投毒。
完整治理见规则仓 `bot/DEFENSE.md`。

---

## 2. 架构（三个部分，各管各的）

```
┌─────────────────┐   转发广告   ┌──────────────────────────┐
│  Telegram 用户   │ ──────────▶ │  mithkaX-rules/bot (Python) │
└─────────────────┘             │  分类+去重+生成正则+Owner复核 │
                                 └────────────┬─────────────┘
                                              │  push rules.json (raw URL)
                                              ▼
┌─────────────────────────────────────────────────────────────┐
│  MithkaX App（本仓库）                                          │
│   lib/ad_filter/  ── 引擎：加载/编译/匹配/按类过滤              │
│   lib/settings/ad_filter_view.dart ── 设置 UI（URL/开关/类目）   │
│   调用点：chat_view_model / chat_list_view_model /             │
│           notification_controller / blocking_settings_view      │
└─────────────────────────────────────────────────────────────┘
```

- **本仓库（App）**：只消费 `rules.json`，不做任何规则生成。
- **`mithkaX-rules`（规则仓）**：规则真相源（`categories.json`）+ 生成器（`build.py`）+ 机器人（`bot/`）。
- **密钥只在规则仓的 `bot/config.py`**（BOT_TOKEN / OWNER_ID / 可选 AI Key），不在 App。

---

## 3. 我们改/加了哪些文件（接手第一眼要看的）

### 3.1 完全新增、零冲突的文件（上游永远不会动这些）

| 文件 | 作用 |
|---|---|
| `lib/ad_filter/rule_model.dart` | 规则数据模型（`AdRule`，含 `category` 字段） |
| `lib/ad_filter/regex_engine.dart` | 安全正则编译/匹配（自动剥 `(?i)`、限长、防 ReDoS） |
| `lib/ad_filter/rule_loader.dart` | 拉取+解析远程规则（纯文本 / JSON 两种格式） |
| `lib/ad_filter/ad_filter_service.dart` | 单例服务：规则集、持久化、定时刷新、**按类开关** |
| `lib/settings/ad_filter_view.dart` | 设置页 UI：URL、自动刷新、间隔、**按类别开关** |

### 3.2 在现有文件里插入的调用点（同步时唯一可能冲突的地方）

| 文件 | 改动 | 冲突风险 |
|---|---|---|
| `lib/chat/chat_view_model.dart` | `_isBlockedMessage` 加 `\|\| AdFilterService.shared.shouldBlock(...)` | 低（1 行插入） |
| `lib/chats/chat_list_view_model.dart` | 会话列表预览占位 | 低（几行） |
| `lib/notifications/notification_controller.dart` | 命中则抑制通知 | 低（十几行） |
| `lib/settings/blocking_settings_view.dart` | 加「广告过滤」入口行 | 低（十几行） |
| `lib/main.dart` | 启动时 `AdFilterService.shared.initialize(...)` + 开定时器 | 低（几行） |
| `lib/app/desktop_chat_window.dart` | 桌面副窗口同样初始化 | 低（2 行） |

### 3.3 i18n（新增 18 个 key，分布在 8 个语言文件）

- `translations/strings/<locale>/strings.xml`：新增 `adFilter*` 共 14 个 key（本次 `+4`：`adFilterCategorySection`/`Hint`/`Empty`/`Other`）。
- `lib/l10n/app_localizations.dart`：`AppStringKeys` 枚举 +N（**只用 `gen_assets.py` 生成，不要手改**）。
- `assets/l10n/<locale>.json`：由生成器产出。

> ⚠️ **i18n 铁律**：改文案只动 `translations/strings/*.xml`，然后跑
> `python3 translations/tools/gen_assets.py` 重新生成 `assets/l10n/*.json` 和
> `app_localizations.dart`，**永远不要手改这两个生成产物**。CI 用
> `python3 translations/tools/check.py` 校验 8 语言 key 一致。

---

## 4. 怎么改（常见维护动作）

### 加一条规则（不改代码）
1. 规则仓 `categories.json` 里对应类目 `rules` 数组追加一行（语法见规则仓 README）。
2. `cd mithkaX-rules && python3 build.py` → `git commit && git push`。
3. App 端 30 分钟内自动拉到，或点「立即刷新」。

### 加一个新类目
1. 规则仓 `categories.json` 的 `categories` 加一个对象（`id` + `label` + `rules`）。
2. `build.py` 会自动把 `category: <id>` 写进 `rules.json`。
3. App 端 `lib/settings/ad_filter_view.dart` 顶部 `kAdFilterCategoryLabels` 加一行中文标签
   （`kAdFilterCategoryOrder` 顺便排个序）。**不做这步也行**——未知类目会显示为原始 id。
4. 跑 `python3 translations/tools/gen_assets.py`（若加了需要翻译的文案）。

### 改 UI / 过滤逻辑
- 引擎与 UI 全在 `lib/ad_filter/`，自包含、不依赖聊天层（服务只吃纯文本 + senderId）。
- 按类开关状态存在 `AdFilterService._disabledCategories`（SharedPreferences 持久化），默认全开。

### 机器人 / 规则生成（在规则仓，不在本仓）
见 `mithkaX-rules/bot/README.md` 与 `bot/DEFENSE.md`。

---

## 5. 别人怎么接手（环境 + 构建）

```bash
# 1. 克隆并切到我们的分支
git clone https://github.com/ylong2026/mithkaX.git
cd mithkaX
git checkout master            # 我们的默认分支

# 2. Flutter 环境（与上游 Mithka 一致）
flutter pub get
flutter analyze               # 先过静态检查

# 3. 跑起来（iOS / Android / macOS / Windows / Linux）
flutter run

# 4. 体验广告过滤
设置 → 拦截 → 广告过滤 → 填规则库 URL：
https://raw.githubusercontent.com/ylong2026/mithkaX-rules/main/rules.json
开启「自动刷新」，或点「立即刷新」。
```

密钥？**App 端不需要任何密钥**。机器人密钥在规则仓（见第 6 节）。

---

## 6. 上游一键同步时的冲突（重点：已经是最小化）

**结论：我们的改动已经是最小冲突设计。** 核心逻辑全部是新增文件（`lib/ad_filter/`），
上游改它的代码不会碰到这些文件。冲突只可能出现在「3.2 的 6 个调用点」和「i18n 生成产物」。

推荐同步流程（每次上游发版时）：

```bash
# 1. 加好上游 remote（只做一次）
git remote add upstream https://github.com/iebb/mithka.git

# 2. 拉上游并合并（GitHub 网页的 "Sync fork" 等价命令）
git fetch upstream
git merge upstream/master          # 若有冲突，只在下面 6 个文件里

# 3. 解决冲突：只处理 3.2 的调用点
#    chat_view_model / chat_list_view_model / notification_controller /
#    blocking_settings_view / main / desktop_chat_window
#    每个都是「在过滤判断里加一行 shouldBlock」或「初始化里加一行」，
#    照原样把那段插入回去即可，逻辑没变。

# 4. i18n 永远重新生成，不手合：
python3 translations/tools/gen_assets.py

# 5. 校验 + 构建
python3 translations/tools/check.py
flutter pub get && flutter analyze && flutter run
```

**为什么 i18n 不会痛**：`app_localizations.dart` 和 `assets/l10n/*.json` 是生成产物，
同步后直接 `gen_assets.py` 覆盖，不用去 diff 上游改了哪行。

**为什么调用点冲突可控**：每个调用点都是「在已有判断里加一个 `||`」或「在初始化里加一行」，
属于最小侵入，review 一眼能看出该插回去哪。

---

## 7. 已知边界 / 注意事项

- `rules.json` 里**没有 `category` 字段的规则**（如外部 Nagram 导入）会归到「未分类」开关下。
- 白名单（`allow`）优先于屏蔽，且不受按类开关影响。
- 分类目前是**中文标签**写在 `kAdFilterCategoryLabels`（非 8 语言 i18n），便于维护；
  要全语言化就把那张表改成 i18n key。
- 上游若大幅重构聊天/通知层，3.2 调用点要按新接口重新接（逻辑不变）。
