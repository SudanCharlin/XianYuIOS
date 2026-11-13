# 闲鱼小猪手 · iOS 版

闲鱼 iOS（`com.taobao.fleamarket`）任务自动化插件。业务链对齐安卓 LSPosed 模块
[`Lotuszn/piggyhand-fish`](https://github.com/Lotuszn/piggyhand-fish) v1.0.2，但实现方式
按 iOS 端重写：**借用宿主自身的 MTOP 协议栈直调接口**，不模拟 UI、不抓包改机。

- 目标 App：闲鱼 iOS 7.29.10（Bundle ID `com.taobao.fleamarket`，可执行文件 `Runner`）
- 运行环境：**非越狱 · 自签**（iOS 27.2 实测口径），不依赖 substrate / ellekit
- 产物：单个 `XianYuPiggyHand.dylib`

---

## 1. 为什么不用 substrate / ellekit

自签安装的 App 跑在非越狱环境，`MSHookMessageEx` / `MSHookFunction` 一律不可用
（依赖的 substrate 服务端不存在，注入即崩）。

本插件因此**完全放弃 Logos（`%hook`）**，所有挂钩走公开的 ObjC Runtime：

| 需求 | 非越狱可用手段 |
|------|----------------|
| 拦截某个 Objective-C 方法 | `method_setImplementation` / `method_exchangeImplementations` |
| 读取/调用任意类与方法 | `NSClassFromString` + `methodForSelector` + `IMP` 调用 |
| 加载时机 | `__attribute__((constructor))` + `UIApplicationDidFinishLaunchingNotification` |

编译时用 `-undefined dynamic_lookup`，不链接任何 hook 框架。

---

## 2. 原理

与安卓模块同构 —— 不自己实现签名、登录态、WUA、设备指纹，而是拿闲鱼自己的发送器：

```
MtopService.getInstance                     // 宿主 MTOP 协议栈单例
  → MtopExtRequest initWithApiName:apiVersion:
  → addBizParameter:forKey:                 // 业务参数
  → async_call:delegate:                    // 发送，sid/cookie/WUA 全由 SDK 附加
  → 回调 succeed:response: → response.json  // 拿到 ret / data
```

已从 `Runner` 二进制实证的调用面（`__objc_methlist` 直接解析所得，非猜测）：

```
MtopService        + getInstance                          -> MtopService*
MtopService        - async_call:delegate:                 v32@0:8@16@24
MtopService        - sync_call:                            @24@0:8@16
MtopExtRequest     - initWithApiName:apiVersion:           @32@0:8@16@24
MtopExtRequest     - addBizParameter:forKey:               @32@0:8@16@24
MtopExtRequest     - setIsEnableWUA:                       v20@0:8B16
MtopExtRequest     - setNetworkTimeout:                    @20@0:8i16
MtopExtResponse    - json / body / isSucceed
MtopExtRequestDelegate - succeed:response: / failed:response:
```

> 值得注意：`Runner` 里能搜到 333 个 `mtop.taobao.idle*` 接口字符串，但**没有**
> `idle.coin.*` / `olivertask` —— 说明赚钱任务页是 H5/Weex（DinamicX + Ariver）承载，
> 接口名由服务端下发，不在原生层。这不影响本方案：MTOP 是共用协议栈，
> 服务端只校验登录态与 WUA，不区分请求从原生页还是 H5 发出。

---

## 3. 功能

| 功能 | 接口 | 说明 |
|------|------|------|
| 每日签到 | `mtop.taobao.idle.coin.signin` v1.0 | |
| 玩一玩签到 | `mtop.taobao.idle.play.sign.in` v1.0 | 带 `playId=4` |
| 擦亮宝贝 | `mtop.taobao.idle.item.polish` v2.0 | `{"type":"originaljson"}` |
| 小店日福利 | `mtop.taobao.idle.startup.shop.daily.benefit` v1.0 | |
| 任务列表 | `mtop.taobao.idle.task.queryolivertasklist` v2.0 | `sceneId=496` |
| 触发任务 | `mtop.taobao.idle.task.uploadolivertasktrigger` v1.0 | |
| 领取奖励 | `mtop.taobao.idle.task.getolivertaskbenefit` v1.0 | |
| 浏览任务商品源 | `mtop.taobao.idlehome.idle.coin.nextfresh` v1.0 | |
| 搜一搜行为 | `mtop.taobao.idlemtopsearch.search` v1.0 | |
| 夺宝投注 | `mtop.taobao.idle.coin.lottery.feeds` / `.bet` v1.0 | 默认关闭 |

**刻意保留的两条反脆弱设计**（来自安卓侧实战日志）：

1. **字段闸** —— 触发请求要求 `fromToken` / `groupId` 齐全。云端对缺字段的请求固定回
   `PARAM_ILLEGAL` 且不扣次数，发了只会污染日志。
2. **毒化闸** —— 同一任务类型连续 2 次 PARAM 类失败，本轮不再发同类请求。

**已知不支持**：激励视频任务（`showAds`）。需要真实广告播放回调，协议层无法伪造，
插件会在日志里显式标注跳过，而不是伪造必然失败的请求。

---

## 4. 编译

### 方式 A：GitHub Actions（推荐，零环境依赖）

1. 把本目录推到 GitHub 仓库
2. Actions 会自动跑 `.github/workflows/build.yml`
3. 在 Artifacts 下载 `XianYuPiggyHand.dylib`

### 方式 B：本地 macOS

```bash
chmod +x build.sh
./build.sh        # 需要 Xcode Command Line Tools，产物 XianYuPiggyHand.dylib
```

### 方式 C：Theos

```bash
make package
```

---

## 5. 注入与自签

### 自动注入

```bash
python3 inject_dylib.py 闲鱼_7.29.10.ipa XianYuPiggyHand.dylib
# 产出 闲鱼_7.29.10_injected.ipa（未签名）
```

脚本做两件事，都不改动任何代码段：

1. 复制 dylib 到 `Payload/Runner.app/Frameworks/`
2. 在 Mach-O load commands 的空隙（`header 末尾 ~ __TEXT,__text` 之间，
   本例实测有 16336 字节空闲）追加一条 `LC_LOAD_DYLIB`，指向
   `@executable_path/Frameworks/XianYuPiggyHand.dylib`

文件总长度不变，现有段偏移全部保持。

### 手动注入（图形工具）

Sideloadly / ESign / Azule 都支持"添加 dylib"：把 `XianYuPiggyHand.dylib` 加进
`Frameworks` 列表后重新签名即可，不需要跑脚本。

### 签名

用你现有的自签流程（Sideloadly / zsign / ESign）对 App、`Frameworks/*.dylib`
（包含本插件）、以及各个 `.appex` 一并重签。**只签主二进制会导致插件加载失败。**

---

## 6. 使用

1. 安装并打开闲鱼，等首页加载完（MTOP 栈初始化 + 登录态就绪）
2. 右上角出现橙色「鱼」悬浮球，点击打开面板
3. 打开「启用插件」，按需勾选功能
4. 点「立即跑批」，或让它按「跑批间隔」自动执行

日志同时写入 App 沙盒 `Documents/ph_journal.log`。

### 参数从哪来

`fishAdCode`（城市码）/ `gps`（经纬度）/ `asac`（会话凭证）**不是硬编码**，而是
hook `MtopExtRequest -addBizParameter:forKey:` 时，从闲鱼自己发出的请求里抄下来的，
落盘到 `Documents/ph_loc.json` 冷启动可恢复。

抄不到就省略该字段 —— 服务端对缺字段请求照常服务（安卓侧 `{"version":4}` 单独发
`map.init` 也返回 SUCCESS），绝不用假值冒充。

---

## 7. 排障

| 现象 | 原因 | 处理 |
|------|------|------|
| 无悬浮球 | dylib 未加载 | 确认 `Frameworks/` 里有 dylib，且主二进制有对应 `LC_LOAD_DYLIB`；确认 dylib 已重签 |
| 日志 `MtopService 未找到` | 注入时机早于宿主初始化 | 插件会自动轮询 30 次（约 60s），停留在首页等一会 |
| 全部请求 `FAIL_SYS_SESSION_EXPIRED` | 登录态未就绪 | 先在 App 内正常登录一次，再点跑批 |
| 大量 `PARAM_ILLEGAL` | 任务列表字段形态变了 | 属正常降级，毒化闸会自动停发该类；等版本适配 |
| 闪退 | 签名不完整 / dylib 架构不符 | 确认 dylib 为 arm64，且所有 Mach-O 都重签过 |

---

## 8. 目录结构

```
XianYuPiggyHand/
├── PHCompat.h/.m       日志、配置、运行时工具、位置凭证捕获
├── PHMtop.h/.m         MTOP 直调客户端（含 delegate + block 双通道回调）
├── PHEngine.h/.m       任务引擎（业务链）
├── PHHUD.h/.m          悬浮球 + 控制面板
├── PHMain.m            入口：constructor、swizzle、自动跑批调度
├── inject_dylib.py     IPA / .app 的 dylib 注入器
├── build.sh            直接编译脚本
├── Makefile            Theos 工程
└── control / *.plist   打包元数据
```

---

## 9. 说明

仅供研究与个人学习用途。协议接口行为随时可能变化，插件对未知形态一律选择"不发请求"
而不是"发必然失败的请求"。使用产生的后果由使用者自行承担。
