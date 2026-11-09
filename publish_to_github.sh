#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${1:-https://github.com/GatechLW/meta-glasses-gemini-live-copilot.git}"

if [[ ! -f "README.md" || ! -d "iPhoneGeminiVideoLab" ]]; then
  echo "Error: run this script from the extracted project root (the folder containing README.md and iPhoneGeminiVideoLab/)." >&2
  exit 1
fi

if ! command -v git >/dev/null 2>&1; then
  echo "Error: Git is required. Install Xcode Command Line Tools with: xcode-select --install" >&2
  exit 1
fi

if [[ ! -d .git ]]; then
  git init
fi

git branch -M main
git add .

if ! git diff --cached --quiet; then
  git commit -m "Initial release: Meta Glasses Gemini Live Copilot"
else
  echo "No staged changes; keeping the existing commit."
fi

if git remote get-url origin >/dev/null 2>&1; then
  git remote set-url origin "$REPO_URL"
else
  git remote add origin "$REPO_URL"
fi

echo "Pushing main to $REPO_URL"
git push -u origin main

echo "Published successfully: https://github.com/GatechLW/meta-glasses-gemini-live-copilot"
