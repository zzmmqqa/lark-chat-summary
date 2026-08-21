---
name: lark-chat-summary
description: |-
  总结飞书（Lark）群聊或话题（thread）在指定时间段内的讨论：自动拉取主线消息 + 话题内回复 + 媒体附件链接（图片/视频/文件），
  生成结构化总结报告（话题主题 / 关键观点 / 决策结论 / 行动项）。默认时间窗口最近 1 月。

  触发词（群级）：「总结当前群消息」「总结群消息」「群消息总结」「群讨论总结」「飞书群总结」
  「整理一下群里的讨论」「summarize chat」「summarize lark chat」「lark summary」「chat summary」

  触发词（话题级 / thread）：「总结当前话题」「总结话题」「话题消息总结」「话题总结」
  「总结这个 thread」「thread 总结」「summarize thread」「summarize topic」「thread summary」
---

# lark-chat-summary

总结飞书群聊讨论。流程：**定位群 → 解析时间窗口 → 拉取主线消息 → 展开 thread → 收集媒体链接 → 生成报告**。

## 0. MCP 工具加载

使用 Codex 中已配置的 `lark-mcp`。本 skill 不负责登录、签发或刷新令牌，也不得读取、输出或写入任何应用凭据；认证由 MCP 启动配置负责。

仅使用当前会话中 `lark-mcp` 暴露的只读能力：

- `im.v1.chat.list`：定位群聊
- `im.v1.message.list`：读取群聊或话题消息
- `im.v1.chatMembers.get`：读取群成员，用于解析发送人
- `im.v1.chatMembers.isInChat`：检查机器人是否在群内

实际工具标识以 Codex 当前会话暴露的名称为准，不在 skill 中硬编码宿主生成的 MCP 工具前缀。禁止调用发送、回复、置顶、删除消息、修改群成员或其他写操作。

## 1. 输入模式判定（chat vs thread）

按触发词区分**容器类型**，决定走 chat 全量流程还是 thread 单串流程：

| 用户表达 | 模式 | container_id_type | container_id 来源 |
|---------|------|-------------------|------------------|
| 「群消息总结」「总结群」「summarize chat」 | **chat 模式** | `chat` | `oc_xxx` |
| 「话题总结」「总结当前话题」「话题消息总结」「thread 总结」「summarize thread/topic」 | **thread 模式** | `thread` | `omt_xxx` 或 thread_id |
| 既给群又指明话题 | thread 模式 + 用群名定位上下文 | `thread` | thread_id |

> ⚠️ **thread 模式核心约束（必须严格遵守）**：
> - **只拉 thread 内所有消息 + 该 thread 的入口（root）消息**，**不**扫描所在群的其他主线消息
> - 入口消息通常是 `im.v1.message.list(container_id_type=thread, …)` 返回的**第一条**（`message_id == root_id` 的那条）；如果首页第一条不是入口，单独再用入口的 `message_id` 反查
> - 时间窗口默认仍是 30 天，但 thread API **不支持** `start_time/end_time`，需全量拉再客户端按 `create_time` 过滤（thread 体量通常 ≤ 几百条，全量无压力）
> - **不要**因为想"看上下文"就再去拉群主线——违反"只看当前话题"的意图
> - 反查入口失败（API 报错 / 入口已撤回）时：仍按已拉到的话题内消息生成报告，在「概览」标注「入口消息缺失」

## 2. 容器定位

### 2.1 chat 模式（chat_id）

| 用户输入 | 行为 |
|---------|------|
| 直接给 `oc_xxx` chat_id | 用之 |
| 给群名 / 「XX 群」 | `im.v1.chat.list(sort=ByActiveTimeDesc, page_size=50)` 按 name 模糊匹配，>1 命中时列出候选并让用户选择 |
| 只说「当前群」「这个群」/ 不给任何线索 | `im.v1.chat.list(sort=ByActiveTimeDesc, page_size=20)` 列出最近活跃前 5 个并让用户选择 |

⚠️ Codex 看不到「用户当前所在群」，**必须**由用户指定或选择，不能凭空编造 chat_id。

### 2.2 thread 模式（thread_id）

| 用户输入 | 行为 |
|---------|------|
| 直接给 thread_id（`omt_xxx` 或 thread 链接 `?thread_id=xxx`） | 用之 |
| 给消息链接 / message_id | 用 `im.v1.message.list(container_id_type=chat, …)` 反查 `thread_id`；**找不到 thread_id 时停止并提示用户改用群级总结**，不要自动降级（违反「只看话题」意图） |
| 只说「当前话题 / 这个话题」/ 无线索 | 先按 chat 模式让用户选群，再列该群最近时间窗内 thread_id Top 5（按消息数排序）并让用户选择；**仅用群定位 thread**，选定后不再读群其他消息 |

⚠️ Codex 同样看不到「用户当前所在 thread」，必须由用户指定或选择。
⚠️ 选定 thread_id 之后，**只**调 `im.v1.message.list(container_id_type=thread, container_id=<thread_id>)`，不再触碰群主线。

## 2. 时间窗口

| 用户表达 | 起止（北京时区） |
|---------|----------------|
| 「最近 1 月」/ 未指定 | `now - 30 day` → `now` |
| 「最近 1 周 / N 天 / N 月」| 按表达换算 |
| 「2026-05-01 到 2026-05-10」| 按字面 |
| 「今天 / 昨天 / 本周 / 上周」| 按当地日历换算 |

将起止时间按 `Asia/Shanghai` 解释并转换为 Unix 秒级时间戳；`im.v1.message.list` 的查询参数使用秒，不是毫秒。不要依赖特定操作系统的日期命令。

## 3. 拉取流程

参考 [`references/message-fetch.md`](references/message-fetch.md)。

### 3.1 chat 模式拉取

1. **主线**：`im.v1.message.list(container_id_type=chat, container_id=<chat_id>, start_time, end_time, sort_type=ByCreateTimeAsc, page_size=50)`，循环 `page_token` 翻页直到 `has_more=false`。
2. **话题展开**：主线每条消息检查 `thread_id`（非空且非自身根）→ 去重收集 → 对每个 thread_id 单独调 `im.v1.message.list(container_id_type=thread, container_id=<thread_id>, page_size=50)`（thread 容器**不支持** start_time/end_time，全量拉再客户端按时间过滤）。
3. **媒体链接**：消息 `msg_type` 为 `image / file / media / audio / sticker` 时，从 `body.content`（JSON 字符串）解析出 `image_key` / `file_key`，构造下载提示（不下载，仅在报告中列链接 / 占位 + key，方便用户在飞书内打开）。`post` 富文本里嵌入的图片/链接也一并提取。
4. **发送人**：消息 `sender.id` 是 `open_id`。已知 chat_id 时，用 `im.v1.chatMembers.get` 获取群成员并建立 `open_id -> name` 映射；无法解析时保留脱敏后的发送人 ID，不请求额外通讯录权限。

### 3.2 thread 模式拉取（只看话题内 + 入口）

1. **只调一个 API**：`im.v1.message.list(container_id_type=thread, container_id=<thread_id>, sort_type=ByCreateTimeAsc, page_size=50)`，翻页拉完整个话题。
2. **入口消息识别**：返回列表中 `message_id == root_id` 的那条即入口；通常是第一条。如果首页第一条不是入口（极少发生），单独保留 `root_id` 待后续标记。
3. **客户端时间过滤**：按 `create_time` 落在用户指定的 `[start_time, end_time]`；**入口消息无论是否在时间窗内都保留**（用户要看上下文起因）。
4. **媒体 / 发送人**：解析逻辑与 chat 模式相同，但仅作用在话题内消息 + 入口。
5. **禁止**：不要再调 `container_id_type=chat`、不要扫描所在群其他消息、不要 follow 群主线里同期的其他 thread。

## 4. 总结报告

参考 [`references/summary-format.md`](references/summary-format.md)。

**chat 模式**必含 5 节：
1. **概览** —— 群名、时间窗口、消息总数、参与人数、话题数、媒体数
2. **主要讨论话题** —— 按 thread 或时间聚类的 3~8 个主题，每个一句话概括 + 关键消息引用（含发送人 + 时间）
3. **关键观点 / 意见** —— 出现频次高或引发讨论的观点，标注提出人
4. **决策与结论** —— 已达成共识或负责人拍板的结论，标注决策人 / 时间
5. **行动项 & 后续步骤** —— `[ ] @负责人 - 事项 - DDL`（DDL 不明确就写「未明确」）

**thread 模式**结构简化（无需「主要讨论话题」节，因为本身就是单话题）：
1. **概览** —— 所属群名（可选）、thread_id、入口消息时间、参与人数、回复总数、媒体数
2. **入口** —— 入口消息原文（≤ 100 字摘录）+ 发送人 + 时间，作为讨论起因
3. **关键观点 / 意见** —— 同 chat 模式
4. **决策与结论** —— 同 chat 模式
5. **行动项 & 后续步骤** —— 同 chat 模式

两种模式都附「媒体清单」附录。

## 5. 输出

**不写文件**。报告直接在控制台输出（Markdown 文本，渲染由终端自处理）。

**字数上限：6000 字**（中文字符 + 英文 token 字符合计；用 `len(report)` 估算即可，无需精确分词）。超出上限时按下面优先级**主动压缩**，**不要**再额外让用户确认：

1. 缩减「主要讨论话题」节的子条目（chat 模式）：每个话题的「关键发言」引用从 3~5 条压到 1~2 条
2. 「关键观点 / 意见」「决策与结论」每节最多 5 条，超出合并 / 删次要项
3. 「行动项」最多 8 条，按 owner 明确度排序，未指派的优先删
4. 媒体清单只保留前 10 条，其余写「另有 N 条媒体」
5. 仍超 6K：把「主要讨论话题」内每个话题压缩成一句话总结，去掉子要点
6. 极限兜底：保留概览 + 关键决策 + 行动项三节，其余全删

末尾不需要文件路径，也不询问"是否打开"——没有文件。可附一行元信息：`📊 N 条主线 / M 个话题 / P 人 / X 媒体 · 窗口 <start>~<end>`。

## 6. 需要用户选择时

- 每次只问 1 个简短问题。
- 提供清晰、互斥的候选项，并允许用户输入其他值。
- 群选择时显示群名和 chat_id，避免选错同名群。

## 7. 边界

- **只读**：只读取群、消息和成员信息；禁止发送、回复、置顶、删除消息、修改群配置或成员。
- **隐私保护**：不输出应用凭据、访问令牌、邮箱、手机号、身份证号等敏感信息；发送人无法安全解析时使用脱敏标识。
- **不虚构**：只依据实际读取到的消息总结；缺失的负责人、DDL、结论或上下文明确标注「未明确」。
- **区分决策和建议**：只有明确拍板、确认执行或形成共识的内容才能列入「决策与结论」；提议、设想、争议和待确认事项列入「关键观点 / 意见」，并标注状态。
- 群消息 > 5000 条：先提示规模，问用户是否缩窗口 / 抽样 / 全量（全量耗 token）
- `im.v1.message.list` 失败 / 无权限：报错并提示用户确认机器人是否在群内（`im.v1.chatMembers.isInChat`）
- 全部消息为撤回 / 系统消息：直接报告"窗口内无有效讨论"，不强凑
- 用户没在群里：`isInChat=false` 时停止，提示用户先加群
