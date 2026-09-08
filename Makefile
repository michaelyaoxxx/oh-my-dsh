.PHONY: setup dev deploy release link-plugins help

help: ## 显示可用目标
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-14s %s\n", $$1, $$2}'

setup: ## 一键搭建本地环境（submodule + 依赖 + harness 构建）
	bash scripts/setup.sh

link-plugins: ## 把 plugins/* 以 link 挂进 DSH profile dsh
	bash scripts/link-plugins.sh

dev: link-plugins ## 启动 DSH Web（$DSH_HOME=./.dsh，--no-open 可加）
	cd harness && DSH_HOME="$(CURDIR)/.dsh" pnpm dsh web --no-open

deploy: ## 部署到远程服务器（读 deploy/hosts）
	bash scripts/deploy-remote.sh

release: ## 校验 pin → 打 tag → push（发布快照）
	bash scripts/release.sh
