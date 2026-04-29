#!/usr/bin/env bash
# ================================================================
# Fix: rewrite commit author email → nyoikepaul2@gmail.com
# Then force-push so GitHub counts all 17 as YOUR contributions
# Usage: GITHUB_TOKEN=ghp_xxx bash fix_email_and_repush.sh
# ================================================================
set -euo pipefail

REPO="NyoikePaul/odoo-enterprise-rag-agent-"
CORRECT_EMAIL="nyoikepaul2@gmail.com"
CORRECT_NAME="NyoikePaul"
BRANCH="main"

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  echo "❌  Set GITHUB_TOKEN=ghp_... before running"
  exit 1
fi

REMOTE="https://${GITHUB_TOKEN}@github.com/${REPO}.git"

echo "📦 Cloning repo..."
rm -rf _fix_email_build
git clone "$REMOTE" _fix_email_build
cd _fix_email_build

git config user.email "$CORRECT_EMAIL"
git config user.name  "$CORRECT_NAME"

echo "✏️  Rewriting author on all commits..."

# Rewrite every commit in history to use the correct email/name
git filter-branch --env-filter "
  export GIT_AUTHOR_NAME='${CORRECT_NAME}'
  export GIT_AUTHOR_EMAIL='${CORRECT_EMAIL}'
  export GIT_COMMITTER_NAME='${CORRECT_NAME}'
  export GIT_COMMITTER_EMAIL='${CORRECT_EMAIL}'
" --tag-name-filter cat -- --branches --tags

echo ""
echo "📋 Verifying author on last 20 commits:"
git log --format="%h  %ae  %s" -20

echo ""
echo "🚀 Force-pushing rewritten history..."
git push --force origin "$BRANCH"

echo ""
echo "✅  Done! All commits now authored by ${CORRECT_EMAIL}"
echo ""
echo "⏳  GitHub processes contributions every few minutes."
echo "    Refresh https://github.com/NyoikePaul in 2–5 minutes"
echo "    and you should see 17 green squares on April 28."
echo ""
echo "🏅  Once contributions register, check:"
echo "    https://github.com/NyoikePaul?tab=achievements"
