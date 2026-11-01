# dsh-superagent 插件安装操作说明（Windows）

> 适用环境：Windows 10/11 + DeepSeek Harness（`dsh` 0.2.1-rc.5）
> 目标：把 [dsh-superagent-prototype](https://github.com/deepseek-ai/dsh-superagent-prototype) 作为 DSH bundle 插件安装进一个独立的 `superagent` profile，并让它跑起来。
> 本文记录实际安装过程、**必须打的 Windows 源码补丁**，以及踩过的坑和对应解法，供复现或排障时对照。

---

## 0. 结论速览

插件已安装并运行成功（2026-11-01 复测通过）：

- 源码/构建产物：`C:\Users\1\Documents\deepseek-harness\default-workspace\dsh-superagent`
- profile 目录：`C:\Users\1\.dsh\profiles\superagent`
- 状态目录：`C:\Users\1\.dsh\state\superagent`（`orchestrator.sqlite` 等）
- 启动器：`C:\Users\1\Documents\deepseek-harness\default-workspace\start-superagent.cmd`（见 §2 步骤 8）
- 面板：`http://127.0.0.1:3082/?token=...`（侧边栏选 **Superagent**；token 每次重启都变，以日志为准）
- 当前 setup 状态：`setup.problem: null`；`accounts.repository: hufeide/dsh_superagent_me`，`accounts.agent: hufeide`
- 当前健康状态：`health.runtime / github / 其余` 全部 `ready`（github：`0 notifications; next poll ≥ 60s`）

> ⚠️ **最关键的一条**：仓库源码在 Windows 下有 **4 处必须打补丁** 才能激活，否则会看到
> `Workspace path is not fully qualified`、`tools.restrict() names unknown global tool "bash"` 之类报错，插件永远停在 "did not activate"。补丁内容见 §2 步骤 3。

---

## 1. 前置条件

| 依赖 | 本机实测 | 说明 |
| --- | --- | --- |
| Node.js | v24.21.0 | 需 `^22.19.0 || >=24.0.0`（`engines`） |
| pnpm | 11.7.0（全局）/ 11.28.5（DSH 自带） | `packageManager` 指定 11.7.0 |
| git | 2.47.1 | 需 ≥ 2.32；同时提供 POSIX `env.exe`（见步骤 8） |
| Python | 3.12.8 | 插件管理脚本用 Python，但 Windows 下**不可用**，见 §5 |
| `dsh` CLI | 0.2.1-rc.5 | 位于 `...\resources\runtime\cli\bin\dsh.cmd`（本机在 `E:\Users\1\AppData\Local\Programs\DeepSeek Harness\...`） |
| GitHub CLI | 2.102.0 | 真正接 GitHub 时才需要（本机 `C:\Program Files\GitHub CLI\gh.exe`） |

`DSH_HOME` 默认为 `C:\Users\1\.dsh`（profile 存放位置）。

---

## 2. 安装步骤（标准流程）

### 步骤 1：克隆仓库

```powershell
cd C:\Users\1\Documents\deepseek-harness\default-workspace
git clone https://github.com/deepseek-ai/dsh-superagent-prototype.git dsh-superagent
```

### 步骤 2：安装依赖

```powershell
cd dsh-superagent
pnpm install
```

> ⚠️ 如果这里或构建时报 `Cannot find package 'ansis' imported from ...\node_modules\tsdown\...`，
> 说明 pnpm 的**隔离链接器**在本机沙箱/权限环境下生成的 reparse point 无法被 Node 遍历。
> 改用 **hoisted** 扁平链接器重装：

```powershell
pnpm install --node-linker=hoisted
```

### 步骤 3：打 Windows 兼容补丁（**必须**，改完再 build）

上游代码只按 POSIX 假设写，在 Windows 上会让 profile 无法激活。共有 4 处代码改动（均在本机已落盘，重新 clone 后需重做）。

#### 3.1 新增平台相关的“完全限定路径”正则

新建/追加 `src/infra/paths.ts`：

```ts
/** Matches a fully qualified path on the host platform: POSIX (`/...`), Windows drive (`C:\...` / `C:/...`), or UNC (`\\...`). */
export const fullyQualifiedPath = process.platform === 'win32' ? /^([A-Za-z]:[\\/]|\\\\)/ : /^\//
```

#### 3.2 `src/deployment.ts`：`stateDir` 校验改用上面的正则

```ts
import { fullyQualifiedPath } from './infra/paths.ts'
// schema 里原本是 s.string().pattern(/^\//)
const absolute = (description: string) => s.string().pattern(fullyQualifiedPath).description(`${description} Absolute path.`)
// machineOf() 里加一条快速失败检查，报错信息更直观
if (!fullyQualifiedPath.test(stateDir)) throw new Error(`dsh-superagent stateDir must be a fully qualified path on ${process.platform}: ${stateDir}`)
```

#### 3.3 `src/policy.ts`：Execution 里的 Ticket 根目录 `directory` 同样放宽

```ts
import { fullyQualifiedPath } from './infra/paths.ts'
directory: z.string().trim().refine(path => path === '' || fullyQualifiedPath.test(path), 'A fully qualified absolute path, or empty for <stateDir>/work').default(''),
```

#### 3.4 `src/app/sessions.ts`：主 Session 的 shell 工具按平台选择

Windows 的全局工具只有 `pwsh`，没有 `bash`，硬编码 `bash` 会让 DSH 拒绝整个 restrict 调用。

```ts
/** The shell tool the profile registers on this platform; DSH rejects a restriction naming a tool it does not have. */
const SHELL_TOOL = process.platform === 'win32' ? 'pwsh' : 'bash'
// 使用处
binding.disposers.push(agent.ctx.tools.restrict({ allow: ['skill', SHELL_TOOL, 'read', 'read_image', 'job_output', 'job_list', 'job_kill'] }),
  agent.ctx.tools.guard(execution => noWait(execution, () => this.routed(agent))))
```

同时 `WORK_TOOLS` 里要同时保留 `bash` 与 `pwsh`（列表本身不改也能跑，因为 `workOnly` 只取当前 profile 拥有的工具）。

#### 3.5 `src/client/execution.tsx`：执行目录输入框的 HTML pattern 放宽

```tsx
<Input className="dt-mono" value={value.directory} placeholder={t('executionDirectoryEmpty')} spellCheck={false} pattern="(\/|[A-Za-z]:).*"
  onChange={event => edit({ directory: event.target.value })} />
```

> 建议把这些改动存成 `git format-patch` / diff 文件放在工作区，升级或重新 clone 后直接 `git apply`，比手改省事。

### 步骤 4：构建 bundle

```powershell
pnpm build
```

成功后会生成 `lib/index.js`、`lib/github-watch.js`、`lib/feishu-watch.js`、`lib/client.js`、`lib/*.d.ts`。**改完源码必须重新 build**，profile 加载的是 `lib/` 而不是 `src/`。

### 步骤 5：新建 `superagent` profile（从官方 web 模板复制）

```powershell
dsh superagent --from-default-profile web --dump-config
```

该命令会创建 `~/.dsh/profiles/superagent`，然后打印组合后的 profile 树并退出（exit 0）。

### 步骤 6：把 bundle 安装进 profile

```powershell
dsh plugin --profile superagent add "link:C:/Users/1/Documents/deepseek-harness/default-workspace/dsh-superagent"
```

成功后 `~/.dsh/profiles/superagent/package.json` 的 `dependencies` 与 `dsh.profile.bundles` 都会包含 `dsh-superagent`。

> pnpm 会提示 peerDependencies 不解析的告警（link 协议的正常现象），不影响运行。

### 步骤 7：写入机器配置（`stateDir` + 面板端口）

编辑 `C:\Users\1\.dsh\profiles\superagent\cordis.patch.yml`，**替换**为：

```yaml
- id: webserver
  config:
    host: 127.0.0.1
    port: 3082
- id: dsh-superagent
  config:
    stateDir: C:/Users/1/.dsh/state/superagent
```

> ⚠️ 打了 §3 的补丁后，`stateDir` 必须写成 **Windows 完全限定路径**（`C:/...`、`C:\...` 或 `\\...`）。
> 老的 `/Users/1/...` 写法现在会被拒绝，见 §4.7。
> 建议统一用正斜杠 `C:/...`，省得在 YAML 里纠结反斜杠转义。

### 步骤 8：准备启动器（解决 `workerProbe` 找不到 POSIX `env`）

插件的启动自检会执行 `env PATH=... <cli> ...`（`src/deployment.ts` 的 `workerProbe`），而 Windows 没有内置 `env.exe`。
建一个 `start-superagent.cmd`，把 Git for Windows 的 `usr\bin` 临时放到 PATH 最前面（不改机器 PATH）：

```cmd
@echo off
setlocal
set "PATH=C:\Program Files\Git\usr\bin;%PATH%"
"E:\Users\1\AppData\Local\Programs\DeepSeek Harness\resources\runtime\cli\bin\dsh.cmd" --profile superagent %*
```

### 步骤 9：启动

```powershell
& 'C:\Users\1\Documents\deepseek-harness\default-workspace\start-superagent.cmd' --no-open
```

看到 `dsh web: http://127.0.0.1:3082/?token=...` 即为成功；`C:\Users\1\.dsh\state\superagent\orchestrator.sqlite` 会被创建。
`--no-open` 只是不自动弹浏览器，可省略。

---

## 3. 验证

### 3.1 管理 API（需请求头）

面板根路径 `http://127.0.0.1:3082/` 直接访问会返回 **401**（需要 `token`），这是设计行为。

```powershell
$h = @{ 'x-orchestrator-request' = '1' }
Invoke-RestMethod -Uri 'http://127.0.0.1:3082/orchestrator/api/state' -Headers $h
Invoke-RestMethod -Uri 'http://127.0.0.1:3082/orchestrator/api/settings' -Headers $h
```

**已配置好并验证通过时的预期**（与本机实测一致）：

| 字段 | 预期值 |
| --- | --- |
| `setup.problem` | `null` |
| `setup.machine.stateDir` | `C:/Users/1/.dsh/state/superagent` |
| `setup.accounts.repository` | `hufeide/dsh_superagent_me` |
| `setup.accounts.agent` | `hufeide` |
| `setup.feishuProblem` | `null`（未启用飞书时） |
| `health.runtime.state` | `ready` / `Orchestrator is ready` |
| `health.github.state` | `ready` / `0 notifications; next poll ≥ 60s` |
| `health.relay / notice / launch / delivery / assessment / reply / evals / models` | `ready` |

**刚建好 profile、还没配 GitHub 时的预期**（初次安装的正常中间态）：`health.runtime` / `health.github` 为 `paused`，
`setup.problem` 为 `{place: github, code: repositoryUnset, detail: "The GitHub Source names no repository."}`。

> `/orchestrator/api/state` 返回 **404** 说明插件本体没激活（`dsh-superagent` 启动失败），去看启动日志的 `did not activate` 原因，不要去查面板/端口。

### 3.2 确认 bundle 已挂载

```powershell
dsh --profile superagent --dump-config
```

输出中应出现 `dsh-superagent`、`dsh-superagent-github`、`dsh-superagent-worker-preset`、`dsh-superagent-router-preset` 等条目。

### 3.3 面板

浏览器打开日志里打印的带 token 的 URL，在侧边栏选择 **Superagent**。

---

## 4. 踩过的坑（务必先看）

### 4.1 `app.asar\dsh\` 路径不存在
运行时上下文给出的 checkout 是 `...\resources\app.asar\dsh\`，但这是**打包在 asar 里的路径**，磁盘上并不存在。实际文件在 `resources\app.asar.unpacked\dsh\node_modules\...`。查插件源码/配置时要去 `app.asar.unpacked` 或直接看 GitHub 仓库。

### 4.2 `git clone` 报“错误”但实际成功
PowerShell 里 git 的进度输出走 **stderr**，被当成 `NativeCommandError` 抛出（exit code 1）。**判断标准是目录是否生成**，不是退出码。

### 4.3 `pnpm build` 失败：找不到 `ansis`
```
Error [ERR_MODULE_NOT_FOUND]: Cannot find package 'ansis' imported from ...\node_modules\tsdown\dist\...
```
原因：pnpm 隔离链接器把顶层 `node_modules/*` 建成 reparse point（symlink/junction），而 Node 在当前环境下**无法沿这些链接向上解析传递依赖**（`node_modules/tsdown` 里只有 `.bin`，没有 `ansis`）。
**解法：`pnpm install --node-linker=hoisted`**（扁平布局，Node 直接向上找到依赖）。
> 排查命令：`node -e "console.log(require.resolve('ansis/package.json'))"`，或检查 `node_modules/tsdown/node_modules` 内容。

### 4.4 `~/.dsh` 不在工作区沙箱内（EPERM）
`dsh superagent --from-default-profile web` 报：
```
EPERM mkdtemp 'C:\\Users\\1\\.dsh\\profiles\\.superagent.staging-XXXXXX'
```
因为 `C:\Users\1\.dsh` 在 workspace 之外，默认 `workspace-write` 策略写不了。**需要 `danger-full-access`**（本会话已批准）。
> 验证：在 `~/.dsh/profiles` 下 `New-Item` 目录，被拒即属此情况。

### 4.5 profile 创建命令要带 `--dump-config`
`dsh superagent --from-default-profile web --dump-config` —— 不带 `--dump-config` 会直接 boot；带它才会“创建后打印并退出”。

### 4.6 `dsh --profile superagent web` 报 “too many arguments”
```
error: too many arguments. Expected 0 arguments but got 1: web.
```
`superagent` profile 本身已经内嵌 web app，**不要**再传 `web`。正确命令就是：
```powershell
dsh --profile superagent
```

### 4.7 `stateDir` 是 POSIX 与 Win32 双重坑（原“必须写 `/Users/...`”的结论已作废）

**症状（原始报错，插件根本没激活）**：
```
dsh: warning: 2 entries did not activate
dsh-superagent (dsh-superagent): TypeError: Workspace path is not fully qualified: /Users/1/.dsh/state/superagent
dsh-superagent-github (dsh-superagent/github-watch): pending (waiting for service: orchestrator)
```

**原因**：两套校验互相矛盾。
- 上游插件 schema 用 `s.string().pattern(/^\//)`，只允许 POSIX 路径 → 填 `C:\Users\...` 会报
  `ValidationError: invalid config: $.stateDir expect string to match regexp /^\//`。
- 但 `stateDir` 随后会被传给 DSH 的 `workspaceRegistry.create(cwd)`，其 `realpathNormalize()` 在 Windows 下要求
  `win32.isAbsolute(path)` 且 `win32.parse(path).root !== '/'`。`/Users/...` 的 win32 root 恰好是 `/`，因此被判「不是完全限定路径」。

也就是说：填 POSIX 被 DSH 拒，填 `C:\` 被插件拒 —— 用配置文件绕不过去，**只能改代码**（§3.1–3.3）。

各写法实测结果：

| 填入值 | 结果 |
| --- | --- |
| `/Users/1/.dsh/state/superagent` | 旧 schema 通过，但 DSH `workspaceRegistry.create` 拒绝 → `Workspace path is not fully qualified` |
| `C:\Users\1\.dsh\state\superagent` | 旧 schema 拒绝 → `expect string to match regexp /^\//` |
| `C:/Users/1/.dsh/state/superagent` | ✅ 打补丁后通过（推荐写法） |

执行设置里的 `directory`（Ticket 工作目录）与 `stateDir` 同源，也必须写成 `C:/...`（§3.3）。

### 4.8 面板根路径 401、API 需要请求头
- 直接 `GET http://127.0.0.1:3082/` → **401**（需要 token），属正常。
- 管理 API 必须带请求头 `x-orchestrator-request: 1`，否则 403。

### 4.9 `scripts/dsh-superagent` 在 Windows 不可用
仓库里的 `scripts/dsh-superagent`（start/status/restart）import `fcntl` 并依赖 `tmux`，是 **Unix 专用**。Windows 下请用 §2 步骤 8 的启动器或 `dsh --profile superagent` 启停，或用 `Stop-Process` 结束进程。

### 4.10 PowerShell 里 `node -e` 的引号陷阱
在 PowerShell 里用 here-string 传 `node -e` 容易把 JS 里的 `/.../` 或引号解析坏（报 `SyntaxError: Invalid regular expression flags`）。**解法：把脚本写成 `.mjs` 文件再 `node xxx.mjs`。**

### 4.11 编辑中的文件被运行中的 profile 改写
`cordis.patch.yml` 在 profile 运行/保存时会被自动追加条目（例如 `ui-settings-general`、`agent-preset-registry`、`llm-pi-ai`）。编辑前要**重新读取**，否则会 `file changed since it was read`。

### 4.12 补完路径坑之后的第二个拦路虎：`tools.restrict()` 不认 `bash`

修好 §4.7 后启动，主 Session 恢复失败：
```
RemoteError: resume failed for session "orchestrator-...":
Error: tools.restrict() names unknown global tool "bash";
known global tools: job_kill, job_list, job_output, pwsh, read, read_image, skill, working_directory
```
原因：`src/app/sessions.ts` 把 `bash` 硬编码进主 Session 的 `tools.restrict({ allow })`，而 Windows 下全局工具只有 `pwsh`。
DSH 会**整体拒绝**这次 restrict，于是 Session 起不来、插件停在 half-ready。
**解法：**`const SHELL_TOOL = process.platform === 'win32' ? 'pwsh' : 'bash'`（§3.4），改完重新 `pnpm build` 并重启。

### 4.13 `Lock file is already being held`（重启时的 stale 锁）

```
Error: Lock file is already being held
```
插件用 `proper-lockfile` 对 `stateDir` 加锁（stale 判定 **30 秒**）。上一次实例被强制结束（`Stop-Process` / 关控制台）时锁目录不会立刻释放，
紧接着启动的新实例就会在 30 秒窗口内判定锁“仍然有效”，于是 `dsh-superagent` 不激活，
`/orchestrator/api/state` 返回 **404**（面板仍能开，容易误判成“插件坏了”）。

处理顺序：
1. 确认没有残留进程、端口没在监听：
   ```powershell
   Get-Process | Where-Object { $_.ProcessName -like '*DeepSeek*' } | Select-Object Id, StartTime
   Get-NetTCPConnection -LocalPort 3082 -ErrorAction SilentlyContinue | Select-Object State, OwningProcess
   ```
   只有 `TimeWait`、没有 `Listen` 才算干净。
2. 等 30 秒以上让 stale 判定过期（或手工删掉 `stateDir` 下的锁目录），再启动。
3. 启动后必须用 §3.1 的 API 复核，**不要只看面板能否打开**。

### 4.14 用 `Start-Process -WindowStyle Hidden` 启动会“启动即退出”

表现：日志里只有一行 `dsh web: ...`，随后进程消失、端口无监听；用 Shell 后台方式启动却能常驻。
另外如果直接用 `dsh.cmd --profile superagent` 而不经过启动器，还会因为 PATH 里没有 POSIX `env.exe` 而让 `workerProbe` 失败（§2 步骤 8）。
**解法：统一用 `start-superagent.cmd`，并把输出重定向到日志文件**，以日志里打印的 token URL 为准。

### 4.15 已知遗留（不影响运行）

`noWait()` 守卫里仍只判断 `name === 'bash'`，Windows 下主 Session 用的是 `pwsh`，因此这条“不要等待、直接结束回合”的提示在 Windows 上不会触发。
只影响主 Session 的交互风格，不影响 Ticket 生成与执行。若要彻底对齐，可在该处同样用 `SHELL_TOOL` 判断。

---

## 5. Windows 特定注意事项

1. **路径用 Windows 完全限定形式**（§4.7）：`C:/Users/...` 或 `C:\Users\...` 或 `\\...`；旧的 `/Users/...` 写法在补丁后会被拒绝。
2. **不要用 `scripts/dsh-superagent`**（§4.9），用 `start-superagent.cmd` 或 `dsh --profile superagent` 启停。
3. **面板 token 每次重启都会变化**，以日志里打印的 URL 为准。
4. 执行设置里的 `prepare` 命令若是 POSIX shell 脚本，需改成 PowerShell 语法或调用 `pwsh -Command`；dsh-superagent 的 worker 默认用 `pwsh`（win32 下自动禁用 bash 工具）。
5. `dsh plugin add "link:..."` 用正斜杠或反斜杠均可，但建议正斜杠 + 绝对路径。
6. **改了 `src/` 一定要 `pnpm build` 再重启**，profile 加载的是 `lib/`。
7. 启动器依赖 Git for Windows 的 `C:\Program Files\Git\usr\bin\env.exe`；换机器时确认该路径存在。

---

## 6. 后续配置（把插件真正跑起来）

插件本体装好后，在面板（或管理 API）依次保存，本机已完成的配置如下：

| 项 | 本机值 |
| --- | --- |
| GitHub Source | `repository: hufeide/dsh_superagent_me`，`agent: hufeide`，`cli: C:\Program Files\GitHub CLI\gh.exe` |
| Policy | 允许发起工作的 GitHub 账号列表（至少一个，否则不会生成 Ticket） |
| Execution | Ticket 目录（`C:/...` 形式，留空则用 `<stateDir>/work`）+ `prepare` 命令（克隆仓库、建 worktree，PowerShell 语法） |
| Prompts | 团队提示词（披露行、评审机器人、提交作者、自动合并条件等） |
| Feishu | 未启用时 `setup.feishuProblem` 应为 `null` |

保存会触发 setup 检查，返回 `restarting: true` 时等重启完成（注意 §4.13 的锁窗口）后再操作。

验证方式：从允许列表里的账号在 Issue 评论 `@<agent login> <request>`，约一分钟后面板 Overview 应出现 Ticket。

---

## 7. 常用命令速查

```powershell
# 启动（后台常驻，日志落盘）
& 'C:\Users\1\Documents\deepseek-harness\default-workspace\start-superagent.cmd' --no-open *> "$env:TEMP\superagent-boot.log"
Get-Content "$env:TEMP\superagent-boot.log" -Tail 20        # 看 token URL

# 停止
Stop-Process -Id (Get-NetTCPConnection -LocalPort 3082).OwningProcess
Get-NetTCPConnection -LocalPort 3082 -ErrorAction SilentlyContinue   # 确认只剩 TimeWait

# 重启（停后至少等 30s 让 stale 锁过期，见 §4.13）
& 'C:\Users\1\Documents\deepseek-harness\default-workspace\start-superagent.cmd' --no-open

# 校验配置组合
dsh --profile superagent --dump-config

# 管理 API
$h = @{ 'x-orchestrator-request' = '1' }
Invoke-RestMethod -Uri 'http://127.0.0.1:3082/orchestrator/api/state' -Headers $h

# 重新构建 bundle（改过 src/ 之后）
cd C:\Users\1\Documents\deepseek-harness\default-workspace\dsh-superagent
pnpm install --node-linker=hoisted ; pnpm build
```

---

## 8. 关键文件清单

| 文件 | 作用 |
| --- | --- |
| `...\default-workspace\dsh-superagent\package.json` | bundle 清单（`dsh.bundle.patch`、`dsh.client`、`engines`） |
| `...\dsh-superagent\cordis.patch.yml` | bundle 的 patch 层：插入插件与两个 agent preset；win32 下禁用 bash 工具、启用 pwsh |
| `...\dsh-superagent\src\infra\paths.ts` | **补丁**：`fullyQualifiedPath` 平台正则（§3.1） |
| `...\dsh-superagent\src\deployment.ts` | **补丁**：`stateDir` schema + 启动自检（§3.2）；`workerProbe` 依赖 POSIX `env` |
| `...\dsh-superagent\src\policy.ts` | **补丁**：Execution `directory` 校验（§3.3） |
| `...\dsh-superagent\src\app\sessions.ts` | **补丁**：主 Session `SHELL_TOOL`（§3.4）；`workspaceRegistry.create(cwd)` 调用点 |
| `...\dsh-superagent\src\client\execution.tsx` | **补丁**：执行目录输入框 pattern（§3.5） |
| `...\dsh-superagent\lib\*.js` | 构建产物，插件实际加载的代码（`pnpm build` 生成） |
| `...\default-workspace\start-superagent.cmd` | Windows 启动器（PATH 注入 Git `usr\bin`，提供 POSIX `env`） |
| `C:\Users\1\.dsh\profiles\superagent\cordis.patch.yml` | 机器配置（`stateDir`、面板端口、模型 provider） |
| `C:\Users\1\.dsh\state\superagent\orchestrator.sqlite` | 插件状态库（setup/settings/会话元数据） |
