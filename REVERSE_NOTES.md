# 逆向笔记 · 闲鱼 iOS 7.29.10

对象：`E:\Download\闲鱼_7.29.10_iOS睿睿.ipa`（183 MB）

---

## 0. 样本状态

解包后只有 `Payload/Runner.app`，无 `Payload/*.app` 之外的产物。

```
Runner                       190,218,496 B   arm64, MH_EXECUTE, cryptid=0（未加密）
Frameworks/
  ├── InjectIPA_Dylibs/libJailedShim.dylib
  ├── InjectIPA_Dylibs/libsubetrate.dylib
  ├── XianYuAdKiller.dylib     （头部被注入框架加密，非标准 Mach-O header）
  ├── libellekit.dylib
  ├── Flutter.framework / App.framework
  └── kun_bridge.framework
```

关键判断：**`LC_ENCRYPTION_INFO_64.cryptid = 0`** —— App Store 的 FairPlay 加密已被剥掉，
可以直接做静态分析。这是一份已被注入服务处理过的包（`InjectIPA_Dylibs` 是注入框架的
运行时组件），不是原始商店包。

| 项 | 值 |
|----|-----|
| Bundle ID | `com.taobao.fleamarket` |
| 可执行文件 | `Runner` |
| 版本 | 7.29.10 |
| MinimumOSVersion | 13.0 |
| 架构 | arm64（单架构，非 fat） |
| ObjC 类 | 21,713 |
| 选择器 | 265,313 |

> 注意：安卓包名是 `com.taobao.idlefish`，iOS 是 `com.taobao.fleamarket`，
> 写过滤配置时别混用。

---

## 1. 分析方法

二进制没有 chained fixups（只有 `LC_DYLD_INFO_ONLY`），所以 `__DATA` 里的指针
是**未加 slide 的原始 vmaddr**，可以按经典 objc2 结构直接遍历：

```
__objc_classlist → class_t*
  class_t:  isa(8) superclass(8) cache(8) vtable(8) data(8)
  data & ~7 → class_ro_t*
    class_ro_t: flags(4) instanceStart(4) instanceSize(4) reserved(4)
                ivarLayout(8) name(8) baseMethods(8) baseProtocols(8)
                ivars(8) weakIvarLayout(8) baseProperties(8)
    baseMethods → method_list_t: entsizeAndFlags(4) count(4) method_t[]
      entsizeAndFlags & 0x80000000 → relative 格式（12 字节/条，int32 偏移）
```

类方法要走 metaclass：`class_t.isa` 本身也是 `class_t`，取它的 `data & ~7` 再读
`baseMethods`。`MtopService + getInstance` 就是这样挖出来的（实例方法列表里没有它）。

两个脚本在 `tools/`：

- `macho.py` —— 段/节/section 定位、cstring 提取
- `objc_dump.py` —— classlist → 类名/方法/类型编码，输出 19 MB 的 `classes.json`

---

## 2. MTOP 协议栈（核心）

### 2.1 类清单

二进制里与 MTOP 相关的类 100+，真正的调用面只有 4 个：

| 类 | 角色 |
|----|------|
| `MtopService` | 协议栈单例 + 发送器 |
| `MtopExtRequest` | 请求对象（208 个方法，属性极全） |
| `MtopExtResponse` | 响应对象 |
| `MtopExtRequestDelegate` | 回调协议 |

旁支：`MtopApiRequest`（另一套更薄的封装，`async` / `sync`）、`MtopBridgePlugin`
（JSBridge 侧）、`MtopAuthAdapter`（登录态续期）。

### 2.2 方法签名（type encoding 原文）

```
MtopService (class)
  + getInstance                                  @16@0:8
  + getInstanceWithID:                           @24@0:8@16
  + getInstanceWithAccountSite:                  @24@0:8@16
  + registerExternalInstance:type:               B32@0:8@16Q24

MtopService (instance)
  - async_call:delegate:                         v32@0:8@16@24
  - async_call:delegate:startFilter:             v40@0:8@16@24@32
  - sync_call:                                   @24@0:8@16
  - sync_call:apiVersion:                        @32@0:8@16@24
  - before:startFilter: / after: / started:
  - succeed:response: / failed:response:
  - pendingRequest: / getRequest: / removeRequest:

MtopExtRequest
  - initWithApiName:apiVersion:                  @32@0:8@16@24
  - initWithApiName:apiVersion:bizID:            @40@0:8@16@24@32
  - addBizParameter:forKey:                      @32@0:8@16@24
  - addExtParameter:forKey:                      @32@0:8@16@24
  - addProtocolParameter:forKey:                 @32@0:8@16@24
  - setIsEnableWUA:                              v20@0:8B16
  - setIsNeedEcode:                              v20@0:8B16
  - setIsNeedAuth:                               v20@0:8B16
  - setNeedAuth:andAuthParam:                    @32@0:8@16@24
  - setNetworkTimeout:                           @20@0:8i16
  - setIsNotUseMainThreadCallback:               v20@0:8B16
  - setSucceedBlock:                             v24@0:8@?16
  - setFailedBlock:                              v24@0:8@?16
  - getRequestId / getApiName / getApiVersion
```

### 2.3 参数分层

`MtopExtRequest` 有三组参数容器，语义不同：

- **bizParameter** —— 进 `data` JSON，业务字段（对应安卓的 `paramMap`）
- **extParameter** —— 挂 URL query / 扩展字段
- **httpHeader** —— 请求头

安卓模块的 `ApiProtocol().paramMap(params)` 对应 iOS 的 `addBizParameter:forKey:`。

### 2.4 回调

两条通道并存，插件里做了去重：

1. delegate：`succeed:response:` / `failed:response:`
2. block：`setSucceedBlock:` / `setFailedBlock:`（`v24@0:8@?16`）

不同 MTOP 版本走哪条不一定，所以两边都挂，谁先到用谁。

---

## 3. 赚钱任务接口在哪

在 `__cstring` 里搜 `mtop.taobao` 命中 463 条，其中 `mtop.taobao.idle*` 333 条：

```
mtop.taobao.idlemessage.login.token
mtop.taobao.idlecommerce.game.iaa.check.award
mtop.taobao.idlecommerce.splash.ads
mtop.taobao.idle.location.citychange
mtop.taobao.idle.search.suggest
...
```

但 **`idle.coin` / `olivertask` / `polaris` 命中数为 0**。

结论：iOS 的钱包/赚钱任务页不在原生层，是 H5 / Weex（`DinamicX` + `Ariver` 容器）
承载，接口名从服务端配置下发，或用 `quickjs` 引擎在运行时拼。

这直接决定了实现路线：不能"hook 某个原生任务页的按钮"，只能走协议直调。
好消息是 iOS 与安卓共用同一套 MTOP 服务端，接口名和参数形状一致 —— 安卓侧
`piggyhand-fish` 已经用大量日志把形状试出来了，直接复用即可。

---

## 4. 从安卓侧继承的业务知识

`piggyhand-fish` 的价值不在代码结构，而在这几条用真实失败日志换来的约束：

### 4.1 496 场景触发体

```json
{"sceneId":496,"deliveryId":"...","fromToken":"...","groupId":...}
```

`fromToken` / `groupId` / `deliveryId` **任一为空** → 云端固定回 `PARAM_ILLEGAL`，
不扣任务次数。所以字段闸是必须的，不是优化。

> 源码注释原话：*109 条失败里 103 条是 PARAM_ILLEGAL，失败请求恰好都是
> fromToken/groupId 缺失的形状。*

### 4.2 领奖体

```json
{"sceneId":"496","deliveryId":"...","fishAdCode":"...","gps":"..."}
```

注意 `sceneId` 这里是**字符串** `"496"`，而触发请求里是**数字** `496`。
安卓侧两个调用点写法不同（`objJson("sceneId","496",...)` vs `Integer.parseInt`），
iOS 侧照抄这个差异。

### 4.3 SUCCESS ≠ 领到

`getolivertaskbenefit` 可能返回 `SUCCESS` 但 `taskBenefitDTO.needBenefit` 仍为
`"true"` 且 `rewards` 为空 —— 服务端没发奖。必须二次校验，否则会误报成功。

### 4.4 位置凭证

`fishAdCode` / `gps` / `asac` 从本机请求流量里抄，取不到就省略字段，不用假值。

### 4.5 任务状态机

```
ACCEPTED ──trigger──> COMPLETE ──benefit──> AWARD
```

- `AWARD` → 直接领
- `COMPLETE` + `needBenefit=true` → 领
- `ACCEPTED` → 按 `materialDTO.actionType` 分流触发：
  `clickFinish` / `EXCUTE` / `PLAINVISIT` / `VISIT` / `SYSTEM_SWITCH` /
  `idleCoinFeesAnchor`（浏览，走 `nextfresh` 商品池）/ `showAds`（视频，协议不可伪造）

---

## 5. 未解决 / 待验证

| 项 | 状态 |
|----|------|
| `addBizParameter:forKey:` 的值类型（NSString vs NSNumber） | 代码里对 `sceneId`/`groupId` 用 NSNumber 还原安卓的 int/long 形状，需真机回包验证 |
| 非越狱环境下 MtopService 是否要求主线程 | 已统一 dispatch 到主线程发送规避 |
| iOS 27.2 实际运行 | 未上机验证（本机无 macOS/设备） |
| 激励视频任务 | 协议层无解，已显式跳过 |
| 夺宝投注参数（`count` 等） | 沿用安卓默认值，未逐字段验证 |

---

## 6. 复现

```bash
# 1) 解包
unzip 闲鱼_7.29.10_iOS睿睿.ipa -d extracted

# 2) 确认未加密（cryptid 应为 0）
python tools/macho.py extracted/Payload/Runner.app/Runner

# 3) 还原全部 ObjC 结构
python tools/objc_dump.py extracted/Payload/Runner.app/Runner out/classes.json

# 4) 查任意类
python -c "import json;d=json.load(open('out/classes.json'));print(d['MtopService']['m'])"
```
