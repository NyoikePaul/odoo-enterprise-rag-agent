.PHONY: setup up down logs test clean

setup:
chmod +x scripts/setup.sh && ./scripts/setup.sh

up:
docker-compose up -d --build

down:
docker-compose down

logs:
docker-compose logs -f api

test:
pytest tests/ --cov=src

clean:
find . -type d -name "__pycache__" -exec rm -rf {} +
rm -rf .pytest_cache .coverage
