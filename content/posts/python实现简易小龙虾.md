---
title: "简易 QQ AI 助手 — 小龙虾 bot 实现记录"
date: 2026-04-11T10:00:00+08:00
categories: ["tech"]
tags:
  - Python
  - LLM
  - Claude
  - Agent
  - QQ
draft: false
description: "记录从零开始搭建一个 QQ AI 助手（小龙虾）的完整过程，包括技术选型、架构设计、多轮对话、长期记忆、定时任务与 MCP 工具机制的实现。"
---

# 从零手搓一个 QQ AI 助手 — 小龙虾 bot 开发全记录

> 本文记录了从零开始搭建一个 QQ AI 助手（小龙虾）的完整过程，包括动机、技术选型、架构设计、逐步实现、踩坑记录和最终成果。

<!-- TOC -->

- [1. 背景](#1-背景)
- [2. 技术选型](#2-技术选型)
- [3. 整体架构设计](#3-整体架构设计)
- [4. 初始项目搭建](#4-初始项目搭建)
- [5. 第一优先级：核心补全](#5-第一优先级核心补全)
  - [5.1 多轮对话上下文](#51-多轮对话上下文)
  - [5.2 错误处理](#52-错误处理)
  - [5.3 实用工具：计算器](#53-实用工具计算器)
- [6. 第二优先级：记忆与个性化](#6-第二优先级记忆与个性化)
  - [6.1 长期记忆](#61-长期记忆)
  - [6.2 用户画像](#62-用户画像)
  - [6.3 记忆状态管理](#63-记忆状态管理)
- [7. 第三优先级：定时任务与主动推送](#7-第三优先级定时任务与主动推送)
  - [7.1 调度器原理](#71-调度器原理)
  - [7.2 实现方案](#72-实现方案)
- [8. 踩坑记录](#8-踩坑记录)
- [9. 最终项目结构](#9-最终项目结构)
- [10. MCP 工具机制详解](#10-mcp-工具机制详解)
- [11. 未来规划](#11-未来规划)

<!-- /TOC -->

## 1. 背景

记录一下python实现一个简易版QQ AI 助手的小龙虾 bot，基于 claude-agent-sdk 实现。


## 2. 技术选型

| 技术 | 选择 | 理由 |
|------|------|------|
| 语言 | Python 3.12 | 生态丰富，AI/异步库完善 |
| 包管理 | uv | 比 pip 快，锁定依赖 |
| QQ 框架 | qq-botpy | 官方 SDK，文档齐全 |
| AI 引擎 | claude-agent-sdk | 支持 agent 工具调用、MCP 协议 |
| 数据库 | aiosqlite | 异步 SQLite，轻量无需额外服务 |
| 定时任务 | apscheduler + croniter | Python 生态最成熟的调度库 |
| 环境配置 | python-dotenv | .env 管理敏感信息 |

## 3. 整体架构设计

在动手写代码之前，先做一个优先级分层的设计：

```
第一优先级（核心）    → 没有这些，bot 基本不可用
  ├─ 多轮对话上下文
  ├─ 实用工具
  └─ 错误处理

第二优先级（记忆）    → 让 bot 从"工具"变成"助手"
  ├─ 长期记忆
  ├─ 用户画像
  └─ 记忆状态管理

第三优先级（主动）    → 让 bot 从"被动"变成"主动"
  ├─ 定时提醒
  └─ 主动推送

第四优先级（进阶）    → 锦上添花
  ├─ 图片/文件理解
  ├─ 外部 API 工具
  └─ 管理员指令
```

**分层原则**：每一层依赖上一层的基础。先让 bot 能正常对话，再加记忆，再加主动性。

## 4. 初始项目搭建

项目从一个最小可运行的骨架开始：

### 4.1 项目结构

```
open_claw_byhand/
├── src/
│   ├── bot.py           # QQ bot 主入口
│   ├── agent.py         # Claude Agent SDK 封装
│   └── tools/           # MCP 工具目录
│       ├── __init__.py
│       ├── server.py    # MCP server 注册中心
│       └── time_tool.py # 时间工具
├── main.py              # 占位入口
├── pyproject.toml       # 依赖配置
├── .env                 # 环境变量
└── .python-version      # Python 版本
```

### 4.2 最小可运行版本

初始版本只有一个消息回显功能——用户发消息，bot 转发给 Claude，Claude 回复。

```python
# src/bot.py 核心骨架
from botpy import Client
from botpy.message import C2CMessage
from claude_agent_sdk import ClaudeAgentOptions, query

async def ask_claude(prompt: str) -> str:
    options = ClaudeAgentOptions(
        model="你的模型名字",
        system_prompt="你是小龙虾助手，使用中文回答问题",
        permission_mode="bypassPermissions",
    )
    async for message in query(prompt=prompt, options=options):
        # 提取回复
        ...
    return result

class MyClient(Client):
    async def on_c2c_message_create(self, message: C2CMessage):
        result = await ask_claude(message.content)
        await message.reply(content=result)
```

这个版本能跑，但每次对话都是独立的——没有上下文，没有记忆，没有工具，没有错误处理。

## 5. 第一优先级：核心补全

### 5.1 多轮对话上下文

**问题**：每次消息都是独立的，agent 不知道之前聊了什么。

**方案**：用 aiosqlite 存储对话历史，每次调用 agent 前读取最近 20 条，拼接到 prompt 中。

**数据库设计**：

```sql
CREATE TABLE conversations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT NOT NULL,   -- 用户 openid，按用户隔离
    role TEXT NOT NULL,         -- user / assistant
    content TEXT NOT NULL,      -- 消息内容
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

**核心逻辑**：

```python
# db.py
async def get_recent_messages(session_id: str, limit: int = 20) -> list[dict]:
    async with aiosqlite.connect(DB_PATH) as db:
        cursor = await db.execute(
            "SELECT role, content FROM conversations "
            "WHERE session_id = ? ORDER BY id DESC LIMIT ?",
            (session_id, limit),
        )
        rows = await cursor.fetchall()
        return [dict(row) for row in reversed(rows)]  # 反转为时间正序
```

**上下文注入**：将历史对话格式化为文本，拼接到 prompt 里：

```python
def _build_context_prompt(history, user_message):
    if not history:
        return user_message
    context_lines = []
    for msg in history:
        role = "用户" if msg["role"] == "user" else "小龙虾"
        context_lines.append(f"[{role}]: {msg['content']}")
    return f"近期对话记录：\n" + "\n".join(context_lines) + f"\n\n用户最新消息：{user_message}"
```

**关键决策**：为什么选 SQLite 而不是 JSON 文件？

- SQLite 有原子写入，不怕并发丢数据
- 查询灵活（按时间、按用户、按关键词）
- 数据量大了性能不会下降
- `aiosqlite` 是异步的，不阻塞 bot 的事件循环

### 5.2 错误处理

**问题**：API 超时、网络异常时 bot 直接崩溃或无响应。

**方案**：三级错误处理。

**第一级 — ask_claude 内的重试**：

```python
max_retries = 2
for attempt in range(max_retries + 1):
    try:
        result = await call_agent(prompt)
        break
    except asyncio.TimeoutError:
        if attempt < max_retries:
            logger.warning("超时，第 %d 次重试", attempt + 1)
            await asyncio.sleep(1)
            continue
        return "思考太久了，请再试一次"
    except (ConnectionError, OSError) as e:
        if attempt < max_retries:
            await asyncio.sleep(1)
            continue
        return "网络出了点问题，请稍后再试"
    except Exception as e:
        logger.error("异常: %s", e, exc_info=True)
        return "出了点问题，请稍后再试"
```

**第二级 — 消息处理函数的兜底**：

```python
async def _handle_c2c_message(message):
    try:
        result = await ask_claude(text, session_id)
    except Exception as e:
        logger.error("消息处理异常: %s", e, exc_info=True)
        result = "出了点问题，请稍后再试"
    await message.reply(content=result)
```

**原则**：对用户友好，对开发者可排查（错误记录到日志）。

### 5.3 实用工具：计算器

MCP 工具的实现遵循固定模式，计算器是一个简单的起点。

```python
# src/tools/calculator_tool.py
import re
from claude_agent_sdk import tool

_SAFE_PATTERN = re.compile(r"^[\d\s+\-*/().%^]+$")

@tool(
    name="calculate",
    description="计算数学表达式",
    input_schema={"expression": str},
)
async def calculate(args):
    expression = args.get("expression", "").strip()
    if not _SAFE_PATTERN.match(expression):
        return {"content": [{"type": "text", "text": "表达式包含不安全字符"}]}
    py_expr = expression.replace("^", "**")
    result = eval(py_expr, {"__builtins__": {}}, {})
    return {"content": [{"type": "text", "text": f"{expression} = {result}"}]}
```

**安全考虑**：用正则白名单限制输入，只允许数字和基本运算符，防止代码注入。

## 6. 第二优先级：记忆与个性化

### 6.1 长期记忆

**对话历史 vs 长期记忆的区别**：

| | 对话历史 | 长期记忆 |
|---|---|---|
| 内容 | 原始消息 | 提炼后的关键信息 |
| 生命周期 | 7 天自动清理 | 永久保留 |
| 用途 | 维持上下文连贯性 | 跨会话记住用户偏好 |
| 示例 | 用户说的每一句话 | "用户喜欢吃辣"、"用户在北京" |

**方案**：给 agent 提供两个 MCP 工具——`save_memory` 和 `recall_memories`，让 agent 自己决定什么值得记。

```python
@tool(name="save_memory", description="保存重要信息到长期记忆")
async def save_memory(args):
    user_id = args.get("user_id")
    content = args.get("content")
    category = args.get("category", "fact")  # fact / preference / reminder
    await db.save_memory(user_id, content, category)
    return {"content": [{"type": "text", "text": f"已记住：{content}"}]}
```

**记忆注入**：每次对话前，将该用户的所有 active 记忆加载到 prompt：

```
你记住的关于用户的信息：
- [preference] 用户喜欢吃辣
- [fact] 用户在北京
- [reminder] 用户明天有会议

近期对话记录：
[用户]: 你好
[小龙虾]: 你好！

用户最新消息：今天吃什么好？
请根据上下文和记忆继续对话。
```

### 6.2 用户画像

不单独建用户表，直接用 memories 表的 `category` 字段区分：

- `preference` — 偏好（"叫我小明"、"喜欢吃甜的"）
- `fact` — 事实（"在北京"、"程序员"）
- `reminder` — 提醒（"明天有会议"）

### 6.3 记忆状态管理

**问题**：用户说"我喜欢吃辣"，后来又说"我现在喜欢吃甜的了"。两条记忆都存在，怎么办？

**方案**：给 memories 加 `status` 字段（`active` / `outdated` / `completed`）。

```
用户：我现在喜欢吃甜的了
→ agent 看到 prompt 里有 "用户喜欢吃辣"
→ agent 调用 update_memory_status(keyword="辣", status="outdated")
→ agent 调用 save_memory("用户喜欢吃甜的", category="preference")
→ prompt 中只保留：用户喜欢吃甜的
```

```python
async def update_memory_status(user_id, keyword, status):
    cursor = await db.execute(
        "UPDATE memories SET status = ? "
        "WHERE user_id = ? AND content LIKE ? AND status = 'active'",
        (status, user_id, f"%{keyword}%"),
    )
    return cursor.rowcount
```

**查询时自动过滤**：`get_memories()` 和 `search_memories()` 只返回 `status = 'active'` 的记录。

**兼容旧表**：用 `ALTER TABLE` 自动补列，已有的旧数据自动为 `active`：

```python
try:
    await db.execute("ALTER TABLE memories ADD COLUMN status TEXT NOT NULL DEFAULT 'active'")
except aiosqlite.OperationalError:
    pass  # 列已存在，忽略
```

## 7. 第三优先级：定时任务与主动推送

### 7.1 调度器原理

定时任务的核心是**调度器**——一个后台线程，每隔约 1 秒检查一次"有没有任务该执行了"。

```
注册 → 轮询 → 执行
  │      │      │
  │      │      └─ 时间到了，调用回调函数（发消息给用户）
  │      └─ APScheduler 后台自动轮询
  └─ 用户说"每天8点提醒我" → 存数据库 + 注册到调度器
```

APScheduler 支持三种触发方式：

| 方式 | 用法 | 示例 |
|------|------|------|
| `date` | 一次性，到点执行 | "明天下午3点提醒我" |
| `cron` | 循环，cron 表达式 | "每天早上8点提醒我" → `0 8 * * *` |
| `interval` | 固定间隔 | 每 2 小时提醒一次 |

### 7.2 实现方案

**数据库**：

```sql
CREATE TABLE reminders (
    id INTEGER PRIMARY KEY,
    user_id TEXT NOT NULL,
    content TEXT NOT NULL,         -- 提醒内容
    trigger_type TEXT NOT NULL,    -- date / cron
    trigger_expr TEXT NOT NULL,    -- "2025-04-12 15:00:00" 或 "0 8 * * *"
    status TEXT NOT NULL DEFAULT 'active',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

**调度器核心**：

```python
from apscheduler.schedulers.asyncio import AsyncIOScheduler
from apscheduler.triggers.cron import CronTrigger
from apscheduler.triggers.date import DateTrigger

scheduler = AsyncIOScheduler(timezone=ZoneInfo("Asia/Shanghai"))

def _add_job_to_scheduler(reminder):
    if reminder["trigger_type"] == "date":
        run_date = datetime.fromisoformat(reminder["trigger_expr"])
        scheduler.add_job(
            _send_reminder,                     # 回调函数
            trigger=DateTrigger(run_date=run_date),
            args=[reminder["user_id"], reminder["content"]],
        )
    elif reminder["trigger_type"] == "cron":
        parts = reminder["trigger_expr"].split()
        scheduler.add_job(
            _send_reminder,
            trigger=CronTrigger(minute=parts[0], hour=parts[1], ...),
            args=[reminder["user_id"], reminder["content"]],
        )
```

**主动推送**：到点后，回调函数通过 QQ bot API 主动发消息：

```python
async def _send_reminder(user_id, content, reminder_id, trigger_type):
    await _bot_client.api.post_c2c_message(
        openid=user_id,
        msg_type=0,
        content=f"提醒：{content}",
    )
    # 一次性提醒执行后标记完成
    if trigger_type == "date":
        await db.complete_reminder(reminder_id)
```

**启动恢复**：bot 重启后，从数据库读取所有 active 的提醒，重新注册到调度器：

```python
async def restore_all_reminders():
    reminders = await db.get_active_reminders()
    for r in reminders:
        _add_job_to_scheduler(r)
```

**MCP 工具**：agent 提供三个工具给用户使用：

- `create_reminder` — 用户说"明早8点提醒我"，agent 自动解析为 `trigger_type + trigger_expr`
- `list_reminders` — 查看所有活跃提醒
- `cancel_reminder` — 取消指定提醒

## 8. 踩坑记录

### 8.1 时区不一致

**现象**：设置了一个提醒，到点后没有触发。问 bot 几点，它说的时间和本地差了 8 小时。

**原因**：代码中没有指定时区，系统默认使用 UTC。用户和 agent 都按北京时间交流，但调度器按 UTC 执行。

**修复**：

```python
# 统一使用 Asia/Shanghai
LOCAL_TZ = ZoneInfo("Asia/Shanghai")
scheduler = AsyncIOScheduler(timezone=LOCAL_TZ)

# 时间工具返回带时区标注
now = datetime.now(LOCAL_TZ)
return f"当前时间: {now.strftime('%Y-%m-%d %H:%M:%S')} (Asia/Shanghai, UTC+8)"

# 调度器解析时间时加上时区
run_date = datetime.fromisoformat(trigger_expr).replace(tzinfo=LOCAL_TZ)
```



## 9. 最终项目结构

```
open_claw_byhand/
├── src/
│   ├── bot.py                  # QQ bot 主入口，消息处理
│   ├── db.py                   # 数据库模块（对话、记忆、提醒）
│   ├── scheduler.py            # APScheduler 调度器封装
│   ├── agent.py                # Claude Agent SDK 独立测试
│   └── tools/                  # MCP 工具目录
│       ├── __init__.py
│       ├── server.py           # MCP server 注册中心
│       ├── time_tool.py        # 时间查询
│       ├── calculator_tool.py  # 计算器
│       ├── memory_tool.py      # 记忆存取 + 状态管理
│       └── reminder_tool.py    # 提醒 CRUD
├── .env                        # 环境变量（API key 等）
├── pyproject.toml              # 项目依赖
└── conversations.db            # SQLite 数据库（运行时生成）
```

## 10. MCP 工具机制详解

本项目的一个核心设计是 **MCP（Model Context Protocol）工具机制**。它让 agent 能主动调用工具，而不是只做文本回复。

### 添加一个新工具的完整流程

以计算器为例：

**第一步**：在 `src/tools/` 下创建工具文件

```python
# src/tools/calculator_tool.py
from claude_agent_sdk import tool

@tool(name="calculate", description="计算数学表达式", input_schema={"expression": str})
async def calculate(args):
    expression = args["expression"]
    result = eval(expression, {"__builtins__": {}}, {})
    return {"content": [{"type": "text", "text": f"{expression} = {result}"}]}
```

**第二步**：在 `server.py` 注册

```python
# src/tools/server.py
from .calculator_tool import calculate

mcp_server = create_sdk_mcp_server(
    name="nanoclaw-tools",
    tools=[get_current_time, calculate],
)
```

**第三步**：在 `bot.py` 的 `allowed_tools` 中放行

```python
allowed_tools=["get_current_time", "calculate"],
```

完成。agent 在需要时会自动调用这个工具。

### 消息流全链路

```
用户发消息 "帮我算 123 * 456"
  │
  ▼
bot.py: on_c2c_message_create()
  │  提取 user_openid 作为 session_id
  │  从 DB 读取历史对话 + 长期记忆
  │  拼接上下文 prompt
  ▼
ask_claude(prompt, session_id)
  │  调用 claude-agent-sdk 的 query()
  │
  ▼
Agent 思考："这是一个计算请求，我需要调用工具"
  │  调用 calculate(expression="123 * 456")
  │  工具返回 "123 * 456 = 56088"
  │
  ▼
Agent 生成最终回复："123 × 456 = 56088"
  │
  ▼
bot.py: 保存 user 和 assistant 消息到 DB
  │  截断超长内容（QQ 限制 2000 字）
  ▼
message.reply(content=result)
  │
  ▼
用户在 QQ 看到回复
```



整个项目在本地运行，基于 Claude Code SDK 调用模型 API。没有单独统计 token 消耗，主要成本就是 API 调用费用。不过现在市面上有功能更加完善的产品，这个只是为了理解大概的原理。

## 11. 未来规划

已完成的功能构成了一个可用的个人助手。后续计划：

- **图片/文件理解**：接收用户发送的图片，用多模态能力分析
- **外部 API 集成**：天气查询、网页搜索、新闻摘要
- **管理员指令**：`/stats`、`/reset`、`/config`
- **包结构整理**：代码迁移到 `src/nanoclaw/` 包下
- **部署方案**：Docker / systemd 服务化，长期稳定运行
