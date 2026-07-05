#!/usr/bin/env just --justfile

# Flexprice justfile — recipes consumed by the shared GitLab CI templates
# (infra/gitlab-ci-templates). Recipes delegate to the existing Makefile
# targets so there's a single source of truth for build/test commands.

set dotenv-load

coverage_profile_log := "./deploy/coverage.out"
coverage_profile_xml := "./deploy/coverage.xml"
coverage_profile_html := "./deploy/coverage.html"
coverage_threshold := "0"

export BASE_PROJ_PATH := `pwd`

# Static checks: go vet + gofmt.
check:
    go vet ./...
    @unformatted="$(gofmt -l .)"; \
    if [ -n "$unformatted" ]; then \
        echo "gofmt found unformatted files:"; \
        echo "$unformatted"; \
        exit 1; \
    fi

# Install build/test deps. Typst is needed because `make test` depends on it.
install-deps:
    go mod download
    make install-typst
    @if ! command -v gocover-cobertura >/dev/null 2>&1; then \
        go install github.com/boumenot/gocover-cobertura@latest; \
    fi

# Local test run (no coverage requirements) — mirrors `make test`.
test:
    make test

# CI coverage recipe. Must produce:
#   1. deploy/coverage.out  (raw Go coverage profile)
#   2. deploy/coverage.xml  (Cobertura, for MR line annotations)
#   3. stdout line matching  ^total:\s+\(statements\)\s+(\d+\.\d+)%
#      (feeds GitLab MR coverage widget)
test-with-coverage:
    mkdir -p deploy
    go test ./internal/... -coverprofile={{ coverage_profile_log }}
    go tool cover -func={{ coverage_profile_log }}
    gocover-cobertura < {{ coverage_profile_log }} > {{ coverage_profile_xml }}

# Start / stop hooks — thin delegates to docker-compose via the Makefile.
start *args='':
    make up

stop *args='':
    make down

integration-test:
    make test

# Ent + Postgres/ClickHouse migrations, mirroring `make migrate-ent`.
migrate:
    make migrate-ent
