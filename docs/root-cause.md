# 根因：两颗独立的雷

> 本文件只写**有证据**的东西。每条判据后面都跟「怎么证出来的」；没证到的统一收在最后一节。
> 脱敏约定见 `README.md`。本文出现的桶名编码形式已替换为 `--<OLD_ROOT-ENCODED>--` / `--<NEW_ROOT-ENCODED>--`
> （真实形态长这样：`--E-~xxxx~xxxx~xxxx--`，把 cwd 里每个非 ASCII 码元写成 `~XXXX`、分隔符写成 `-`、外面包 `--`）。

---

## 0. 症状与它的形状

宿主（桌面端 app）能起来、能连上、体检全绿，然后**每一次**工作区操作都失败：

```
workspace create failed: gateway/service-unavailable: typert gateway: workspace/create:
active Service "workspaceController" is unavailable
```

这句话**不是在说数据坏了**，它是在说：**提供该服务的插件没被注册**。这一条是读实现得到的，
它把整类「文件损坏 / UI 缓存 / 注册表悬空」的假设都排除掉了（后来也确实逐条证否，见 `timeline.md` ㉖）。

---

## 1. 服务链：四环，任一环断，用户看到的就是同一句话

| 环 | 位置 | 行为 |
|---|---|---|
| 1 | `@deepseek-ai/dsh-session-persistence-jsonl/lib/index.js:2878`（`listArtifacts()`） | `if (ids.has(header.id)) throw new Error('duplicate JSONL session id "<id>" appears in multiple project directories')`。公开方法 `list()`（`:2454`）就是遍历 `listArtifacts()`（`:2858`）⇒ **一个重复 ID 就让 `list()` 必抛**。`:3204` 的 `findLog(id)` 是同一判据的第二处 |
| 2 | `@deepseek-ai/dsh-workspace/lib/index.js:314` / `:336` / `:729` | `WorkspaceRegistry static inject = ["storageDomain","sessionPersistence"]`；`Service.init` → `listStoredHeaders()` = `ctx.sessionPersistence.list()` ⇒ 上一步抛错 ⇒ **`workspaceRegistry` 永不激活** |
| 3 | `@deepseek-ai/dsh-api-workspace-controller/lib/index.js:657` | `static inject = ["typert","workspaceRegistry"]` ⇒ 依赖缺失 ⇒ **`workspaceController` 永不激活**；同链上 `dsh-api-session-controller` 亦报 `pending (waiting for service: workspaceRegistry)` |
| 4 | `@deepseek-ai/dsh-api-gateway/lib/index.js:743` | `if (!isObject(receiver)) throw new TypertGatewayError("gateway/service-unavailable", endpoint, "active Service ... is unavailable")` ⇒ **用户看到的那句话** |

**这条链的含义**：第 1 环有两种完全不同的坏法（重复 ID / 头与位置不符），**但它们在第 2–4 环上
产生的症状一模一样**。这就是为什么只修一颗雷会给人「修好了」的错觉，也是为什么必须把两个变量**分开验证**。

---

## 2. 雷 ①：桶碰撞（duplicate session id）

### 2.1 布局规则（可复用判据）

```
<home>\sessions\<桶名>\<条目名>\
桶名 = 把该会话 cwd 里每个非 ASCII 码元写成 "~XXXX"、分隔符写成 "-"、外面包 "--"
```

所以**桶名本身就是 cwd 的编码**。实测形态：

| 桶名 | 解码 |
|---|---|
| `--<OLD_ROOT-ENCODED>--` | 旧根的 cwd |
| `--<NEW_ROOT-ENCODED>--` | 新根的 cwd |

### 2.2 实测（这是定案的物证）

| 家 | 桶目录 | 会话条目 | 重复 ID | 闸门退出码 |
|---|---|---|---|---|
| 旧家 | 3 | 28 | **0** | 0 |
| 新家 | **6**（3 旧名 + 3 新名） | 28 | **27** | 1 |

**旧家从来没有这个状态。** 这就是「回滚之后一切正常、切过去就坏」的全部原因（就这颗雷而言）。

### 2.3 为什么每一轮都必然复发

- 切换的**增量复制**从旧家（在验收全绿前，旧家一直活着）把**旧名桶**搬进新家；
  而新家早先那一轮已经把桶改成了新名 ⇒ 同一个会话又变两份。
- 解碰撞（`resolve-bucket-collisions.mjs`）是**独立的一步**：
  - 重跑器里有这一步；
  - **主切换器原本没有**——而交接单让用户双击的正是它 ⇒ **点一次，坏一次**。
- 实证：「解碰撞从未在新家真正落过盘」——新家档案目录下**没有任何 `bucket-collision-backup-*`**，
  且 27 处重复**此刻仍在盘上**。

### 2.4 解碰撞的判据：谁是谁的超集

改写只动第一帧头部，**尾帧逐字节不变**（这正是改写函数自己验证的不变式）。所以：

- 对每个出现在多个桶里的条目名，解出各份的**帧尾**；
- **保留是其余超集的那一份**，其余 `renameSync` 进备份（**不删除**）；
- **没有超集 ⇒ 拒绝，且一个字都不写**（fail-closed）。

夹具实测：拒绝路径 → 退 1、**备份目录都没建**、树一字节未动；解碰撞路径 → 退 0，内容相同那对保留 A 桶、
超集在 B 桶那对保留 B 桶的超集（反方向选优也对）。

真实新家只读干跑：**26 处碰撞全部可判**，25 处两份内容完全相同；只有 `session-740bd340`（网页端会话）
不同——旧名 `4492936 B / 1203 帧` vs 新名 `4269596 B / 1153 帧`，**旧名是超集**。
`session-6c174f16`（只在新家生成的悬浮球会话）**不在碰撞列表**，被完整保留。

---

## 3. 雷 ②：工具盲区（真凶）

### 3.1 缺陷本体（`fix-paths.mjs`）

```js
// 修前
function sessionFiles(sessionDir) {
  return [ join(sessionDir, 'session.v4.jsonl.zstd') ];   // ← 写死 v4
}
```

⇒ **只有 v4 那一代的会话对 inspect / apply / verify 可见**。本机有 **4 个会话只有 v3**：

```
259ec281-…
7ee2958b-…
session-a63d3a20-…
session-ec907aa5-…
```

这 4 个文件从头到尾没被任何一趟改写碰过。它们躺在**新名桶**里，而**头里 cwd 仍是旧路径**。

### 3.2 宿主侧怎么炸

`dsh-session-persistence-jsonl` 的 `listArtifacts()` → `readGenerationHeader()` → **`assertStoredIdentity()`**：
它用 `generationLogPath(root, meta.cwd, meta.id, version)` 反算出「按头部 cwd，这个文件应当在哪里」，
再与文件**实际所在路径**比对。这 4 个文件对不上 ⇒ 抛：

```
corrupt session log "...\--<NEW_ROOT-ENCODED>--\<会话目录>\session.v3.jsonl.zstd":
  header id "<id>" and cwd identify "...\--<OLD_ROOT-ENCODED>--\<会话目录>\session.v3.jsonl.zstd"
```

⇒ 服务链第 2 环的 `init` 抛错 ⇒ 第 3、4 环依次失效 ⇒ 用户看到那句 unavailable。

### 3.3 修法

- 新增 `currentGeneration(sessionDir)`：扫 `session.v<N>.jsonl.zstd` 取**最大 N**；
  `sessionFiles()` 改用它（不再写死 v4）。
- 顺手把备份名从写死的 `.session.v4.jsonl.zstd` 改成**真实代名**——**备份不该说谎**。
  （这一条是这次事故里最容易被人觉得「不重要」的改动：一个名字写错的备份，会在下次取证时把人引向错误的一代。）

### 3.4 修复前后的对照（同一个家、同一个启动器、只改这一处）

| | 修前（00:35） | 修后（00:40） |
|---|---|---|
| 工具返回值 | `headers rewritten=24`（只认 25 个会话） | `headers rewritten=4 skipped=25`、**`verify: sessions=29 bad=0`** |
| stderr | `corrupt session log ...`（v3 那个）+ `dsh: warning: 4 entries did not activate` + `session-controller/workspace-controller: pending (waiting for service: workspaceRegistry)` | **无 `did not activate`、无 workspace 报错** |
| 其它 | — | PREFLIGHT PASS、端口正常监听、近 20 分钟无 `startup-*.log` |

**「`sessions=25`」这个数字本身就是指纹**：当你看到的会话数比你以为的少，
不要先怀疑「文件丢了」——先怀疑**工具的可见范围**。

---

## 4. 为什么前六轮查不到

1. **桌面端宿主是裸 `Start-Process` 起的，它的 stderr 不落任何文件。**
2. `logs\startup-*.log` 由 `@deepseek-ai/dsh/lib/bin.js` 的 `reportStartupFailure` 写，
   **只在宿主启动失败时落盘**；桌面端宿主走 `dsh-desktop-host` 这条路，**不写这份**。
3. 于是「没有 startup 日志」被误当成「没问题」的判据——**它是没有证据，不是没有问题**。
4. 真正把真相逼出来的动作只有一个：**把网页端接到新家、直接捕获那个宿主的 stderr**，让错误印在屏幕上。

**可复用的取证姿势**（顺序照做）：

```
① 起一个宿主，指向那个家，把 stdout/stderr 落盘（launch-with-log.ps1 就是干这个的）
② 或者直接：DSH_HOME=<家> powershell -File <根>\DSH\start-dsh.ps1
③ 读 stderr 找 `corrupt session log` / `did not activate` / `pending (waiting for service:`
④ 修 → 复起宿主 → 确认这两类行消失
```

`logs\app-stderr-*.log` **确实会落盘**（本次证实的）——所以「带记录仪拉起」不是仪式，是唯一的证据来源。

---

## 5. 可复用判据清单（按发现价值排序）

1. **「某服务 unavailable」= 提供它的插件没注册**，不是数据坏了。顺着 `inject` 链往上读实现，
   第一个 `init` 抛错的地方就是根因。
2. **持久化层的 `assertStoredIdentity`**：`<home>\sessions\<桶名>\<会话目录>\session.v<N>.jsonl.zstd`
   的**头里 cwd 必须与桶名解码出的路径一致**。桶名 = cwd 的编码，这是这个判据的全部依据。
3. **同名会话出现在 >1 个桶 = 致命**，且核心**不写日志**。用 `tools\check-session-collisions.ps1` 量它。
4. **「工具说 `bad=0`」只在「工具看得见的范围」内成立**。任何 `verify` 都要配一句
   「它认得的条目数 == 实际条目数」的交叉核对。
5. **「没有日志」≠「没问题」**。先确认这条启动路径**到底会不会写日志**。
6. **两颗雷必须分开验证**。修好一颗之后仍然坏，不代表「那颗不成立」，而代表**还有第二颗**。
7. **桶名变化 = 碰撞的指纹**。「旧名桶 + 新名桶并存」这个形态本身就说明增量复制与改名趟赛跑了。
8. **改名的替换不可靠时，桶/目录名要靠「读实现」而不是「猜规则」**；生成词（本地扩展的重放器、
   备份名）也一样要取**真实名字**，不要沿用旧硬编码。

---

## 6. 另一类「安静失效」：配置对 ≠ 数据在那

这一条不是那两个雷之一，但同一场事故里真实发生过，而且**后果比报错更危险**。

**形状**：引擎照常启动、体检全绿，**而记忆是空的**。

三条实证途径：

- **同步器是单向覆盖**：跑完同步**必须**补跑「改写趟」，否则已经改好的文件被旧树原文覆盖回去。
  实测 **40 个文件被重写**（含两个壳的 `cordis.patch.yml` 与启动脚本）⇒ 网页端把记忆根指向
  一个**当时并不存在的目录**，并**安静地现建了一个空记忆库**。
- **活库判据**：目标目录里**有现成的 `_keys.json` = 那才是活库**。改任何「根」之前先看这一条，
  改完重启第一件事是问引擎自己（`info`）：`root` 对不对、节点数与历史量级对不对得上。
- **改完必须回看真实状态**，不能只看退出码 0。

---

## 7. 诚实标注（未证 / 未做）

> 这一段是这份文档最重要的部分。原项目的交接文档一直保留这个传统：**证据不到就写「未定」，不写结论。**

1. **那句 `workspaceController is unavailable` 在本轮的最后一次出现，第二个原因未找到。**
   有据可查的物证：某一轮 `resolve-bucket-collisions.mjs --apply` 与重指脚本**真的跑过**
   （备份目录 `bucket-collision-backup-20261015-000449` 与 `session-path-backup-2026-10-15T16-04-51-881Z` 都在），
   新家 sessions 变为 3 桶 / 29 条目 / **重复 0**，工作区路径复核**通过**（3 个工作区 path 全部存在、无 cwd 失配），
   包名集合四组（92 / 187 / 240 / 6）**逐名一致**、服务链 13 个包两家都齐——
   **然后桌面端仍报同一句错。** 因此：「重复会话 ID」是**必要但不充分**原因。
   **不许再凭症状相似指认。**
2. **那一轮的宿主报错痕迹穷举全空**：新家 `logs\` 无 `startup-*.log`、无 app stdout/stderr（裸 `Start-Process` 起的）、
   崩溃日志最新时间早于事发、桥接调试日志末条为「ready=ok uptime=51s」。⇒ 第二个原因**没有留下证据**。
3. **仍未测的唯一结构变量**：新家位于「桌面端程序自己的**安装目录内**」（新根 ⊂ 程序所在目录），
   而旧家不在任何程序目录里。把程序复制进单元、使程序与数据互为**兄弟**的脚本（`prepare-app-copy.ps1`）
   就是为这个变量写的，**从未真正跑过**（单元里没有程序目录）。
4. **未证的可疑点**：宿主服务激活完成前就点了工作区（`workspaceRegistry.init` 要等 `storageDomain` +
   `sessionPersistence`，对 28 个会话逐个读头）。下次若再试，**起来后等 15 秒再点**。
5. **便携性缺口（既存，与本故障无关）**：`profiles\node_modules` 里 164 个联接仍指向
   `<CACHE_ROOT>\_npx\<some-hash>`（另一处记录为 482 个）。「整盘搬走」≠「换台机器能跑」。
   要真便携，需在**停机窗口**里对 profile 做一次真实安装（运行时不许动 profile）。
6. **老根 / 新根双向分叉依旧存在**（新家独有 4 个记忆节点等），本轮未处理——那是记录，不是配置。
7. **自动回滚的失败路径无法在切换前真实触发**（要触发就得真切一次）。它是薄封装，被调用的几个函数
   各自经过静态复核或干跑。
8. **两联接之间的窄缺口**：「第一个联接已改、第二个改失败」不触发自动回滚（置位语句在两个联接都成功之后），
   会留下「一半在新家、一半在旧家」。窗口极窄（建联接是毫秒级），再双击一次重跑器即可恢复。未改。
9. 本仓库里的路径均为**占位符**；文中出现的具体数字（会话数、文件数、字节数、节点数）来自当时的实测记录，
   **不保证在别的机器上重现**。
