.PHONY: up down test lint load smoke dr tf-test logs

up:            ## start app + Postgres + Prometheus + Grafana + Loki
	docker compose up -d --build
	@until curl -sf localhost:8000/readyz >/dev/null; do sleep 1; done
	@echo "app http://localhost:8000/docs  grafana http://localhost:3000  prometheus http://localhost:9090"

down:
	docker compose down -v

test:          ## needs Postgres: `docker compose up -d --wait postgres`
	pytest -v

lint:
	ruff check . && ruff format --check .
	terraform fmt -check -recursive infra/terraform
	helm lint deploy/helm/surge-links -f deploy/helm/surge-links/ci/test-values.yaml

smoke:
	SCENARIO=smoke docker compose --profile load run --rm -e SCENARIO=smoke k6

load:          ## 10x spike, writes load/results/summary.json
	docker compose --profile load run --rm k6

dr:            ## backup -> drop -> restore -> verify -> RTO
	./scripts/dr-drill.sh

tf-test:
	cd infra/terraform/modules/service-env && terraform init -input=false && terraform test

logs:
	docker compose logs -f app
