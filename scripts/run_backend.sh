#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../backend"
if [ ! -d .venv ]; then
  python3 -m venv .venv
fi
source .venv/bin/activate
pip install -r requirements.txt
if [ -f .env ]; then
  uvicorn main:app --reload --env-file .env
else
  uvicorn main:app --reload
fi
