# 消息拉取细节

## 主线消息

```text
im.v1.message.list(
  query={
    container_id_type: "chat",
    container_id: "<oc_xxx>",
    start_time: "<unix_seconds>",
    end_time:   "<unix_seconds>",
    sort_type:  "ByCreateTimeAsc",
    page_size:  50,
    page_token: "<上一页返回的 token，首页不传>"
  }
)
```

翻页：`has_more=true` 时，用返回的 `page_token` 再调，直到 `has_more=false`。**累积条数 > 1000** 时提醒用户考虑缩窗口。

### 响应字段（每条 item）

| 字段 | 用途 |
|------|------|
| `message_id` | 唯一 ID |
| `root_id` | 若非空，说明这是某话题的回复 |
| `parent_id` | 直接回复对象的 message_id |
| `thread_id` | 话题 ID（属于话题串时存在） |
| `msg_type` | `text` / `post` / `image` / `file` / `media` / `audio` / `sticker` / `merge_forward` / `share_chat` / `interactive` 等 |
| `body.content` | JSON 字符串，按 msg_type 解析（见下） |
| `mentions[]` | `@` 提及的人 `key=@_user_1` → `id=open_id` |
| `sender.id` / `sender.id_type` | 发送人 ID（open_id） |
| `create_time` | 毫秒时间戳字符串 |
| `updated_time` | 同上，撤回 / 编辑会更新 |
| `deleted` | true 表示已撤回，**跳过** |

### body.content 解析（按 msg_type）

| msg_type | content 形态 | 提取 |
|---------|-------------|------|
| `text` | `{"text":"..."}` | text |
| `post` | `{"title":"...","content":[[{"tag":"text","text":"..."}, {"tag":"a","href":"...","text":"..."}, {"tag":"img","image_key":"..."}, {"tag":"at","user_id":"open_id"}]]}` | 拼接每行；保留链接 + image_key |
| `image` | `{"image_key":"img_xxx"}` | image_key（媒体清单） |
| `file` | `{"file_key":"file_xxx","file_name":"...","file_size":N}` | file_key + file_name |
| `media` | `{"file_key":"media_xxx","file_name":"...","duration":N}` | file_key + duration（视频/音频）|
| `audio` | `{"file_key":"audio_xxx","duration":N}` | file_key |
| `sticker` | `{"file_key":"sticker_xxx"}` | 一般跳过，仅计数 |
| `share_chat` | `{"chat_id":"oc_..."}` | 引用其他群 |
| `merge_forward` | `{"title":"...","content":"..."}` | 转发的内容（含原始消息序列） |
| `interactive` | 卡片 JSON | 取 `header.title` + `elements` 文本部分 |

> ⚠️ 不要下载图片/视频本体，**只在报告里列 `image_key`/`file_key` + 所在消息时间和发送人**，让用户在飞书内点开。

## Thread（话题）展开

### chat 模式下的话题展开

主线扫一遍，收集所有 **非空且未见过** 的 `thread_id`，去重成集合。对每个 thread_id：

```text
im.v1.message.list(
  query={
    container_id_type: "thread",
    container_id: "<thread_id>",
    sort_type: "ByCreateTimeAsc",
    page_size: 50
    # 注意：thread 容器不支持 start_time/end_time，会全量返回
  }
)
```

拉完后客户端按 `create_time` 过滤掉时间窗外的（如果时间窗很重要）。**话题首楼可能在主线中已存在**，按 `message_id` 去重，避免双计。

### thread 模式（直接以话题为目标）

⚠️ **只调一次 `container_id_type=thread`，不再读群主线**。

```text
im.v1.message.list(
  query={
    container_id_type: "thread",
    container_id: "<thread_id>",
    sort_type: "ByCreateTimeAsc",
    page_size: 50
  }
)
```

入口识别（按优先级尝试）：

1. 返回列表中 `message_id == root_id` 的消息（一般是第一条），标记为「入口」
2. 若首页第一条不是入口（如 thread 已被截断），保留 `root_id` 字段记录原始入口 ID，写进报告附录但不再去拉原消息体
3. 入口缺失也照常生成报告，在「概览」标注「入口消息缺失」

时间窗：客户端用 `create_time` 过滤 thread 内回复；**入口消息无论时间是否在窗内都保留**（用户要看话题起因）。

**禁止**：thread 模式下任何情况都不能再调 `container_id_type=chat` 或拉其他 thread。

## 时间戳处理

API 返回 `create_time` 是**毫秒字符串**（如 `"1709876543210"`），输入 `start_time`/`end_time` 用**秒级**字符串。换算：

```text
start_time = UnixSeconds(now_in_Asia/Shanghai - 30 days)
end_time   = UnixSeconds(now_in_Asia/Shanghai)
display_time = FormatInTimezone(create_time_ms / 1000, Asia/Shanghai)
```

## 用户名解析

已知 chat_id 时，用只读群成员接口获取成员并建立名称映射：

```text
im.v1.chatMembers.get(
  path={ chat_id: "<oc_xxx>" },
  query={ member_id_type: "open_id", page_size: 100 }
)
```

按 `page_token` 拉取完整成员列表，将 `member_id` 与 `name` 缓存在内存映射中。无法解析的发送人使用脱敏后的 open_id 标识；不要为补全姓名申请或调用额外通讯录权限。

## 性能 / 规模控制

| 条数 | 处理 |
|------|------|
| ≤ 500 | 全量拉取 + 全文摘要 |
| 500 ~ 2000 | 全量拉取，但分批摘要：按 thread 或时间段切片，逐片摘要后聚合 |
| > 2000 | 先提示规模，让用户决定缩窗 / 抽样（每 N 条取 1 条） / 仅看话题 |

## 错误处理

| 错误 | 处置 |
|------|------|
| 401 / 无权限 | 调 `im_v1_chatMembers_isInChat`，不在群里就提示用户加入 |
| 429 限流 | 等待 5s 重试，最多 3 次 |
| 单个 thread 拉取失败 | 跳过该 thread 并在报告附录标注 |
| 全部消息为撤回/系统 | 直接输出"窗口内无有效讨论" |
