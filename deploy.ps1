Param(
    [string]$SourceMessage = "chore: update content",
    [string]$DeployMessage = $(Get-Date -Format "'deploy: 'yyyy-MM-dd HH:mm")
)

$ErrorActionPreference = "Stop"

function Invoke-Step {
    param(
        [string]$Command,
        [string]$WorkingDirectory = (Get-Location),
        [switch]$IgnoreExitCode
    )

    Push-Location $WorkingDirectory
    Write-Host ">> $WorkingDirectory :: $Command" -ForegroundColor Yellow
    Invoke-Expression $Command
    $exitCode = $LASTEXITCODE
    Pop-Location

    if (-not $IgnoreExitCode -and $exitCode -ne 0) {
        throw "Command '$Command' failed with exit code $exitCode"
    }

    return $exitCode
}

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$public = Join-Path $root "public"

# 1. 确保源码仓库状态可提交
Invoke-Step "git status"

# 2. 添加并提交源码（如果有变化）
Invoke-Step "git add ."
$sourceDiff = Invoke-Step "git diff --cached --quiet" -IgnoreExitCode
if ($sourceDiff -eq 0) {
    Write-Host "No source changes to commit." -ForegroundColor Cyan
} else {
    Invoke-Step "git commit -m `"$SourceMessage`""
    Invoke-Step "git push origin main"
}

# 3. 构建站点
Invoke-Step "hugo --minify" $root

# 4. 处理 public 仓库
Invoke-Step "git status" $public
Invoke-Step "git add ." $public
$publicDiff = Invoke-Step "git diff --cached --quiet" $public -IgnoreExitCode
if ($publicDiff -eq 0) {
    Write-Host "No public changes to commit." -ForegroundColor Cyan
} else {
    Invoke-Step "git commit -m `"$DeployMessage`"" $public
    Invoke-Step "git push origin main -f" $public
}

Write-Host "部署完成 Done" -ForegroundColor Green

