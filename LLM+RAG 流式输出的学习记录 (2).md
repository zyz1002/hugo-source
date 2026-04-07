# 从需求到底层：LLM\+RAG 流式输出的学习记录（含LangChain实现与底层原理）

最近做了一个 LLM\+RAG 智能问答项目，原本以为用 LangChain 封装好的接口就能快速实现，但实际开发中遇到了一堆底层问题——异步/同步混淆、线程安全报错、SSE 流式推送异常，逼得我从“只会用框架”沉下心去补底层知识。这篇博客记录了我的完整学习过程，从需求出发，到遇困、求解、吃透原理，再到最终的两种实现方案，希望能帮到和我一样困惑的开发者。

## 一、我的核心需求

做一个 LLM\+RAG 智能问答应用，核心需求有 3 点：

1. 用 RAG 检索知识库，获取相关资料后，交给 LLM 生成回答；

2. 实现**SSE 流式输出**：前端发起一次请求，后端持续推送内容（RAG 检索状态 \+ LLM 逐字回答），不用前端反复请求；

3. 工具调用可视化：RAG 检索的每一步（如“正在检索”“检索完成”）都能实时推送到前端，提升用户体验。

原本以为“LangChain 封装好了 Agent 和流式接口，直接调用就行”，结果写出来的代码要么卡顿、要么报错，彻底陷入困境。

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

2. **状态无法推送**：RAG 检索的“正在检索”“检索完成”状态，没法实时推送到前端，用户只能看到最终回答，体验很差；

3. **偶尔报错**：偶尔会出现 `RuntimeError: Non\-thread\-safe operation invoked on an event loop`，完全不知道原因。

我以为是 LangChain 的用法不对，查了文档才发现：不是用法错了，是我不懂 LangChain 底层帮我做了什么——异步、线程、队列这些底层概念，我完全是模糊的，只知道“调用接口”，遇到问题根本无法定位。

无奈之下，只能停下框架的使用，先补底层知识，否则就算侥幸解决问题，下次遇到还是会懵。

## 三、核心疑问：SSE 明明支持实时推送，为什么用 LangChain 就不行？

在补底层知识的过程中，我一直有个困惑：SSE 本身是支持实时推送的，为什么一旦结合 LangChain \+ Agent \+ RAG 工具，就无法实时将工具状态推送到前端，只能等工具执行完、LLM 开始生成后，才能收到消息？其实答案很简单，核心不是 SSE 失效，而是 LangChain 的流式机制和工具执行的线程特性，导致状态消息没有被“接入”SSE 流。

### 3\.1 关键结论：不是 SSE 不能实时，是状态消息没被捕获

SSE 的实时推送能力没有问题，问题出在 **LangChain 的流式输出范围** 和 **工具执行的线程隔离**：

1. LangChain 的 `astream`或 `astream\_events` 接口，默认只捕获 **LLM 生成的流式 token**，不会自动捕获 RAG 工具内部的状态（比如“正在检索”“检索完成”）；

2. RAG 工具是同步阻塞函数，LangChain 会自动将其放到 **子线程** 执行，而 SSE 的 `yield` 推送跑在主线程的协程中，子线程的状态消息如果不主动传递，主线程根本无法捕获，自然无法通过 SSE 推送给前端；

3. 我最初的错误写法，只监听了 LLM 的流式 chunk，没有将子线程中工具的状态消息，接入到 SSE 的推送队列中，所以前端只能等 LLM 开始输出，才能收到消息，误以为 SSE 不能实时推送。

### 3\.2 通俗理解：两个“独立世界”的消息隔离

可以用一个简单的比喻，理解这种隔离现象：

- 主线程（协程）：相当于“前端通信员”，负责通过 SSE 向前端推送消息，只能接收自己“视野内”的消息（比如 LLM 流式输出）；

- 子线程（RAG 工具）：相当于“后端执行者”，负责执行检索任务，在执行过程中会产生状态消息，但它和“通信员”没有直接联系，无法主动把消息交给“通信员”；

- LangChain 只负责“让执行者干活”（自动把子线程跑起来），但不负责“让执行者把消息交给通信员”，这一步需要我们手动实现。

### 3\.3 解决方案：手动搭建“消息桥梁”，让状态接入 SSE 流

解决这个问题的核心，就是在子线程（RAG 工具）和主线程（SSE 推送）之间，搭建一座“消息桥梁”——也就是我们之前提到的`asyncio\.Queue`，再用 `loop\.call\_soon\_threadsafe` 保证跨线程消息传递的安全，具体步骤很简单：

1. 在主线程中创建 `asyncio\.Queue`，作为消息中转站，统一接收 LLM 流式内容和 RAG 工具状态；

2. 在 RAG 工具中，手动调用状态推送函数（比如 `send\_status`），将“正在检索”“检索完成”等消息，通过 `call\_soon\_threadsafe` 安全写入队列；

3. 主线程的 SSE 推送循环，持续从队列中获取消息，不管是 LLM 的流式 token，还是 RAG 的状态，都能实时 `yield` 推送给前端。

这也是方案 2（LangChain 完整版）中，为什么要加入全局队列和 `send\_status` 函数的原因——本质就是手动打通子线程和主线程的消息通道，让 SSE 能实时捕获所有需要推送的内容。

## 四、补底层：搞懂这 4 个概念，才能真正解决问题

结合我的需求，我发现核心是要搞懂「同步/异步」「线程/进程」「队列」「SSE 流式」这 4 个概念，尤其是它们之间的关联——这也是我最混乱的地方，整理成最易懂的笔记，避免后续再忘。

### 4\.1 同步 vs 异步：会不会“卡住”服务？

这是最基础也是最关键的区别，直接决定服务是否卡顿：

- **同步（Sync）**：代码执行时，必须等当前操作完成，才能执行下一行（比如 RAG 检索时，要等 2 秒才能拿到结果，这期间代码完全不动）；

- **异步（Async）**：代码执行时，遇到等待操作（如网络请求、睡眠），不会卡住，而是去执行其他任务，等待完成后再回来继续执行。

我的坑：RAG 工具是同步阻塞的（普通 def 函数 \+ time\.sleep），如果直接在 FastAPI 主线程执行，会卡住整个服务——因为 FastAPI 是基于异步事件循环的，主线程一旦阻塞，所有请求都无法处理。

### 4\.2 进程 vs 线程：谁来执行代码？

用最通俗的比喻理解：

- **进程**：相当于一个“工厂”，有独立的厂房（内存）、设备（资源），一个工厂崩了，不影响其他工厂；

- **线程**：相当于工厂里的“工人”，共享工厂的资源，一个工人出事，可能连累整个工厂（一个线程崩了，整个进程可能崩溃）。

结合我的项目：

- 启动 FastAPI 服务（uvicorn main:app），操作系统会创建一个「进程」，这个进程是服务的载体；

- 进程内部有一个「主线程」，跑着 FastAPI 的事件循环（Event Loop），负责处理所有异步请求、SSE 推送；

- RAG 这种同步阻塞任务，不能让主线程去做（会卡住），所以要交给「子线程」去执行，主线程继续处理其他请求。

### 4\.3 队列（Queue）：解决“多来源消息统一输出”

我的需求里，有两个消息来源要推送到前端：

1. RAG 工具的状态（正在检索、检索完成）；

2. LLM 逐字生成的回答。

这两个消息来自不同的“执行载体”（RAG 在子线程，LLM 在主线程协程），如果直接推送，会出现乱序、丢失的问题。

队列就是解决这个问题的——相当于一个“消息中转站”，不管是子线程的 RAG 状态，还是主线程的 LLM 内容，都先放进队列，主线程再从队列里拿消息，统一推送给前端，保证顺序和安全。

注意：Python 里有两种队列，用法完全不同：

- `asyncio\.Queue`：协程专用，非线程安全，只能在主线程的事件循环里使用；

- `queue\.Queue`：线程安全，适合跨线程通信，但我项目里用的是前者（因为 SSE 跑在协程里）。

### 4\.4 SSE 流式：后端主动推消息的“长连接”

普通接口是“请求\-响应\-关闭”，而 SSE（Server\-Sent Events）是“请求\-长连接\-持续推送”，正好适合 LLM 逐字输出和状态推送。

核心原理：

1. 前端发起一次 HTTP 请求，后端返回 `media\_type=\&\#34;text/event\-stream\&\#34;`，告诉前端“这是一个长连接，我会持续推消息”；

2. 后端用 `yield` 关键字，每 yield 一次，就向前端推送一条消息，格式必须是 `data: 消息内容\\n\\n`；

3. 前端监听这个连接，收到消息后实时渲染（比如逐字显示回答、显示检索状态）。

### 4\.5 关键坑：子线程不能直接操作主线程的队列

这是我之前报错 `RuntimeError` 的原因：RAG 跑在子线程，想直接往主线程的 `asyncio\.Queue` 里放消息，而 `asyncio\.Queue` 是非线程安全的，跨线程操作会破坏事件循环状态，导致程序崩溃。

解决方法：用 `loop\.call\_soon\_threadsafe`——让子线程“委托”主线程自己去操作队列，相当于“子线程发请求，主线程自己干活”，避免跨线程直接操作。

### 4\.6 补充：yield 与 LangChain 异步迭代器（关键疑问解析）

在开发过程中，我曾有个核心疑问：LangChain 生成的是迭代器吗？为什么用 yield 就能实现逐字推送？结合前文代码和底层知识，整理出最易懂的解析，彻底搞懂这两个关键知识点的关联：

首先明确核心结论：**LangChain 的 astream/astream\_events 接口，返回的不是普通迭代器，而是「异步迭代器」**，yield 的作用是“逐段推送内容”，而非“被调用一次输出一个字”，具体拆解如下：

1. **LangChain 异步迭代器的本质**：普通迭代器（如 for 循环遍历列表）是同步的，执行时会阻塞主线程；而 LangChain 的 `agent\.astream\_events\(\)` 或 `llm\.astream\(\)` 返回的是 `async iterable`（异步可迭代对象），本质是异步迭代器。这也是为什么我们必须用 `async for` 去遍历它——因为 LLM 生成内容是异步操作（需要等待模型返回结果），异步迭代器会“等待模型生成一段内容，就返回一段”，不会阻塞主线程的事件循环，这是实现实时流式的基础。

2. **yield 的作用：逐段推送，而非“被动调用”**：结合我们项目中的代码场景，yield 并不是“被调用一次就输出一个字”，而是“每获取到一段有效内容，就主动推送一次”。比如方案 2 中的核心代码：
        `async for event in agent\.astream\_events\(\.\.\.\):
    if event\[\&\#34;event\&\#34;\] == \&\#34;on\_chat\_model\_stream\&\#34;:
        token = event\[\&\#34;data\&\#34;\]\[\&\#34;chunk\&\#34;\]\.content
        if token:
            yield f\&\#34;data: \{token\}\\n\\n\&\#34;`
        这里的逻辑是：异步迭代器（`agent\.astream\_events\(\)`）持续产生事件，当捕获到 LLM 流式生成事件（`on\_chat\_model\_stream`）时，提取其中的 token（可以是单个字、单个词，也可以是短片段），只要 token 有效，就用 yield 推送给前端。也就是说，yield 的执行时机，取决于异步迭代器是否产生了有效内容，每产生一段就推送一段，前端就能实时接收并渲染，实现“逐字输出”的效果。
      

3. **同步迭代器与异步迭代器的区别（避坑关键）**：我最初的错误写法，用了普通 `for` 循环遍历 `agent\.stream\(\)`（同步迭代器），这种情况下，同步迭代器会等 **整个 RAG 工具执行完、LLM 生成完所有内容**，才一次性生成所有 chunk，所以 yield 也只能一次性推送所有内容，无法实现实时流式；而正确写法用 `async for \+ agent\.astream\_events\(\)`（异步迭代器），生成一段、推送一段，这才是真正的实时流式输出。

简单总结：LangChain 提供异步迭代器，负责“逐段获取 LLM 生成内容”，yield 负责“逐段将内容推送给前端”，两者结合，再配合 SSE 长连接，就实现了我们需求中的“实时流式输出”。

## 五、两种实现方案：不用 LangChain vs 用 LangChain

吃透底层知识后，我分别写了“不用 LangChain”和“用 LangChain”的代码，对比之下，就能清晰看到 LangChain 帮我们封装了多少底层工作。

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

- 用 `asyncio\.to\_thread` 把同步 RAG 丢到子线程，避免阻塞主线程；

- 用 `call\_soon\_threadsafe` 实现子线程到主线程的安全通信；

- 用 `asyncio\.Queue` 统一消息，保证输出顺序；

- 自己实现 SSE 推送，每一步都可控。

### 方案 2：用 LangChain（封装好的，简洁高效）

吃透底层后，再用 LangChain 就会发现，它帮我们自动处理了“子线程执行同步工具”“异步流式”等底层工作，代码简洁很多，和我最初的尝试相比，多了状态推送和线程安全处理：

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

- LangChain 自动将同步工具（search\_knowledge\_base）丢到子线程，不用我们手动调用 `asyncio\.to\_thread`；

- 用 `agent\.astream\_events` 可以轻松获取 LLM 流式输出，还能监听工具调用的各种事件；

- 我们只需要关注“业务逻辑”（工具、状态推送），底层的异步、线程、调度全部由 LangChain 封装。

### 方案 3：LangChain 极简流式输出（无多余要求，快速实现）

如果不需要状态推送、不需要复杂的 Agent 调度，只是单纯用 LangChain 实现 LLM 流式输出（含 RAG 工具调用，无多余配置），代码可以极简——去掉所有冗余，保留核心逻辑，直接运行即可满足基础流式需求：

```python
import asyncio
import json
from fastapi import FastAPI
from fastapi.responses import StreamingResponse
from langchain_openai import ChatOpenAI
from langchain_core.tools import tool
from langgraph.prebuilt import create_react_agent

# 1. 初始化 FastAPI 和 LLM
app = FastAPI()
llm = ChatOpenAI(model="gpt-3.5-turbo", temperature=0)

# 2. 简单 RAG 工具（同步阻塞，无需额外状态）
@tool
def search_knowledge_base(query: str) -> str:
    """简单 RAG 检索，模拟阻塞耗时"""
    import time
    time.sleep(1.5)  # 模拟向量库查询
    return f"RAG 检索结果：{query} 的相关信息为..."

# 3. 初始化 Agent（极简配置）
agent = create_react_agent(llm, [search_knowledge_base])

# 4. 核心流式接口（无多余逻辑，仅实现流式输出）
@app.get("/chat/simple-stream")
async def simple_stream(msg: str):
    async def stream_generator():
        # LangChain 自动处理异步、线程，直接流式获取结果
        async for event in agent.astream_events(
            {"messages": [("human", msg)]},
            version="v2"
        ):
            # 只推送 LLM 生成的文字内容
            if event["event"] == "on_chat_model_stream":
                token = event["data"]["chunk"].content
                if token:
                    yield f"data: {json.dumps({{"content": token}})}\n\n"
        # 流式结束标记
        yield "data: [DONE]\n\n"
    
    return StreamingResponse(stream_generator(), media_type="text/event-stream")
```

极简版核心说明（无多余要求，直接用）：

- 去掉全局变量、状态推送、队列等冗余逻辑，仅保留“工具 \+ Agent \+ 流式推送”核心；

- LangChain 自动处理所有底层：同步工具丢子线程、异步流式生成、线程安全，无需手动干预；

- 接口直接返回 StreamingResponse，前端发起请求后，即可收到 LLM 逐字流式输出；

- 运行方式和之前一致：`uvicorn 文件名:app \-\-reload`，访问 `http://localhost:8000/chat/simple\-stream?msg=你的问题` 即可测试。

补充：如果连 RAG 工具都不需要，只需要 LLM 纯流式输出，可再简化（去掉 tool 和 Agent，直接调用 LLM 流式）：

```python
from fastapi import FastAPI
from fastapi.responses import StreamingResponse
from langchain_openai import ChatOpenAI
from langchain_core.messages import HumanMessage

app = FastAPI()
llm = ChatOpenAI(model="gpt-3.5-turbo", temperature=0)

# LLM 纯流式输出（无任何工具）
@app.get("/chat/llm-only-stream")
async def llm_only_stream(msg: str):
    async def stream():
        async for chunk in llm.astream([HumanMessage(content=msg)]):
            if chunk.content:
                yield f"data: {chunk.content}\n\n"
        yield "data: [DONE]\n\n"
    return StreamingResponse(stream(), media_type="text/event-stream")
```

## 六、学习总结

这次学习最大的收获，不是“学会了用 LangChain 实现流式输出”，而是“明白了框架背后的底层逻辑”——一开始只想着“拿来就用”，遇到问题就手足无措，直到沉下心补完同步/异步、线程、队列的知识，才发现原来那些报错、卡顿，都是因为不懂底层原理。

### 1\. 核心感悟

- 框架是“工具”，不是“黑盒”：LangChain 确实能帮我们省很多事，但如果不懂底层，遇到问题就无法定位，更无法灵活调整；

- 先解决“能用”，再追求“懂原理”：一开始可以先调用框架接口实现需求，再回头拆解底层，这样学习更有针对性；

- 关键底层知识点（必记）：
        

    - 同步阻塞任务（如 RAG）必须放子线程，避免卡住主线程；

    - `asyncio\.Queue` 非线程安全，跨线程写入必须用 `call\_soon\_threadsafe`；

    - SSE 流式的核心是“长连接 \+ yield 推送”，格式必须规范。

### 2\. 两种方案对比

|方案|优点|缺点|适用场景|
|---|---|---|---|
|不用 LangChain（原生）|底层可控，能彻底理解原理，灵活调整|代码量大，需要自己处理线程、异步、队列|学习底层、定制化需求高的场景|
|用 LangChain|代码简洁，快速实现需求，减少重复工作|底层封装较深，调试时需要懂原理|实际项目开发、快速落地需求|
|LangChain 极简版|代码最少，无需配置，快速实现基础流式|无状态推送，定制化能力弱|无多余要求，仅需基础流式输出|

### 3\. 面试重点（结合我的项目）

如果面试官问“你项目里的流式输出是怎么做的”，可以这样回答：

> 我项目里的 LLM\+RAG 流式输出，用 FastAPI \+ SSE 实现，底层结合了 LangChain 框架。因为 RAG 检索是同步阻塞任务，LangChain 会自动将其放到子线程执行，避免阻塞主线程的事件循环。我用 asyncio\.Queue 统一汇聚 RAG 状态和 LLM 流式内容，由于子线程不能直接操作队列，我用 call\_soon\_threadsafe 实现线程安全通信，最后主线程通过 yield 把消息实时推送到前端，实现逐字输出和状态可视化。
> 
> 

最后，希望这篇学习记录能帮到和我一样的开发者——不要害怕底层知识，也不要盲目依赖框架，先懂原理，再用工具，才能真正把项目做好、做深。

> （注：文档部分内容可能由 AI 生成）
