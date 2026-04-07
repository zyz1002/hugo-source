---
title: "从需求到底层：LLM+RAG 流式输出的学习记录"
date: 2026-04-07T10:00:00+08:00
categories: ["tech"]
tags:
  - LLM
  - RAG
  - LangChain
  - Python
draft: false
---

最近做了一个 LLM\+RAG 智能问答项目，原本以为用 LangChain 封装好的接口就能快速实现，但实际开发中遇到了一堆底层问题——异步/同步混淆、线程安全报错、SSE 流式推送异常，逼得我从"只会用框架"沉下心去补底层知识。这篇博客记录了我的完整学习过程，从需求出发，到遇困、求解、吃透原理，再到最终的两种实现方案，希望能帮到和我一样困惑的开发者。

## 一、我的核心需求

做一个 LLM\+RAG 智能问答应用，核心需求有 3 点：

1. 用 RAG 检索知识库，获取相关资料后，交给 LLM 生成回答；

2. 实现**SSE 流式输出**：前端发起一次请求，后端持续推送内容（RAG 检索状态 + LLM 逐字回答），不用前端反复请求；

3. 工具调用可视化：RAG 检索的每一步（如"正在检索""检索完成"）都能实时推送到前端，提升用户体验。

原本以为"LangChain 封装好了 Agent 和流式接口，直接调用就行"，结果写出来的代码要么卡顿、要么报错，彻底陷入困境。

## 二、最初的尝试：直接用 LangChain 写，却遇坑无数

一开始我直接用 LangChain 的 Agent 和 astream 接口，想快速实现流式输出，代码大概是这样的：

```python
from langchain_openai import ChatOpenAI
from langchain_core.tools import tool
from langchain.agents import create_react_agent

# 1. 模拟 RAG 工具（同步阻塞）
@tool
def search_knowledge_base(query: str) -> str:
    """RAG 知识库检索，模拟阻塞耗时"""
    import time
    time.sleep(2)  # 模拟向量库查询的阻塞等待
    return f"关于【{query}】的检索结果：RAG 是检索增强生成"

# 2. 初始化 LLM 和 Agent
llm = ChatOpenAI(model="gpt-3.5-turbo", temperature=0)
agent = create_react_agent(llm, [search_knowledge_base])

# 3. 尝试直接流式输出（问题百出）
def chat_stream(user_msg: str):
    # 直接调用 agent.astream，想逐字返回
    for chunk in agent.stream({"messages": [("human", user_msg)]}):
        yield f"data: {chunk.content}\n\n"
```

这段代码看似简单，却出现了两个致命问题：

1. **服务卡顿**：RAG 工具是同步阻塞的，调用时会卡住整个 FastAPI 服务，其他用户的请求完全无法响应；

2. **状态无法推送**：RAG 检索的"正在检索""检索完成"状态，没法实时推送到前端，用户只能看到最终回答，体验很差；

3. **偶尔报错**：偶尔会出现 `RuntimeError: Non-thread-safe operation invoked on an event loop`，完全不知道原因。

我以为是 LangChain 的用法不对，查了文档才发现：不是用法错了，是我不懂 LangChain 底层帮我做了什么——异步、线程、队列这些底层概念，我完全是模糊的，只知道"调用接口"，遇到问题根本无法定位。

无奈之下，只能停下框架的使用，先补底层知识，否则就算侥幸解决问题，下次遇到还是会懵。

## 三、补底层：搞懂这 4 个概念，才能真正解决问题

结合我的需求，我发现核心是要搞懂「同步/异步」「线程/进程」「队列」「SSE 流式」这 4 个概念，尤其是它们之间的关联——这也是我最混乱的地方，整理成最易懂的笔记，避免后续再忘。

### 3.1 同步 vs 异步：会不会"卡住"服务？

这是最基础也是最关键的区别，直接决定服务是否卡顿：

- **同步（Sync）**：代码执行时，必须等当前操作完成，才能执行下一行（比如 RAG 检索时，要等 2 秒才能拿到结果，这期间代码完全不动）；

- **异步（Async）**：代码执行时，遇到等待操作（如网络请求、睡眠），不会卡住，而是去执行其他任务，等待完成后再回来继续执行。

我的坑：RAG 工具是同步阻塞的（普通 def 函数 + time.sleep），如果直接在 FastAPI 主线程执行，会卡住整个服务——因为 FastAPI 是基于异步事件循环的，主线程一旦阻塞，所有请求都无法处理。

### 3.2 进程 vs 线程：谁来执行代码？

用最通俗的比喻理解：

- **进程**：相当于一个"工厂"，有独立的厂房（内存）、设备（资源），一个工厂崩了，不影响其他工厂；

- **线程**：相当于工厂里的"工人"，共享工厂的资源，一个工人出事，可能连累整个工厂（一个线程崩了，整个进程可能崩溃）。

结合我的项目：

- 启动 FastAPI 服务（uvicorn main:app），操作系统会创建一个「进程」，这个进程是服务的载体；

- 进程内部有一个「主线程」，跑着 FastAPI 的事件循环（Event Loop），负责处理所有异步请求、SSE 推送；

- RAG 这种同步阻塞任务，不能让主线程去做（会卡住），所以要交给「子线程」去执行，主线程继续处理其他请求。

### 3.3 队列（Queue）：解决"多来源消息统一输出"

我的需求里，有两个消息来源要推送到前端：

1. RAG 工具的状态（正在检索、检索完成）；

2. LLM 逐字生成的回答。

这两个消息来自不同的"执行载体"（RAG 在子线程，LLM 在主线程协程），如果直接推送，会出现乱序、丢失的问题。

队列就是解决这个问题的——相当于一个"消息中转站"，不管是子线程的 RAG 状态，还是主线程的 LLM 内容，都先放进队列，主线程再从队列里拿消息，统一推送给前端，保证顺序和安全。

注意：Python 里有两种队列，用法完全不同：

- `asyncio.Queue`：协程专用，非线程安全，只能在主线程的事件循环里使用；

- `queue.Queue`：线程安全，适合跨线程通信，但我项目里用的是前者（因为 SSE 跑在协程里）。

### 3.4 SSE 流式：后端主动推消息的"长连接"

普通接口是"请求-响应-关闭"，而 SSE（Server-Sent Events）是"请求-长连接-持续推送"，正好适合 LLM 逐字输出和状态推送。

核心原理：

1. 前端发起一次 HTTP 请求，后端返回 `media_type="text/event-stream"`，告诉前端"这是一个长连接，我会持续推消息"；

2. 后端用 `yield` 关键字，每 yield 一次，就向前端推送一条消息，格式必须是 `data: 消息内容\n\n`；

3. 前端监听这个连接，收到消息后实时渲染（比如逐字显示回答、显示检索状态）。

### 3.5 关键坑：子线程不能直接操作主线程的队列

这是我之前报错 `RuntimeError` 的原因：RAG 跑在子线程，想直接往主线程的 `asyncio.Queue` 里放消息，而 `asyncio.Queue` 是非线程安全的，跨线程操作会破坏事件循环状态，导致程序崩溃。

解决方法：用 `loop.call_soon_threadsafe`——让子线程"委托"主线程自己去操作队列，相当于"子线程发请求，主线程自己干活"，避免跨线程直接操作。

## 四、两种实现方案：不用 LangChain vs 用 LangChain

吃透底层知识后，我分别写了"不用 LangChain"和"用 LangChain"的代码，对比之下，就能清晰看到 LangChain 帮我们封装了多少底层工作。

### 方案 1：不用 LangChain（纯原生实现，吃透底层）

这种方式需要自己处理线程、异步、队列、跨线程通信，适合彻底理解原理，代码如下（可直接运行）：

```python
import asyncio
import json
from fastapi import FastAPI
from fastapi.responses import StreamingResponse

app = FastAPI()

# 全局变量：主线程的事件循环和队列（用于子线程通信）
_main_loop = None
_output_queue = None

def send_status(text: str):
    """子线程调用：推送 RAG 状态到前端（安全写入队列）"""
    if _main_loop and _output_queue:
        # 关键：委托主线程写入队列，避免跨线程直接操作
        _main_loop.call_soon_threadsafe(
            _output_queue.put_nowait,
            json.dumps({"type": "status", "content": text})
        )

# 1. 原生 RAG 工具（同步阻塞）
def search_rag(query: str) -> str:
    send_status(f"🔍 正在检索【{query}】...")
    import time
    time.sleep(2)  # 模拟阻塞
    send_status("✅ 检索完成，开始生成回答...")
    return "RAG 是检索增强生成，用于提升 LLM 回答的准确性"

# 2. 原生 LLM 流式模拟（模拟逐字生成）
async def mock_llm_stream(rag_result: str):
    answer = f"根据检索结果：{rag_result}"
    for char in answer:
        await asyncio.sleep(0.05)  # 模拟 LLM 生成延迟
        await _output_queue.put(json.dumps({
            "type": "content",
            "content": char
        }))

# 3. 核心流式函数（自己处理线程、队列、SSE）
async def chat_stream(user_msg: str):
    global _main_loop, _output_queue

    # 拿到主线程的事件循环
    _main_loop = asyncio.get_running_loop()
    # 创建统一队列，汇聚所有消息
    _output_queue = asyncio.Queue()

    # 后台任务：执行 RAG（子线程）+ LLM 流式（协程）
    async def worker():
        # 把同步 RAG 丢到子线程执行，不阻塞主线程
        rag_result = await asyncio.to_thread(search_rag, user_msg)
        # 执行 LLM 流式生成
        await mock_llm_stream(rag_result)
        # 发送结束标记
        await _output_queue.put(None)

    # 启动后台任务
    task = asyncio.create_task(worker())

    # SSE 推送主循环：持续从队列取消息，推给前端
    try:
        while True:
            item = await _output_queue.get()
            if item is None:
                break
            yield f"data: {item}\n\n"
    except GeneratorExit:
        # 前端断开连接，取消后台任务
        task.cancel()
    finally:
        yield "data: [DONE]\n\n"

# 接口
@app.get("/chat/nolangchain")
async def chat_nolangchain(msg: str):
    return StreamingResponse(
        chat_stream(msg),
        media_type="text/event-stream"
    )
```

核心亮点：

- 用 `asyncio.to_thread` 把同步 RAG 丢到子线程，避免阻塞主线程；

- 用 `call_soon_threadsafe` 实现子线程到主线程的安全通信；

- 用 `asyncio.Queue` 统一消息，保证输出顺序；

- 自己实现 SSE 推送，每一步都可控。

### 方案 2：用 LangChain（封装好的，简洁高效）

吃透底层后，再用 LangChain 就会发现，它帮我们自动处理了"子线程执行同步工具""异步流式"等底层工作，代码简洁很多，和我最初的尝试相比，多了状态推送和线程安全处理：

```python
import asyncio
import json
from fastapi import FastAPI
from fastapi.responses import StreamingResponse
from langchain_openai import ChatOpenAI
from langchain_core.tools import tool
from langgraph.prebuilt import create_react_agent

app = FastAPI()

# 全局变量：用于子线程推送状态
_main_loop = None
_output_queue = None

def send_status(text: str):
    """工具调用时，推送状态到前端"""
    if _main_loop and _output_queue:
        _main_loop.call_soon_threadsafe(
            _output_queue.put_nowait,
            json.dumps({"type": "status", "content": text})
        )

# 1. LangChain RAG 工具（同步阻塞）
@tool
def search_knowledge_base(query: str) -> str:
    """RAG 知识库检索工具"""
    send_status(f"🔍 正在检索【{query}】...")
    import time
    time.sleep(2)  # 模拟阻塞
    send_status("✅ 检索完成，开始生成回答...")
    return "RAG 是检索增强生成，用于提升 LLM 回答的准确性"

# 2. 初始化 LLM 和 Agent（LangChain 封装）
llm = ChatOpenAI(model="gpt-3.5-turbo", temperature=0)
agent = create_react_agent(llm, [search_knowledge_base])

# 3. 核心流式函数（LangChain 版）
async def chat_stream_langchain(user_msg: str):
    global _main_loop, _output_queue

    _main_loop = asyncio.get_running_loop()
    _output_queue = asyncio.Queue()

    # 后台任务：运行 LangChain Agent 流式
    async def worker():
        # LangChain 自动处理：同步工具丢子线程，异步流式生成
        async for event in agent.astream_events(
            {"messages": [("human", user_msg)]},
            version="v2"
        ):
            # 推送 LLM 逐字内容
            if event["event"] == "on_chat_model_stream":
                token = event["data"]["chunk"].content
                if token:
                    await _output_queue.put(json.dumps({
                        "type": "content",
                        "content": token
                    }))
        # 结束标记
        await _output_queue.put(None)

    asyncio.create_task(worker())

    # SSE 推送
    while True:
        item = await _output_queue.get()
        if item is None:
            break
        yield f"data: {item}\n\n"
    yield "data: [DONE]\n\n"

# 接口
@app.get("/chat/langchain")
async def chat_langchain(msg: str):
    return StreamingResponse(
        chat_stream_langchain(msg),
        media_type="text/event-stream"
    )
```

核心亮点：

- LangChain 自动将同步工具（search_knowledge_base）丢到子线程，不用我们手动调用 `asyncio.to_thread`；

- 用 `agent.astream_events` 可以轻松获取 LLM 流式输出，还能监听工具调用的各种事件；

- 我们只需要关注"业务逻辑"（工具、状态推送），底层的异步、线程、调度全部由 LangChain 封装。

## 五、学习总结

这次学习最大的收获，不是"学会了用 LangChain 实现流式输出"，而是"明白了框架背后的底层逻辑"——一开始只想着"拿来就用"，遇到问题就手足无措，直到沉下心补完同步/异步、线程、队列的知识，才发现原来那些报错、卡顿，都是因为不懂底层原理。

### 1. 核心感悟

- 框架是"工具"，不是"黑盒"：LangChain 确实能帮我们省很多事，但如果不懂底层，遇到问题就无法定位，更无法灵活调整；

- 先解决"能用"，再追求"懂原理"：一开始可以先调用框架接口实现需求，再回头拆解底层，这样学习更有针对性；

- 关键底层知识点（必记）：

    - 同步阻塞任务（如 RAG）必须放子线程，避免卡住主线程；

    - `asyncio.Queue` 非线程安全，跨线程写入必须用 `call_soon_threadsafe`；

    - SSE 流式的核心是"长连接 + yield 推送"，格式必须规范。

### 2. 两种方案对比

|方案|优点|缺点|适用场景|
|---|---|---|---|
|不用 LangChain（原生）|底层可控，能彻底理解原理，灵活调整|代码量大，需要自己处理线程、异步、队列|学习底层、定制化需求高的场景|
|用 LangChain|代码简洁，快速实现需求，减少重复工作|底层封装较深，调试时需要懂原理|实际项目开发、快速落地需求|

### 3. 面试重点（结合我的项目）

如果面试官问"你项目里的流式输出是怎么做的"，可以这样回答：

> 我项目里的 LLM+RAG 流式输出，用 FastAPI + SSE 实现，底层结合了 LangChain 框架。因为 RAG 检索是同步阻塞任务，LangChain 会自动将其放到子线程执行，避免阻塞主线程的事件循环。我用 asyncio.Queue 统一汇聚 RAG 状态和 LLM 流式内容，由于子线程不能直接操作队列，我用 call_soon_threadsafe 实现线程安全通信，最后主线程通过 yield 把消息实时推送到前端，实现逐字输出和状态可视化。

最后，希望这篇学习记录能帮到和我一样的开发者——不要害怕底层知识，也不要盲目依赖框架，先懂原理，再用工具，才能真正把项目做好、做深。

> （注：文档部分内容可能由 AI 生成）
