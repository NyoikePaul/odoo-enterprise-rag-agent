#!/usr/bin/env bash
set -e

echo "🛠️ Creating Virtual Environment..."
python3 -m venv venv
source venv/bin/activate

echo "🚀 Installing Core Dependencies..."
pip install --upgrade pip
pip install -r requirements.txt
pip install -r requirements-dev.txt

echo "✅ Setup Complete. Run 'source venv/bin/activate' to begin."
