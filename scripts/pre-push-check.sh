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

# Check for hardcoded secret patterns in staged content
if git diff --cached | grep -qE "(sk-|AKIA|api_key|secret_key|password=|token=)"; then
  echo "  WARNING: Possible hardcoded secret detected in staged changes."
  echo "  Review with: git diff --cached"
  RISKY=1
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
