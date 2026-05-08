.PHONY: up down logs build sh test fmt lint

up:
	docker compose up -d --build

down:
	docker compose down

logs:
	docker compose logs -f --tail=200

build:
	docker compose build

sh:
	docker compose exec backend bash

test:
	docker compose exec backend pytest -q

fmt:
	docker compose exec backend ruff format .

lint:
	docker compose exec backend ruff check .
