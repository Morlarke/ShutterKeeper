#!/bin/bash
#
# 把「快门闪选」发布到 GitHub。
#
# 请在你自己的终端里运行 —— Codex 的沙盒里没有你的 GitHub 凭据，也不允许我改动项目的 .git。
#
#   Scripts/publish-to-github.sh                      # 仓库名 ShutterKeeper
#   Scripts/publish-to-github.sh MyRepo private       # 自定义名字与可见性
#   Scripts/publish-to-github.sh ShutterKeeper private Morlarke
#                                                     # 第三个参数给 GitHub 用户名（没装 gh 时用）
#   SK_REMOTE=git@github.com:you/Repo.git Scripts/publish-to-github.sh   # 直接指定远程地址
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

REPO_NAME="${1:-ShutterKeeper}"
VISIBILITY="${2:-public}"
GITHUB_USER="${3:-}"
AUTHOR_NAME="快门镖局-陈师"
AUTHOR_EMAIL="thechengsir@foxmail.com"
COMMIT_MESSAGE="快门闪选 beta0.1：导入 / 批量改名 / 审阅打分，与 Lightroom Classic 互认星级"

if [[ "$VISIBILITY" != "public" && "$VISIBILITY" != "private" ]]; then
    echo "第二个参数只能是 public 或 private"
    exit 2
fi

echo "==> 1/4 初始化仓库"
if [[ ! -d .git ]]; then
    git init -q
fi
# 没配置过 git 身份时，用项目作者信息（只作用于这个仓库，不动你的全局配置）
if [[ -z "$(git config user.name || true)" ]]; then
    git config user.name "$AUTHOR_NAME"
fi
if [[ -z "$(git config user.email || true)" ]]; then
    git config user.email "$AUTHOR_EMAIL"
fi

echo "==> 2/4 检查有没有不该提交的大文件"
FOUND_BIG=0
while IFS= read -r file; do
    [[ -f "$file" ]] || continue
    size=$(stat -f%z "$file")
    if [[ "$size" -gt 5242880 ]]; then
        echo "    ⚠️  $file（$(du -h "$file" | cut -f1)）"
        FOUND_BIG=1
    fi
done < <(git ls-files --cached --others --exclude-standard)
if [[ "$FOUND_BIG" == "1" ]]; then
    echo "    以上文件超过 5MB，确认要提交再继续（这些多半应该放在 .gitignore 里）。"
    read -r -p "    继续提交？[y/N] " answer
    [[ "$answer" == "y" || "$answer" == "Y" ]] || exit 1
fi

echo "==> 3/4 提交"
git add -A
git branch -M main 2>/dev/null || true
if git diff --cached --quiet; then
    echo "    没有需要提交的改动"
else
    git commit -q -m "$COMMIT_MESSAGE"
    echo "    已提交：$(git log --oneline -1)"
fi

echo "==> 4/4 推到 GitHub"
if command -v gh >/dev/null 2>&1; then
    if git remote get-url origin >/dev/null 2>&1; then
        git push -u origin main
    else
        gh repo create "$REPO_NAME" --"$VISIBILITY" --source . --remote origin --push
    fi
else
    # 没装 gh：直接把已有的仓库推上去（仓库需要先在网页上建好）
    remote="${SK_REMOTE:-}"
    if [[ -z "$remote" ]]; then
        if [[ -n "$GITHUB_USER" ]]; then
            remote="https://github.com/${GITHUB_USER}/${REPO_NAME}.git"
        elif [[ -n "$(git config github.user || true)" ]]; then
            remote="https://github.com/$(git config github.user)/${REPO_NAME}.git"
        fi
    fi
    if [[ -z "$remote" ]]; then
        cat <<MANUAL

    没有检测到 GitHub CLI（gh），也不知道远程地址。两种办法：

    A. 装 gh 后重跑本脚本：
         brew install gh && gh auth login

    B. 把 GitHub 用户名作为第三个参数传进来（仓库要先在网页上建好）：
         Scripts/publish-to-github.sh $REPO_NAME $VISIBILITY <你的用户名>

       还没建仓库的话：打开 https://github.com/new
         Repository name 填 $REPO_NAME，不要勾选 Add README / .gitignore / license

    首次推送会要求认证：用户名填 GitHub 用户名，密码处粘贴 Personal Access Token
    （https://github.com/settings/tokens 生成，勾 repo 权限）。

MANUAL
        exit 0
    fi
    echo "    远程地址：$remote"
    git remote remove origin 2>/dev/null || true
    git remote add origin "$remote"
    if ! git push -u origin main; then
        cat <<'HINT'

    推送失败。常见原因：
      * 远程仓库里已经有 README（推送被拒，提示 fetch first / non-fast-forward）
        → 这是刚建的空仓库，可以直接覆盖：git push -u origin main --force
      * 认证失败（提示 Authentication failed / password）
        → 密码处要粘贴 Personal Access Token，不是 GitHub 登录密码
          https://github.com/settings/tokens 生成，勾 repo 权限
      * 仓库不存在（提示 Repository not found）
        → 先到 https://github.com/new 建一个同名仓库（不要勾任何初始化选项）
HINT
        exit 1
    fi
fi

echo
echo "发布完成 🎉"
if command -v gh >/dev/null 2>&1; then
    echo "仓库地址：$(gh repo view --json url -q .url 2>/dev/null || echo "$(git remote get-url origin 2>/dev/null)")"
else
    echo "仓库地址：$(git remote get-url origin 2>/dev/null)"
fi
echo "（代码刚刚推上去，GitHub 的 CI 会自动跑构建 + 自检，几分钟后可在 Actions 页面看到）"
