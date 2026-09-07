# PRDashboard 本地 Socket API

PRDashboard 在运行期间会监听一个 Unix Domain Socket，外部进程可以通过它查询应用当前状态、PR 列表以及单个 PR 的详细信息。本文档面向需要直接访问该接口、不依赖随附 `ghpr` CLI 的调用方。

实现位置：`PRDashboard/LocalAPI/`（`LocalSocketServer.swift`、`LocalSocketClient.swift`、`LocalAPIModels.swift`）。

---

## 1. 连接方式

### Socket 路径

| 来源 | 取值 |
|------|------|
| 默认路径 | `/tmp/com.xiaocang.PRDashboard.<uid>.sock`，其中 `<uid>` 为运行 PRDashboard 用户的 `getuid()` |
| 环境变量覆盖 | `GHPR_SOCKET_PATH`（client 端读取；server 端在启动时使用默认路径，不读取该变量） |

> server 当前不读取 `GHPR_SOCKET_PATH`，始终监听默认路径。该环境变量仅供 client/CLI 指定要连接到的 socket。

socket 文件权限为 `0600`（仅当前用户可读写）。

### 协议

- 传输：`AF_UNIX`、`SOCK_STREAM`
- 帧格式：**单帧 newline-delimited JSON**
  - client → server：写入一条 JSON 后追加 `\n`，然后 `shutdown(SHUT_WR)` 表示请求结束
  - server → client：写入一条 JSON 后追加 `\n`，然后关闭连接
- 一次连接 = 一次请求 + 一次响应，不复用连接
- 编码：UTF-8

### 大小限制

| 方向 | 上限 |
|------|------|
| 请求 | 1 MiB（超过即报 `invalid_request`） |
| 响应 | 4 MiB（client 端读取超出会报错） |

### 同源校验

server 通过 `getpeereid()` 校验对端 UID 必须等于当前进程 UID，否则返回 `unauthorized_peer` 错误。换言之：仅同一用户的进程可以访问。

---

## 2. 协议版本

```
schemaVersion = 2
```

每个响应都会带 `schemaVersion` 字段。client 应当校验它等于自己支持的版本，不一致时按协议错误处理。`schemaVersion` 从 1 升级到 2 是可加字段的兼容变更：新增了 `import_review` 命令、请求体的 `review` 字段、响应体的 `reviewImport` 字段，以及 `summary.directMentions` / `pullRequests.directMentions`；旧客户端忽略未知字段仍可继续工作。

---

## 3. 请求结构

```json
{
  "command": "ping" | "snapshot" | "pr" | "import_review",
  "repository": "owner/name",   // 仅 pr / import_review 命令必填
  "number": 123,                // 仅 pr / import_review 命令必填
  "review": { ... }             // 仅 import_review 命令必填，结构见 5.4
}
```

字段说明：

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `command` | string | 是 | 命令名，见下文 |
| `repository` | string | `pr` / `import_review` | `owner/name` 形式；大小写不敏感匹配 |
| `number` | int | `pr` / `import_review` | PR 号 |
| `review` | object | 仅 `import_review` | 见 5.4 `LocalReviewImportPayload` |

未识别的 `command` 会返回 `unsupported_command` 错误。

---

## 4. 响应结构

```json
{
  "schemaVersion": 2,
  "ok": true,
  "snapshot": { ... } | null,
  "pullRequest": { ... } | null,
  "reviewImport": { ... } | null,
  "error": null | { "code": "...", "message": "..." }
}
```

约定：

- `ok = true` 时 `error = null`，且至少有一个数据字段（`snapshot` / `pullRequest` / `reviewImport`）非空，由命令决定哪个字段被填充。
- `ok = false` 时数据字段均为 `null`，`error` 必填。

### 错误码

| `error.code` | 含义 |
|--------------|------|
| `invalid_request` | JSON 不合法、缺少必填字段、请求超出长度限制、或 `import_review` 校验失败 |
| `unsupported_command` | `command` 不在已知集合中 |
| `unauthorized_peer` | 对端 UID 不匹配（同源校验失败） |
| `not_found` | `pr` 命令找不到对应的 PR |
| `internal_error` | server 内部错误（如生成 snapshot 超时，或 `import_review` 时扩展平台控制器不可用） |

---

## 5. 命令

### 5.1 `ping`

健康检查。

请求：

```json
{ "command": "ping" }
```

响应：

```json
{ "schemaVersion": 2, "ok": true, "snapshot": null, "pullRequest": null, "reviewImport": null, "error": null }
```

### 5.2 `snapshot`

返回应用当前完整快照，包含版本、登录状态、刷新状态、限流信息、聚合统计以及五个分组下的所有 PR。

请求：

```json
{ "command": "snapshot" }
```

成功响应：

```json
{
  "schemaVersion": 2,
  "ok": true,
  "snapshot": { /* LocalSnapshot，结构见第 6 节 */ },
  "pullRequest": null,
  "reviewImport": null,
  "error": null
}
```

> server 在主线程构建 snapshot，超时 5 秒会返回 `internal_error`。

### 5.3 `pr`

按 `owner/name` + PR 号查询单个 PR。匹配范围限定为 snapshot 中已加载的五个分组（`authored` / `reviewRequests` / `mentioned` / `directMentions` / `mergedLast24h`），未加载的 PR 不会去 GitHub 重查。

请求：

```json
{ "command": "pr", "repository": "example-org/example-repo", "number": 1234 }
```

成功响应：

```json
{
  "schemaVersion": 2,
  "ok": true,
  "snapshot": null,
  "pullRequest": { /* LocalPRSnapshot，结构见第 6 节 */ },
  "reviewImport": null,
  "error": null
}
```

未找到时：

```json
{
  "schemaVersion": 2,
  "ok": false,
  "snapshot": null,
  "pullRequest": null,
  "reviewImport": null,
  "error": { "code": "not_found", "message": "No PR found for example-org/example-repo#1234." }
}
```

### 5.4 `import_review`

将一份已经完成的 code review 以 `pr.review` Skill run 的形式落盘到 PRDashboard 本地存储（`extension-platform.json`），供 UI 和其它读命令展示。**该命令绝不会向 GitHub 提交 review 或评论**，纯本地写入。

请求 `review` 字段结构（`LocalReviewImportPayload`）：

| 字段 | 类型 | 说明 |
|------|------|------|
| `baseSHA` | string | 40 位十六进制 base commit SHA |
| `headSHA` | string | 40 位十六进制 head commit SHA |
| `engine` | string | 1-200 字符，任意 provenance 标签（如 `claude-code`） |
| `overviewMarkdown` | string | 1-100000 字符，review 总览 Markdown |
| `findings` | `LocalReviewImportFinding[]` | 1-50 条，每条一个 line-anchored finding |

`LocalReviewImportFinding` 字段：

| 字段 | 类型 | 说明 |
|------|------|------|
| `file` | string | 仓库相对路径，1-1024 字符，不含 `..` 或前导 `/` |
| `startLine` / `endLine` | int | `startLine > 0` 且 `endLine >= startLine` |
| `side` | `"left"` \| `"right"` | diff 侧 |
| `title` | string | 1-200 字符 |
| `summary` | string | 1-2000 字符 |
| `why` / `suggestedFix` / `background` / `quotedCode` | string? | 各自最多 20000 字符 |
| `severity` | `"error"` \| `"warning"` \| `"info"` | |
| `confidence` | number | `0...1` |
| `category` | string | 1-200 字符 |

请求：

```json
{
  "command": "import_review",
  "repository": "example-org/example-repo",
  "number": 1234,
  "review": {
    "baseSHA": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "headSHA": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "engine": "claude-code",
    "overviewMarkdown": "## Summary\nLooks good overall, one correctness issue.",
    "findings": [
      {
        "file": "src/worker.ts",
        "startLine": 18,
        "endLine": 18,
        "side": "right",
        "title": "Lost update",
        "summary": "The write drops concurrent changes.",
        "severity": "error",
        "confidence": 0.95,
        "category": "concurrency"
      }
    ]
  }
}
```

成功响应（`reviewImport` 为 `LocalReviewImportResult`）：

```json
{
  "schemaVersion": 2,
  "ok": true,
  "snapshot": null,
  "pullRequest": null,
  "reviewImport": {
    "runID": "run_mcp_1a2b3c4d5e6f7a8b9c0d1e2f",
    "repository": "example-org/example-repo",
    "number": 1234,
    "headSHA": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "findingCount": 1,
    "importedAt": "2026-01-01T00:00:00Z",
    "alreadyImported": false
  },
  "error": null
}
```

**幂等**：使用完全相同的 `(repository, number, review)` 再次调用会返回相同的 `runID`，`alreadyImported: true`，不会产生新的 run、不会触碰 store revision。

校验失败（例如 SHA 不是 40 位十六进制、`endLine < startLine`、字段超长、findings 超过 50 条）会在写入任何数据前返回 `invalid_request`，不会产生部分写入。扩展平台控制器不可用时返回 `internal_error`。

---

## 6. 数据模型

所有 `Date` 字段均为 ISO 8601 字符串（UTC，例如 `2026-04-28T10:23:45Z`）。

### 6.1 `LocalSnapshot`

| 字段 | 类型 | 说明 |
|------|------|------|
| `schemaVersion` | int | 与顶层 `schemaVersion` 一致 |
| `generatedAt` | Date | 该 snapshot 生成时间 |
| `app` | `LocalAppSnapshot` | 应用元信息 |
| `auth` | `LocalAuthSnapshot` | 登录状态 |
| `refresh` | `LocalRefreshSnapshot` | 上次刷新状态 |
| `rateLimit` | `LocalRateLimitSnapshot` | GitHub API 限流 |
| `summary` | `LocalSummarySnapshot` | 聚合计数 |
| `pullRequests` | `LocalPRSectionsSnapshot` | 五个分组的 PR 列表 |

### 6.2 `LocalAppSnapshot`

| 字段 | 类型 |
|------|------|
| `version` | string |
| `build` | string |
| `bundleIdentifier` | string |

### 6.3 `LocalAuthSnapshot`

| 字段 | 类型 | 说明 |
|------|------|------|
| `isAuthenticated` | bool | 是否已登录 |
| `username` | string? | 登录用户名 |
| `method` | string? | 认证方式（如 `oauth`、`pat`） |

### 6.4 `LocalRefreshSnapshot`

| 字段 | 类型 | 说明 |
|------|------|------|
| `status` | string | 当前刷新状态文案 |
| `isLoading` | bool | 是否正在加载 |
| `lastUpdated` | Date | 上次刷新完成时间 |
| `error` | string? | 上次刷新错误描述 |

### 6.5 `LocalRateLimitSnapshot`

| 字段 | 类型 | 说明 |
|------|------|------|
| `limit` | int | 限流上限 |
| `remaining` | int | 剩余配额 |
| `resetAt` | Date | 重置时间 |
| `isLow` | bool | 是否进入低水位 |

### 6.6 `LocalSummarySnapshot`

| 字段 | 类型 | 说明 |
|------|------|------|
| `authored` | int | 我创建的 PR 数 |
| `reviewRequests` | int | 待我 review 的 PR 数 |
| `mentioned` | int | @我 的 PR 数 |
| `directMentions` | int | 评论中直接 @我 的 PR 数 |
| `mergedLast24h` | int | 24 小时内已合并 |
| `totalUnresolved` | int | 全部 PR 的未解决评论数总和 |
| `authoredUnresolved` | int | 我创建的 PR 中未解决评论数总和 |
| `readyToMerge` | int | 可合并 PR 数 |
| `changesRequested` | int | 被 request changes 的 PR 数 |
| `ciFailing` | int | CI 失败 PR 数 |
| `ciRunning` | int | CI 运行中 PR 数 |
| `waitingForMyReview` | int | 等我 review 的 PR 数 |

### 6.7 `LocalPRSectionsSnapshot`

| 字段 | 类型 |
|------|------|
| `authored` | `LocalPRSnapshot[]` |
| `reviewRequests` | `LocalPRSnapshot[]` |
| `mentioned` | `LocalPRSnapshot[]` |
| `directMentions` | `LocalPRSnapshot[]` |
| `mergedLast24h` | `LocalPRSnapshot[]` |

### 6.8 `LocalPRSnapshot`

| 字段 | 类型 | 说明 |
|------|------|------|
| `id` | int | 应用内部 PR ID |
| `section` | enum: `authored` / `review` / `mentioned` / `directMentions` / `merged` | 该 PR 所属分组（注意是单数 `review` / `merged`，与 `LocalPRSectionsSnapshot` 字段名不同） |
| `repository` | string | `owner/name` |
| `number` | int | PR 号 |
| `title` | string | 标题 |
| `author` | string | 作者登录名 |
| `url` | string | PR HTML URL |
| `state` | string | `OPEN` / `CLOSED` / `MERGED` 等 |
| `isDraft` | bool | 是否 draft |
| `isPinned` | bool | 用户是否在应用中 pin 了该 PR |
| `hasBaseConflicts` | bool | 是否与 base 分支冲突 |
| `unresolvedCount` | int | 未解决 review thread 数 |
| `ciStatus` | string? | 例如 `SUCCESS` / `FAILURE` / `PENDING`；可能为空 |
| `checkSuccessCount` | int | 成功的 check 数 |
| `checkFailureCount` | int | 失败的 check 数 |
| `checkPendingCount` | int | 进行中的 check 数 |
| `ciIsRunning` | bool | 是否仍在跑 |
| `approvalCount` | int | approval 数 |
| `changesRequestedCount` | int? | request changes 数 |
| `myReviewStatus` | string? | 当前用户的 review 状态 |
| `jiraTicket` | string? | 解析到的 Jira ticket |
| `updatedAt` | Date | PR 更新时间 |
| `mergedAt` | Date? | 合并时间，未合并为 null |

### 6.9 `LocalReviewImportResult`

`import_review` 成功时填充在响应的 `reviewImport` 字段。

| 字段 | 类型 | 说明 |
|------|------|------|
| `runID` | string | 生成的 `pr.review` run ID，形如 `run_mcp_<24 位十六进制>` |
| `repository` | string | 归一化（小写）后的 `owner/name` |
| `number` | int | PR 号 |
| `headSHA` | string | 归一化（小写）后的 head SHA |
| `findingCount` | int | 落盘的 finding 数 |
| `importedAt` | Date | 首次导入完成时间；重复导入时为原始导入时间 |
| `alreadyImported` | bool | 是否命中了已存在的相同 review（幂等） |

---

## 7. 调用示例

### 7.1 shell（`socat` 或 `nc`）

```bash
# 路径基于 uid，按需替换
SOCKET="/tmp/com.xiaocang.PRDashboard.$(id -u).sock"

printf '{"command":"ping"}\n' | socat - UNIX-CONNECT:$SOCKET
printf '{"command":"snapshot"}\n' | socat - UNIX-CONNECT:$SOCKET | jq .
printf '{"command":"pr","repository":"example-org/example-repo","number":1234}\n' \
  | socat - UNIX-CONNECT:$SOCKET | jq .
```

注意：BSD `nc` 在写完后不会主动 half-close，可能导致 server 收不到结束标志而永远等下去。优先用 `socat`，或显式让 client 写完 `\n` 后调用 `shutdown(SHUT_WR)`。

### 7.2 Python

```python
import json, os, socket

def call(req):
    sock_path = os.environ.get(
        "GHPR_SOCKET_PATH",
        f"/tmp/com.xiaocang.PRDashboard.{os.getuid()}.sock",
    )
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.connect(sock_path)
        s.sendall((json.dumps(req) + "\n").encode("utf-8"))
        s.shutdown(socket.SHUT_WR)
        chunks = []
        while True:
            buf = s.recv(65536)
            if not buf:
                break
            chunks.append(buf)
        return json.loads(b"".join(chunks).decode("utf-8"))

print(call({"command": "ping"}))
print(call({"command": "snapshot"})["snapshot"]["summary"])
print(call({"command": "pr", "repository": "example-org/example-repo", "number": 1234}))
```

### 7.3 Node.js

```js
const net = require("net");

function call(req) {
  const path = process.env.GHPR_SOCKET_PATH
    || `/tmp/com.xiaocang.PRDashboard.${process.getuid()}.sock`;
  return new Promise((resolve, reject) => {
    const sock = net.createConnection(path);
    const buffers = [];
    sock.on("data", (b) => buffers.push(b));
    sock.on("end", () => {
      try { resolve(JSON.parse(Buffer.concat(buffers).toString("utf8"))); }
      catch (e) { reject(e); }
    });
    sock.on("error", reject);
    sock.write(JSON.stringify(req) + "\n", () => sock.end());
  });
}

call({ command: "ping" }).then(console.log);
```

---

## 8. 调用方注意事项

1. **应用必须在前台运行**：socket 仅在 PRDashboard 进程存活期间存在。连不上时按"未运行"处理。
2. **快照来自当前内存状态**：调用 `snapshot` / `pr` 时不会触发 GitHub 请求；如果应用还在加载，可能拿到上一次的结果或空列表。`refresh.isLoading` 与 `refresh.lastUpdated` 可用于判定。
3. **schemaVersion 兼容**：未来若有破坏性变更会递增 `schemaVersion`，请显式校验，不要忽略字段差异。
4. **同源限制**：跨用户访问会被拒绝。如需跨用户共享，需要自行在拥有方进程内做转发。
5. **不要长连接**：每次请求都建立新连接。server 一收到 EOF（`SHUT_WR`）才开始处理。
6. **错误处理建议**：
   - 连不上 socket → 应用未运行
   - 收到 `unauthorized_peer` → 检查运行身份
   - 收到 `not_found` → PR 未在已加载分组中，应用未必能"按需"拉取
   - 收到 `internal_error` → 通常是 5 秒内未拿到 snapshot，可重试

---

## 9. 已知限制

- 仅支持 macOS（应用本身为 macOS menu bar app）。
- 不提供推送 / 流式接口，需要轮询 `snapshot` 才能拿到最新值。
- `pr` 命令只能查询已加载的 PR；不在五个分组里的 PR 不会被命中。
- `import_review` 是当前唯一的写命令：其余命令（`ping` / `snapshot` / `pr`）仍然只读；`import_review` 只写本地存储，绝不触达 GitHub。
