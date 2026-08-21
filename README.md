\# lark-chat-summary



通过 Codex 和飞书/Lark OpenAPI MCP，按需读取飞书群聊或 thread 历史消息，并生成结构化总结。



\## 能力



\- 总结整个群指定时间段内的消息

\- 展开并总结 thread 回复

\- 提取关键观点、明确决策和行动项

\- 保留媒体附件 key，不下载文件本体

\- 默认只读，不发送、删除或修改飞书消息



\## 前置条件



\- Codex CLI、IDE 扩展或桌面端

\- Node.js 20+

\- 飞书企业自建应用

\- 机器人已加入目标群

\- 已开通并发布群聊、消息和成员只读权限



\## 安装 Skill



将仓库克隆到：



```powershell

git clone <仓库地址> "$env:USERPROFILE\\.agents\\skills\\lark-chat-summary"
