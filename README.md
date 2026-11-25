# LiqTab

抖音液态悬浮底栏插件，专为 **iOS 16.3.1 + 巨魔（TrollStore）** 环境适配，目标抖音版本 **41.2.0**（工作区中 `抖音_41.2.0.ipa` 即为该版本砸壳包）。

参考项目 [DYKiller](https://github.com/HierarchThurs/DYKiller) 的玻璃底栏最低支持 iOS 26+，原因是它直接调用 iOS 26 的 `UIGlassEffect` / `_UITabBarPlatterView` 等系统私有玻璃渲染栈。本插件**不依赖这些 API**，而是：

1. 用公开的 `UIVisualEffectView` + `UIBlurEffect`（系统材质）+ 自适应色调 + 高光描边 + 投影，在 iOS 15/16 上手绘出接近「液态玻璃」的悬浮胶囊底栏；
2. 可选强制开启抖音 **41.2.0 自带的** `aiDouyinEnableFakeLiquidGlass` / `aiDouyinEnableLiquidGlass` ABTest 开关（抖音内部其实已经写了 fake liquid glass 实现，只是默认没开），两条路径相互补充。

**只做液态底栏这一个功能**，不修改评论区、分享面板、播放页等其它 UI。

---

## 特性

- **抖音设置页内直接调整**：进入 抖音「设置」→ 最上方「LiqTab 液态底栏」→ 即可切换材质、模糊强度、尺寸，无需 Filza / 无需重启抖音（与 DYYY 的设置入口共存）
- 悬浮胶囊底栏，圆角连续曲率（continuous corner），磨砂/清透质感可调
- 独立圆形相机（+）键，与 DYKiller 的布局思路一致
- 自动镜像抖音原生底栏的：标题、图标、红点/角标、选中态、图标着色（取抖音自身选中标签文字颜色）
- 点击回调转发给抖音自己的控制器方法（`plusTabBarButtonDidClick:` / `tabBarButtonDidTouchUpInside:gestureRecognizer:`），保证选中态、页面跳转与原生一致
- 隐藏原生底栏像素但保留其视图与代理逻辑
- 自适应深色/浅色、减弱透明度（Reduce Transparency）与减弱动态效果（Reduce Motion）
- 三种模式：自动（默认）、纯自绘、仅开启抖音自带开关
- **零依赖**：不用 Substrate / Logos / 首启注入，纯 Objective-C Runtime method swizzling，和 TrollFools / azule  Injection 兼容

---

## 目录结构

```
LiqTab/
├── Makefile                 # Theos library.mk 工程（无 tweak.mk / 无 Substrate 依赖）
├── control                  # 包控制信息
├── Sources/
│   ├── LiqTabInternal.h     # 内部声明、偏好设置键
│   ├── LTPrefs.m            # NSUserDefaults 偏好读取
│   ├── LTCustomGlassView.m  # iOS 16 可用的玻璃效果合成
│   ├── LTTabItemView.m      # 单个底栏按钮（图标 / 文字 / 角标）
│   ├── LTTabBarMirror.m     # 镜像抖音底栏到悬浮胶囊的核心逻辑
│   ├── LTNativeGlassEnabler.m # 强制开启抖音自带液态玻璃 ABTest flag
│   ├── LTSettings.m         # 在抖音设置页注入 LiqTab 设置入口与开关面板
│   └── Tweak.m              # constructor 入口，安装 swizzling
└── README.md                # 本文件
```

---

## 构建（无需 Mac，用 GitHub Actions 云端构建）

本项目已配置好 GitHub Actions，用 GitHub 免费的 macOS 云主机自动编译，**你不需要有自己的 Mac**。

1. 注册 / 登录 GitHub，点击右上角 **+** → **New repository**，例如命名为 `LiqTab`。当作**公开仓库**即可（不要放进任何隐私内容）。创建时不要勾选 README / .gitignore / license（本地已有），直接 Create repository。

2. 在你电脑上打开 Git Bash，进入项目目录并推送（把 `YOUR_USERNAME` / `LiqTab` 换成你的用户名和仓库名）：

   ```bash
   cd "C:/Users/Yang/Desktop/LiqTab"
   git init
   git add .
   git commit -m "LiqTab initial"
   git branch -M main
   git remote add origin https://github.com/YOUR_USERNAME/LiqTab.git
   git push -u origin main
   ```

   > `.gitignore` 已自动排除 720MB 的 `抖音_41.2.0.ipa` 和构建产物，不会被上传。如果 `git add .` 提示该文件太大，确认 `.gitignore` 已存在。

3. 打开你的 GitHub 仓库页面 → **Actions** 标签 → 左侧点击最新的 **Build LiqTab dylib** 工作流 → 等待约 2–5 分钟变成绿色 ✅。

4. 点击这次运行，页面底部 **Artifacts** 处下载 `LiqTab-ios16-arm64`（一个 zip）。解压后得到：
   - `LiqTab.dylib` —— 注入用的动态库
   - `com.yang.liqtab_1.0.0_iphoneos-arm64.deb` —— 安装包（一般不需要）

5. 把 `LiqTab.dylib` 传到手机，用 TrollFools 注入抖音即可（见下方“安装到巨魔环境”）。

以后只要修改了任何源码并 `git push`，GitHub 会自动重新构建，你再下载新 artifact 即可。也可以在 Actions 页面点 **Run workflow** 手动触发。

### 本地构建（如果你后来有了 Mac 或 Linux）

```bash
cd LiqTab
make clean
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
```

产物：`packages/com.yang.liqtab_1.0.0_iphoneos-arm64.deb`，dylib 在 `.theos/obj/`。

---

## 安装到巨魔环境（以 TrollFools 为例）

> 前提：你的抖音 41.2.0 已经用 TrollStore 安装（巨魔），且 IPA 未破坏签名结构。

1. 在手机上打开 **TrollFools**。
2. 选择 **抖音** → **注入** → 选择编译好的 `LiqTab.dylib`（从 deb 中解包得到，或直接用 clang 编译的 dylib）。
3. 等待注入完成，TrollFools 会自动重新签名并刷新应用注册。
4. 完全退出抖音后台，重新打开。底栏应自动变为悬浮胶囊玻璃。

也可以用 `azule` 或 `Sideloadly` 的 tweak injection 功能注入同一个 dylib。因为本插件不依赖 Substrate，任何能向 IPA 注入 dylib 的工具都可以。

---

## 在抖音设置里调整（推荐）

像 DYKiller 一样，LiqTab 会在抖音设置页注入入口：

1. 打开抖音 → **我** → **右上角三横线** → **设置**
2. 页面最上方会出现 **「LiqTab 液态底栏」** 分区（DYYY 入口旁边）
3. 点进去可以调：
   - **启用液态底栏**（总开关）
   - **玻璃外观**：自动 / 乳白磨砂 / 深色磨砂
   - **模糊强度**：清透 / 薄磨砂 / 标准磨砂 / 厚磨砂 / 纯深色
   - **显示选中胶囊**
   - **点击震动反馈**
   - **左右边距 / 胶囊高度**
4. 改动**即时生效**，不用重启抖音

> 与 DYYY 共存：DYYY 的设置入口也在同一页面，两个入口会同时显示，互不覆盖。

## 高级配置（可选）

所有配置都写在 NSUserDefaults suite `com.yang.liqtab`（用 `defaults write` 或任意偏好设置 App 修改），修改后重启抖音生效：

| Key | 类型 | 默认 | 说明 |
|---|---|---|---|
| `LiqTab.enabled` | BOOL | YES | 总开关 |
| `LiqTab.mode` | Int | 0 | 0=自动，1=纯自绘，2=仅强制抖音自带开关 |
| `LiqTab.sideInset` | Float | 14 | 胶囊距屏幕左右边缘距离(pt) |
| `LiqTab.bottomInset` | Float | 14 | 胶囊距屏幕底部（含 Home Indicator）距离(pt) |
| `LiqTab.barHeight` | Float | 58 | 胶囊高度(pt)，范围 44–80 |
| `LiqTab.cornerRadius` | Float | 0 | 0=胶囊（高度一半），>0=自定义圆角 |
| `LiqTab.blurStyle` | Int | 0 | 0=UltraThin，1=Thin，2=Material，3=Thick，4=Dark |
| `LiqTab.showLabels` | BOOL | YES | 是否显示按钮文字 |
| `LiqTab.haptics` | BOOL | YES | 点击轻微震动反馈 |
| `LiqTab.debugLog` | BOOL | NO | 打开 NSLog 调试日志 |
| `LiqTab.forceNativeFlags` | BOOL | YES | 是否强制开启抖音自带液态玻璃 ABTest 开关 |

示例：改成更清透、更窄的胶囊：

```
defaults write com.yang.liqtab LiqTab.blurStyle -int 0
defaults write com.yang.liqtab LiqTab.sideInset -float 20
defaults write com.yang.liqtab LiqTab.barHeight -float 54
killall Aweme
```

> 注意：NSUserDefaults suite 在沙盒内，直接在电脑端 `defaults write` 对手机无效；需在手机上的偏好设置 App（如 Preferences）或写一个小的注入辅助工具来改。

---

## 三种模式说明

- **模式 0（自动，默认）**：同时开启抖音自带的 fake liquid glass 开关，并安装自绘玻璃胶囊。如果你发现抖音自带实现已经生效且效果更好，可以切到模式 2。
- **模式 1（纯自绘）**：不注入 ABTest，只使用自绘玻璃（适合抖音自带实现有 bug 时）。
- **模式 2（仅原生）**：只强制 ABTest 开关，完全不创建自绘底栏。适合想验证抖音自带 fake liquid glass 效果的用户。

由于我无法在你的设备上实机测试，建议先尝试 **模式 2**，看抖音自带开关是否能在 iOS 16.3.1 上直接出效果；如果不能，再回到模式 0 或 1 使用自绘玻璃。

---

## 实现细节与兼容性说明

### 为什么不能直接用 DYKiller 的代码？

DYKiller 的玻璃底栏本质是：创建一个真正的 `UITabBar`，让 iOS 26 的 floating tab bar provider 自动生成 `_UITabBarPlatterView` 玻璃背板，然后用 `UIGlassEffect` KVC 修改玻璃材质。整个渲染栈（`UIGlassEffect`、`UICornerConfiguration`、`tabBarMinimizeBehavior`、`_UITabBarPlatterView.glassEffect`）在 iOS 16 上都不存在，所以无法移植。本插件保留它的**架构思路**（挂在 `AWENormalModeTabBar` 的 `layoutSubviews`、镜像按钮、转发点击、隐藏原生像素），但玻璃部分完全自绘。

### 抖音端 hook 点（均通过字符串/KVC 访问，无硬链接私有符号）

- 主类：`AWENormalModeTabBar`（41.2.0 中存在，DYKiller 同样 hook 它），hook `layoutSubviews`
- 按钮数组：`[tabBar valueForKey:@"tabBarButtons"]`
- 标题：`innerView.label.text` → `currentTitleText` → `accessibilityLabel`
- 类型：`type == 2` 视为相机（+）按钮，单独做圆形键
- 角标：`badge` / `badgeText` / `badgeNumber`，或扫描 `AWENormalModeTabBarBadgeContainerView`
- 点击转发：控制器方法 `plusTabBarButtonDidClick:` 与 `tabBarButtonDidTouchUpInside:gestureRecognizer:`
- ABTest 注入：`AWEABTestManager` 的 `setAbTestData:`（参考 DYYY 的做法，仅注入两个 key，带防重入保护）

### iOS 26 液态玻璃在 iOS 16 上的还原边界

真正的 `UIGlassEffect` 包含：背景模糊 + 折射（lens deformation）+ 色散 + 高光边缘 + 基于亮度的自适应 + 触摸形变（SDF + CABackdropLayer 新特性）。其中折射、色散、亮度采样、SDF 形变**无法用 iOS 16 公开 API 实现**。本插件还原的是：模糊、高光描边、圆角外形、投影、触摸选中胶囊动画、深浅色自适应。视觉上在正常使用距离可以读作「悬浮玻璃底栏」，但不会有 iOS 26 那种动态折射效果。

---

## 排障

- **底栏没变化**：检查 `LiqTab.enabled` 是否为 YES；确认抖音是通过 TrollStore 安装且 dylib 已成功注入（TrollFools 注入列表里能看到）。建议打开 `LiqTab.debugLog` 后重启抖音，通过控制台（`libimobiledevice` 的 `idevice syslog` 或 Console.app）查看 `[LiqTab]` 日志。
- **出现两套底栏 / 点击错乱**：说明原生底栏没有完全隐藏。这是因为某些抖音版本底栏类名不同。可用 Filza 查看 `/var/containers/Bundle/Application/.../Aweme.app/Frameworks/AwemeCore.framework/AwemeCore` 中是否包含 `AWENormalModeTabBar`（工作区 IPA 已确认存在）。
- **想彻底关闭原生开关注入**：设置 `LiqTab.forceNativeFlags` 为 NO，或 `LiqTab.mode` 为 1。
- **崩溃**：先尝试模式 1（纯自绘）并关闭 `forceNativeFlags`，以隔离 ABTest 注入的影响。

---

## 参考与致谢

- [DYKiller](https://github.com/HierarchThurs/DYKiller) — 悬浮玻璃底栏架构与抖音 hook 点参考
- [DYYY](https://github.com/Wtrwx/DYYY) — `AWEABTestManager` ABTest 字典注入参考
- [少数派：探寻 Liquid Glass 的实现原理](https://sspai.com/post/100983) — 液态玻璃渲染栈逆向分析
- Apple 开发者文档：`UIVisualEffectView`、`UIBlurEffect`、`UIVibrancyEffect`

---

## 免责声明

本项目仅供学习、研究与个人自用，不得用于商业用途。修改第三方应用可能违反其服务条款，请自行承担风险。作者不对账号异常、数据丢失或设备损坏承担任何责任。
