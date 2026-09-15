# recipes 用 bash（tee 管线需要 pipefail 才能把脚本退出码传回 make）
SHELL := /bin/bash
# make 目标输出落盘目录（gitignore）；每次 make 调用一个标识，同一调用内共用。
# 用 **UTC + PID**：原先的本地时间戳精确到秒，同一秒内并发两个 make 会写同一个文件，
# 互相覆盖（`make dev` 与 `make link-plugins` 同开就会踩到）。PID 消除碰撞；
# UTC 消除跨时区/跨机器的可比性问题。
LOG_DIR := log
LOG_STAMP := $(shell printf '%s-%s' "$$(date -u +%Y%m%dT%H%M%SZ)" "$$$$")

# release 的版本号白名单：只允许字母/数字/点/下划线/连字符，且必须非空。
# ⚠️ 这是**纵深防御，不是权威校验**——Make 的变量替换是纯文本的，任何在 recipe 里
# 写 "$(VERSION)" 的地方都存在注入面（含引号/反引号/`$(`）。权威校验在
# scripts/release.sh 里（它必须在任何入口下都成立）；这里拦的是最常见的手滑。
#
# ⚠️ 用 `grep -x`（整行匹配）而不是正则的 `^…$` 锚点：**Make 会把值末尾的 `$` 吃掉**
#    （`$` + 行尾被当作变量引用）。实测用 `^…$` 时展开成 `'^…*'`，**丢了结尾锚点**，
#    于是 `v1.0;x` 这种串照样通过——守卫形同虚设。改用 -x 后可彻底避开 `$`。
VERSION_RE := v?[0-9A-Za-z][0-9A-Za-z._-]*

.PHONY: setup dev dev-tui deploy release link-plugins help

help: ## 显示可用目标
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-14s %s\n", $$1, $$2}'

setup: ## 一键搭建本地环境（submodule + 依赖 + harness 构建）
	mkdir -p $(LOG_DIR)
	set -o pipefail; bash scripts/setup.sh 2>&1 | tee $(LOG_DIR)/setup-$(LOG_STAMP).log

link-plugins: ## 把 plugins/* 以 link 挂进 DSH profile dsh
	mkdir -p $(LOG_DIR)
	set -o pipefail; bash scripts/link-plugins.sh 2>&1 | tee $(LOG_DIR)/link-plugins-$(LOG_STAMP).log

dev: ## 启动 DSH Web（$DSH_HOME=./.dsh；固定 --no-open，不自动开浏览器）
	mkdir -p $(LOG_DIR)
	# CI=true 原因与 scripts/setup.sh 相同：pnpm 11 跑脚本前默认校验依赖，脏时会先自动
	# pnpm install，重装会触发 harness 根 postinstall（install-lefthook.mjs），在 submodule
	# 环境必然失败；export CI=true 使其跳过 hooks 安装（与 GitHub Actions 全局 CI=true 一致）。
	# `dsh web` 别名 boot 官方模板 web profile，挂载目标是 dsh，故显式 `--profile dsh`
	set -o pipefail; { bash scripts/link-plugins.sh && cd harness && DSH_HOME="$(CURDIR)/.dsh" CI=true pnpm dsh --profile dsh --no-open; } 2>&1 | tee $(LOG_DIR)/dev-$(LOG_STAMP).log

dev-tui: ## 启动 DSH TUI（独立 profile tui；终端前端，需真 TTY，故不落盘日志）
	# 不走 tee：TUI 插件有 TTY 校验，管道会让 stdout 不是 TTY 而启动失败。
	bash scripts/link-tui.sh
	cd harness && DSH_HOME="$(CURDIR)/.dsh" CI=true pnpm dsh --profile tui

deploy: ## 部署到远程服务器（读 deploy/hosts）；⚠️ 非生产，从未端到端跑通过
	mkdir -p $(LOG_DIR)
	set -o pipefail; bash scripts/deploy-remote.sh 2>&1 | tee $(LOG_DIR)/deploy-$(LOG_STAMP).log

release: ## 校验 pin → 打 tag → push（发布快照）；需 VERSION=v0.1.0
	@# ⚠️ 全程用 shell 的 $$VERSION（make 命令行变量**会导出到 recipe 环境**，已实测），
	@#    **绝不写 $(VERSION)** —— Make 会把值**原样插进 recipe 文本**再交给 shell 解析。
	@#    实测过两种伤害：不加引号会被分词（`v1.0; rm -rf …` 直接执行后面的命令）；
	@#    加了引号也没用——值里的 `$$(…)` 会被 Make 转义成 shell 的 `$(…)`，
	@#    在**双引号**里照样当命令替换执行（实测 `v1.0$$(whoami)` 真的跑了 whoami）。
	@#    走环境变量则值根本不进入文本，shell 只当普通变量展开，不再二次解析。
	@printf '%s' "$$VERSION" | grep -qxE '$(VERSION_RE)' || { \
	  echo "错误: VERSION 缺失或含非法字符：'$$VERSION'" >&2; \
	  echo "  只允许字母/数字/点/下划线/连字符，如 v0.1.0。用法: make release VERSION=v0.1.0" >&2; \
	  exit 1; }
	mkdir -p $(LOG_DIR)
	set -o pipefail; bash scripts/release.sh "$$VERSION" 2>&1 | tee $(LOG_DIR)/release-$(LOG_STAMP).log
