# prepare-executor.sh — 组件准备动作的**唯一实现**（被 setup.sh 与 remote-install.sh source）
#
# 为什么必须共用：`--plan prepare` 只统一了「准备哪些组件、各用什么模式」这份**决策数据**。
# 若两处各自实现一套 `case "$prepareMode"` 去决定**怎么准备**，漂移只会从
# 「选哪个字段」变成「怎么执行动作」——病没治好，换个地方发作。
# 此前两处循环逐行同构，正是 09-15 review 的 P0-1 的土壤。
#
# 本文件**不自己执行**，它是被 source 的库。调用方必须先定义两个钩子，
# 把**环境策略差异**注入进来（这正是唯一该有差异的地方）：
#
#   pe_install <rel> <frozen|nonfrozen>   # 安装依赖
#   pe_run_build <rel>                    # 执行构建
#
# 两者都应在失败时自行退出（调用方已有的 plugin_install / plugin_run 即符合）。

# shellcheck shell=bash

prepare_component() { # $1=rel(paths 形如 plugins/<name>)  $2=prepareMode  $3=frozen|nonfrozen
  local rel="$1" mode="$2" install_policy="$3"

  case "$mode" in
    none)
      echo "==> 跳过准备: ${rel}（prepareMode=none）"
      return 0
      ;;
    install-only|source-build|tracked-prebuilt) ;;
    *)
      echo "错误: ${rel} 的 prepareMode 取值非法: '${mode}'（允许 source-build / tracked-prebuilt / install-only / none）。这是组件目录与执行器不一致，拒绝继续。" >&2
      return 1
      ;;
  esac

  echo "==> 安装依赖: ${rel}（${install_policy}）"
  pe_install "$rel" "$install_policy" || return 1

  if [ "$mode" = "source-build" ]; then
    echo "==> 构建: ${rel}"
    pe_run_build "$rel" || return 1
  fi

  if [ "$mode" = "tracked-prebuilt" ]; then
    # 产物的**跟踪状态**由 check-components.mjs --require-materialized 校验；
    # 这里只声明动作，不重复实现校验逻辑（那会是第二份事实源）。
    echo "==> 跳过构建: ${rel}（prepareMode=tracked-prebuilt；入口跟踪状态由 check-components.mjs 校验）"
  fi

  return 0
}
