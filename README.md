# dsh-home-migration

> Moving a plugin host's home directory without silently breaking it — 15 failed rounds, 2 independent root causes, 1 gate that ends the loop.

> **脱敏说明（4 行）**：本仓库是那场真实搬迁的**脱敏通用版**——旧根一律写作 `<OLD_ROOT>`，新根写作 `<NEW_ROOT>`，
> 桶名里的编码形式写作 `--<OLD_ROOT-ENCODED>--` / `--<NEW_ROOT-ENCODED>--`，会话 ID 只保留前 8 位。
> 主机名、账户名、联系方式、密钥、凭据一律不出现；`tools\` 下的 PowerShell 保持纯 ASCII。
> 凡是当时**没有证据**的结论，正文里一律标注「未证」——这份文档的价值在于它不假装知道。

---

## 它解决什么

一个插件式宿主应用（这里叫 DSH）的「家」是一个目录：`<DSH_HOME>`。里面有 `sessions\`（会话日志）、
`profiles\`（两个壳各自的档案：桌面端 / 网页端）、工作区登记表、`logs\`、记忆库。

用户要的是**整盘搬走**：换盘符、换目录名，把两个壳指向同一个新家、共用一份记忆。

结果是**连续失败 15 轮**。每次切过去，宿主都能起来、体检全绿，然后**所有工作区操作**都报同一句：

```
active Service "workspaceController" is unavailable
```

真正的两个原因（各自都能单独掐断同一条服务链）：

| # | 雷 | 一句话 | 为什么难查 |
|---|---|---|---|
| ① | **桶碰撞** | `sessions\` 下同一个会话 ID 同时存在于旧名桶与新名桶 | 核心按设计**拒绝**该状态，且**不写任何日志** |
| ② | **工具盲区** | 搬迁工具 `sessionFiles()` **写死** `session.v4.jsonl.zstd`，只有 v4 那一代会话对它可见 | 工具自己报 `bad=0`，因为它只检查它认得的文件 |

**② 才是六轮都查不到的真凶。** 本机有 4 个会话**只有 v3**，它们从头到尾没被改写过：文件躺在**新名桶**里
（桶名 = 编码后的 cwd），而文件**头部记的 cwd 仍是旧路径** ⇒ 宿主启动时 `assertStoredIdentity()` 判定
「头里的 cwd」与「文件实际所在桶」不一致 ⇒ 抛 `corrupt session log ...` ⇒ `workspaceRegistry` 永不激活
⇒ 下游服务 pending ⇒ 用户看到那句 unavailable。

---

## 症状 → 判据（照这个查，别照症状猜）

| 你看到的 | 先量这个 | 判据 |
|---|---|---|
| 宿主起来了，但一切工作区操作报 `active Service "..." is unavailable` | `<home>\sessions\*\<会话目录名>` 的**重名数** | 同名出现在 **>1 个桶 = 致命**（exit 1）。读不到状态 = 失败，绝不当作「干净」 |
| 同上 | 用**修好的**工具跑 `apply` 后看它认了几个会话 | 数字比实际会话总数**小** ⇒ 工具盲区还在（实例：25 vs 实际 29） |
| 同上 | 一个会话文件的**头里 cwd** 与**它所在桶名解码出的路径** | 两者必须一致；不一致 ⇒ `corrupt session log` ⇒ 服务链断 |
| 「搬家后某个功能安静地没了」 | 目标目录里有没有那份**活数据**（实例：`_keys.json`） | **配置对 ≠ 数据在那**：引擎照常启动、体检全绿，**而里面是空的** |
| 「搬家后某条命令全都跑不了」 | 新目录的**所有者写入权限** | 报 `SetNamedSecurityInfoW failed (Win32 5)` ⇒ 补权限 + **回读验证** + 重跑原命令 |
| 「搬迁后一切都好」 | 关键配置文件里**还剩几处旧根字面量** | 旧根还在 ⇒ 它**照常能用**；旧根一删就**无声断掉**（实例：SSH 配置里的发布身份路径） |

**一条贯穿全文的判据**：**「没有日志」不是「没问题」**。桌面端宿主走另一条启动路径，它的 stderr
**从不落盘**；`logs\startup-*.log` 只在「宿主启动失败」时写。前六轮把「没有 startup 日志」当成了
「已排除」，这是本事故里最贵的一次误判。

---

## 目录

```
README.md                              主文（你在这里）
LICENSE                                MIT
docs/root-cause.md                     两颗雷的完整因果链（每一环给 包:行号 / 文件:函数）
docs/method.md                         「闸门先行」的搬迁方法与 11 步验收清单（照着做）
docs/timeline.md                       15 轮时间线：每轮做了什么、结果、留下了什么机制
tools/check-session-collisions.ps1     唯一的判据实现（纯 ASCII，fail-closed）
```

**建议阅读顺序**：先读 `docs/root-cause.md` 的「可复用判据」一节（5 分钟），
需要动手时读 `docs/method.md`，想知道那些判据是怎么被血换来的读 `docs/timeline.md`。

---

## 一分钟版

```powershell
# 1) 量碰撞（在任何复制/切换动作之前，以及之后各一次）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\check-session-collisions.ps1 -DshHome <home>
#    exit 0 = 可以继续；1 = 必须先在同一个停机窗口里解掉；2 = 读不到（= 失败）

# 2) 改写后必须核对「工具认得的会话数 == 实际会话数」
#    数字偏小 ⇒ 工具的可见范围就是它的盲区

# 3) 起宿主时必须捕获它的 stderr
#    唯一能看到「为什么某个服务没激活」的办法
```

---

## 贡献

两条要求，来自这次事故的教训：

1. **任何新的判据都必须在「干净路径」和「故障路径」上各跑一次。** 这次的闸门脚本第一版
   只在故障路径上正常——干净路径因为「空集合展开成 `$null`」直接崩了。**一个只在坏的时候工作的判据，
   会在你最需要它的时候撒谎。**
2. **`.ps1` / `.cmd` 保持纯 ASCII。** 无 BOM 的非 ASCII 脚本会被 PowerShell 5.1 读成乱码。

## License

MIT
