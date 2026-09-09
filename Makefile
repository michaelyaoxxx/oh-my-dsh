# recipes 用 bash（tee 管线需要 pipefail 才能把脚本退出码传回 make）
SHELL := /bin/bash
# make 目标输出落盘目录（gitignore）；每次 make 调用一个时间戳，同一调用内共用
LOG_DIR := log
LOG_STAMP := $(shell date +%Y-%m-%d-%H:%M:%S)

.PHONY: setup dev deploy release link-plugins help

help: ## 显示可用目标
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-14s %s\n", $$1, $$2}'

setup: ## 一键搭建本地环境（submodule + 依赖 + harness 构建）
	mkdir -p $(LOG_DIR)
	set -o pipefail; bash scripts/setup.sh 2>&1 | tee $(LOG_DIR)/setup-$(LOG_STAMP).log

link-plugins: ## 把 plugins/* 以 link 挂进 DSH profile dsh
	mkdir -p $(LOG_DIR)
	set -o pipefail; bash scripts/link-plugins.sh 2>&1 | tee $(LOG_DIR)/link-plugins-$(LOG_STAMP).log

dev: ## 启动 DSH Web（$DSH_HOME=./.dsh，--no-open 可加）
	mkdir -p $(LOG_DIR)
	# CI=true 原因与 scripts/setup.sh 相同：pnpm 11 跑脚本前默认校验依赖，脏时会先自动
	# pnpm install，重装会触发 harness 根 postinstall（install-lefthook.mjs），在 submodule
	# 环境必然失败；export CI=true 使其跳过 hooks 安装（与 GitHub Actions 全局 CI=true 一致）。
	# `dsh web` 别名 boot 官方模板 web profile，挂载目标是 dsh，故显式 `--profile dsh`
	set -o pipefail; { bash scripts/link-plugins.sh && cd harness && DSH_HOME="$(CURDIR)/.dsh" CI=true pnpm dsh --profile dsh --no-open; } 2>&1 | tee $(LOG_DIR)/dev-$(LOG_STAMP).log

deploy: ## 部署到远程服务器（读 deploy/hosts）
	mkdir -p $(LOG_DIR)
	set -o pipefail; bash scripts/deploy-remote.sh 2>&1 | tee $(LOG_DIR)/deploy-$(LOG_STAMP).log

release: ## 校验 pin → 打 tag → push（发布快照）
	mkdir -p $(LOG_DIR)
	set -o pipefail; bash scripts/release.sh $(VERSION) 2>&1 | tee $(LOG_DIR)/release-$(LOG_STAMP).log
