#!/bin/bash

# github-secrets-guard: Pre-Push Check Script
# Run this before every git push to catch risky files.
# Usage: bash pre_push_check.sh

echo ""
echo "============================="
echo "  PRE-PUSH SAFETY CHECK"
echo "============================="
echo ""

echo "Files staged for commit:"
echo ""
git diff --cached --name-only
echo ""

echo "Checking staged files for risks..."
echo ""

RISKY=0

# Check if any .env files are staged
if git diff --cached --name-only | grep -qE "^\.env|\.env\."; then
  echo "  STOP: A .env file is staged for commit. Remove it with:"
  echo "  git rm --cached .env"
  RISKY=1
fi

# Check for key/cert files
if git diff --cached --name-only | grep -qE "\.(pem|key)$|id_rsa"; then
  echo "  STOP: A key or certificate file is staged. Remove it."
  RISKY=1
fi

# Check for credential files
if git diff --cached --name-only | grep -qE "credentials\.json|service-account\.json|secrets\.json"; then
  echo "  STOP: A credentials file is staged. Remove it."
  RISKY=1
fi

# Check for database files
if git diff --cached --name-only | grep -qE "\.(db|sqlite)$|dump\.sql"; then
  echo "  STOP: A database or SQL dump is staged. Remove it."
  RISKY=1
fi

# Check for hardcoded secret patterns in staged content.
#
# Two deliberate choices here:
#   1. This file and .gitignore are excluded. They necessarily contain the
#      patterns being searched for, and a checker that flags itself on every
#      run trains you to ignore it.
#   2. The patterns require a credential-shaped VALUE, not just a prefix.
#      Matching bare "sk-" or "token=" fires on ordinary prose and code.
SCAN_PATHS=$(git diff --cached --name-only \
  | grep -vE "^(scripts/pre-push-check\.sh|\.gitignore)$")

if [ -n "$SCAN_PATHS" ]; then
  SECRET_RE='sk-ant-api[0-9]{2}[A-Za-z0-9_-]{20,}'
  SECRET_RE="$SECRET_RE|sk-proj-[A-Za-z0-9_-]{20,}"
  SECRET_RE="$SECRET_RE|sk-or-v1-[A-Za-z0-9]{32,}"
  SECRET_RE="$SECRET_RE|sk-[A-Za-z0-9]{32,}"
  SECRET_RE="$SECRET_RE|xai-[A-Za-z0-9]{40,}"
  SECRET_RE="$SECRET_RE|AKIA[0-9A-Z]{16}"
  SECRET_RE="$SECRET_RE|gh[pousr]_[A-Za-z0-9]{30,}"
  SECRET_RE="$SECRET_RE|github_pat_[A-Za-z0-9_]{40,}"
  SECRET_RE="$SECRET_RE|AIza[0-9A-Za-z_-]{35}"
  SECRET_RE="$SECRET_RE|xox[baprs]-[A-Za-z0-9-]{20,}"
  SECRET_RE="$SECRET_RE|-----BEGIN [A-Z ]*PRIVATE KEY-----"
  # An assignment whose value looks like a real secret rather than a placeholder.
  SECRET_RE="$SECRET_RE|(password|passwd|secret|api_?key|access_?token)[\"'\'']?[[:space:]]*[:=][[:space:]]*[\"'\'']?[A-Za-z0-9/+_-]{16,}"

  MATCHES=$(echo "$SCAN_PATHS" | tr '\n' '\0' \
    | xargs -0 git diff --cached -- 2>/dev/null \
    | grep -aiE "$SECRET_RE")

  if [ -n "$MATCHES" ]; then
    echo "  STOP: Possible hardcoded secret in staged changes:"
    echo "$MATCHES" | cut -c1-100 | sed 's/^/    /'
    echo "  Review with: git diff --cached"
    RISKY=1
  fi
fi

if [ $RISKY -eq 0 ]; then
  echo "  All clear. No obvious secrets detected in staged files."
  echo ""
  echo "  Final check (do this manually):"
  echo "  [ ] Review git diff --cached one more time"
  echo "  [ ] Confirm .gitignore is present and up to date"
  echo "  [ ] Ask: Would I be okay if a stranger saw every file I'm pushing?"
  echo ""
  echo "  Safe to push? Your call."
else
  echo ""
  echo "  Fix the issues above before pushing."
  echo "  Do NOT run git push until these are resolved."
fi

echo ""
echo "============================="
echo ""
