---
title: "GitHub 部署流程复盘"
date: 2025-11-14T18:20:00+08:00
tags:
  - 部署
  - Git
  - 随笔
draft: false
---

最近在折腾 Hugo + GitHub Pages，整理一下问答要点，免得下次忘记：

## 基本概念

- **Git**：版本管理工具，记录每次修改。`git add` 暂存，`git commit` 生成快照，`git push` 同步到远程。
- **仓库**：存放项目的文件夹；本地一个，GitHub 上也有一个，通过远程地址 (`origin`) 连接。
- **分支**：仓库里的不同时间线，默认是 `main` 或 `master`，通常只用主分支即可。
- **GitHub Pages**：GitHub 提供的静态站托管，把构建好的 HTML/CSS/JS 推到指定仓库就能上线。

## 当前工作流

1. `yuu_blog/` 作为源码仓库（`hugo-source`），只保存 Markdown、主题、配置等。`public/` 被 `.gitignore` 忽略。
2. 每次写完内容运行 `deploy.ps1`：
   - 提交源码并 `git push origin main`（同步到 `hugo-source`）
   - 执行 `hugo --minify` 重新生成 `public/`
   - 在 `public/` 仓库里 `git add/commit/push -f origin main`，覆盖 `zyz1002.github.io`
3. 几秒后访问 `https://zyz1002.github.io/` 就能看到最新站点。

## 自动部署是什么

当前属于“半自动”：脚本帮我把源码提交 + 构建 + 推送都跑一遍，但仍然在本地执行。若改用 GitHub Actions，就可以只 push 源码，服务器自动构建并部署到 `gh-pages` 分支。这一步以后再尝试。

## 常用 Git 命令速查

- `git init`：把当前目录变成 Git 仓库。
- `git status`：查看有哪些文件修改、哪些已暂存。
- `git add .`：把所有改动加入暂存区，准备提交。
- `git commit -m "msg"`：保存一次快照，记录当前改动。
- `git remote add origin <url>`：为远程仓库起名 `origin`，方便 push/pull。
- `git push origin main`：把本地 `main` 分支推到远程 `origin`。
- `git pull origin main`：拉取远程 `main` 的更新并合并到本地。
- `git branch -M main`：把当前分支重命名为 `main`。
- `git push -f origin main`：强制推送，常用于只保存构建产物的仓库。

> 记录完毕，下次遇到 Git/GitHub 相关问题就先翻这篇。
