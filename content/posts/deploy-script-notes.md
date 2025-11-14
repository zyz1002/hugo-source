---
title: "deploy.ps1 脚本详解"
date: 2025-11-14T19:30:00+08:00
tags:
  - 部署
  - PowerShell
  - 自动化
draft: false
---

趁着把 Hugo 站点部署流程跑通，记录一下 PowerShell 脚本到底做了什么，以及 `.ps1` 是什么格式。

## `.ps1` 是什么

- `.ps1` 是 **PowerShell Script** 的扩展名，和 `.sh`（bash）、`.bat`（CMD）类似，用来保存 PowerShell 命令的集合。
- 运行方式：在 PowerShell 终端里执行 `.\deploy.ps1`，脚本就会按照写好的顺序一条条命令地执行。

## 脚本结构拆解

1. **参数区（Param）**
   - `SourceMessage`：提交源码仓库时用的 commit message。
   - `DeployMessage`：提交 `public/` 仓库时的 commit message，默认会带时间戳。

2. **`$ErrorActionPreference = "Stop"`**
   - 遇到错误立即中断，不会悄悄忽略，方便定位问题。

3. **`Invoke-Step` 函数**
   - 包装所有命令的执行逻辑：
     - 在指定目录执行命令（比如源码根目录或 `public/`）。
     - 打印 `>> path :: command`，方便看日志。
     - 捕获退出码：如果命令返回非 0 且没有标记 `-IgnoreExitCode`，就直接抛错。
     - 返回退出码，供外部判断（例如 `git diff --cached --quiet` 判断有没有改动）。

4. **关键变量**
   - `$root`：当前脚本所在目录（Hugo 源码根目录）。
   - `$public`：`public/` 子目录，也就是 GitHub Pages 仓库。

## 实际流程

1. **检查源码仓库状态**
   - `git status` 打印当前分支和改动。

2. **提交源码（hugo-source 仓库）**
   - `git add .`
   - `git diff --cached --quiet`：如果返回 0，说明没有需要提交的内容；否则执行 `git commit -m <SourceMessage>` 并 `git push origin main`。

3. **构建站点**
   - `hugo --minify` 在 `$root` 目录运行，重新生成 `public/`。

4. **提交发布仓库（zyz1002.github.io）**
   - 进入 `public/`，再次 `git status`、`git add .`。
   - 判断 `git diff --cached --quiet` 的结果，有改动就 `git commit -m <DeployMessage>`，并且 `git push origin main -f`（部署仓库允许覆盖历史）。

5. **结束提示**
   - 所有步骤通过后打印 `部署完成 Done`。

## 常见提示

- `LF will be replaced by CRLF`：只是行尾换行警告，不影响结果。
- `No source/public changes to commit.`：表示这一步没有发现新的改动，脚本就跳过 commit + push。
- `Command 'git push origin main' failed with exit code 1`：通常是分支名称不一致或没有设置 upstream，修复后重新跑脚本即可。

> 以后若脚本报错，就对照上面这些步骤，看看是卡在哪一层：Git 状态不干净？分支名不对？还是 `hugo` 没跑成功。这样就能迅速定位问题。

