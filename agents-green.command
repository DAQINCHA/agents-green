#!/bin/bash
# agents-green.command — ~/.agents 工具链唯一入口
#
# 动作：
#   双击运行 / ./agents-green.command                   交互菜单
#   ./agents-green.command install [--force] [all|claude|codex|pi|codebuddy]   安装（默认全部）
#   ./agents-green.command setup                        迁移后修复 / 重建命令入口
#   ./agents-green.command update [1-5|all|check|runtime]   版本更新
#   ./agents-green.command uninstall [--dry-run|--yes|--no-backup] [all|claude|codex|pi|codebuddy]
#       卸载全部只清理脚本生成的目录与文件，保留 AGENTS_HOME 本身和其他文件
#       默认备份写到 AGENTS_HOME/.backups，不再写到 HOME
#
# 环境变量：
#   AGENTS_HOME   安装根目录（默认 ~/.agents；可设为任意可写目录的绝对路径）
#   NODE_VER / NPM_VER / CLAUDE_VER / CODEX_VER / PI_VER / CODEBUDDY_VER   指定版本，默认自动取最新
#   SKIP_AGENTS=1 install 只装 Node/npm 运行时
#   SKIP_LINKS=1  install 不建 /opt/homebrew/bin 入口
#   NO_NODE_LINK=1 setup 不暴露 node/npm/npx（四个 CLI 仍可用自带 Node）
#   AGENTS_BIN_DIR  指定入口目录（默认自动挑 /opt/homebrew/bin 等，仅测试用）
#
# 只写 AGENTS_HOME 内部与入口目录（/opt/homebrew/bin、/usr/local/bin 或 ~/.local/bin），不碰系统 node/npm。

# 注意：上面那个空行是 usage() 的结束标记，删掉或在其上方再加空行都会让 --help 截断。
set -uo pipefail
# 变量紧贴中文时必须写 ${var}：bash 3.2 在 C/POSIX locale 下会把中文字节的首字节
# 并进变量名，导致 $var， 被当成未定义变量（表现为吞字或 unbound variable）。

SELF_DIR="$(cd "$(dirname "$0")" && pwd -P)"
SELF_FILE="$SELF_DIR/$(basename "$0")"
while [ -L "$SELF_FILE" ]; do
  _link="$(readlink "$SELF_FILE")"
  case "$_link" in
    /*) SELF_FILE="$_link" ;;
    *)  SELF_FILE="$(cd "$(dirname "$SELF_FILE")" && pwd -P)/$_link" ;;
  esac
done
SELF_DIR="$(cd "$(dirname "$SELF_FILE")" && pwd -P)"
unset _link
AGENTS_HOME_SET="${AGENTS_HOME:+1}"
AGENTS_HOME="${AGENTS_HOME:-$HOME/.agents}"
TMP=""
ACTION="menu"
FORCE=0
CONFIRMED=0
DRY=0
DO_BACKUP=1
ASSUME_YES=0
STATUS_FRESH=""
PRESENT_COMPONENTS=""
INTERACTIVE=0
[ -t 0 ] && INTERACTIVE=1

if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_CYAN=$'\033[36m'; C_YELLOW=$'\033[33m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_GREEN=""; C_RED=""; C_CYAN=""; C_YELLOW=""
fi

step() { printf "\n%s▸ %s%s\n" "$C_BOLD" "$1" "$C_RESET"; }
ok()   { printf "  %s✓%s %s\n" "$C_GREEN" "$C_RESET" "$1"; }
warn() { printf "  %s!%s %s\n" "$C_YELLOW" "$C_RESET" "$1"; }
bad()  { printf "  %s✗%s %s\n" "$C_RED" "$C_RESET" "$1"; }
die()  { bad "$1"; printf "\n%s操作中止。%s\n" "$C_RED" "$C_RESET"; exit 1; }

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }

cleanup() {
  [ -n "$TMP" ] || return 0
  if rm -rf "$TMP" 2>/dev/null; then
    TMP=""
  else
    printf "\n%s! 临时目录未能自动清理：%s%s\n" "$C_YELLOW" "$TMP" "$C_RESET"
    printf "  %s可手动删除：rm -rf %s%s\n" "$C_DIM" "$TMP" "$C_RESET"
    TMP=""
  fi
}
pause_on_exit() {
  cleanup
  if [ "$INTERACTIVE" = "1" ]; then
    printf "\n%s按回车确认退出脚本...%s" "$C_DIM" "$C_RESET"
    read -r _ 2>/dev/null || true
  fi
}
trap pause_on_exit EXIT

set_home_paths() {
  NODE="$AGENTS_HOME/.dependencies/node/bin/node"
  NPM_CLI="$AGENTS_HOME/.dependencies/npm/bin/npm-cli.js"
}

fetch_file() {
  local url="$1" out="$2"
  if [ -t 2 ]; then
    curl -fL --progress-bar -o "$out" "$url"
  else
    curl -fsSL -o "$out" "$url"
  fi
}

# $1 传空串时解析失败返回空（状态表用它区分"未知"），不传则回落默认版本
resolve_node_ver() {
  local v fb="${1-24.22.1}"
  v="$(curl -fsSL --max-time 20 https://nodejs.org/dist/index.json 2>/dev/null \
        | tr '{' '\n' | grep '"lts":"' | head -1 \
        | sed -n 's/.*"version":"v\([0-9][^"]*\)".*/\1/p')"
  printf '%s' "${v:-$fb}"
}

resolve_npm_ver() {
  local v fb="${1-12.2.1}"
  v="$(curl -fsSL --max-time 20 https://registry.npmjs.org/npm/latest 2>/dev/null \
        | sed -n 's/.*"version":"\([0-9][^"]*\)".*/\1/p' | head -1)"
  printf '%s' "${v:-$fb}"
}

pick_bin_dir() {
  local d
  # 测试/特殊部署用：显式指定入口目录，跳过自动探测
  if [ -n "${AGENTS_BIN_DIR:-}" ]; then
    mkdir -p "$AGENTS_BIN_DIR" 2>/dev/null || return 1
    printf '%s' "$AGENTS_BIN_DIR"
    return 0
  fi
  for d in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin"; do
    [ -d "$d" ] || continue
    [ -w "$d" ] && { printf '%s' "$d"; return 0; }
  done
  mkdir -p "$HOME/.local/bin" 2>/dev/null || return 1
  printf '%s' "$HOME/.local/bin"
}

# 把已存在的入口挪成 .bak；已有同名 .bak 时追加时间戳，绝不覆盖上一次的备份。
# 成功时把备份后的路径打到 stdout（调用方用 $( ) 接），失败返回 1。
backup_entry() {
  local p="$1" bak
  bak="$p.bak"
  [ -e "$bak" ] && bak="$p.bak.$(date +%Y%m%d-%H%M%S)"
  mv "$p" "$bak" 2>/dev/null || { bad "无法备份 $p（权限不足？）"; return 1; }
  printf '%s' "$bak"
}

# 原子写一个 /bin/sh wrapper：内容从 stdin 读，先写 .tmp 再 mv，任何一步失败都返回 1。
# 用法：printf 'exec "%%s" "$@"\n' "$path" | write_shim /opt/homebrew/bin/foo
write_shim() {
  local path="$1" tmp
  tmp="$path.tmp.$$"
  {
    printf '#!/bin/sh\n'
    printf '# agents-green: %s -> %s\n' "$(basename "$path")" "$AGENTS_HOME"
    cat
  } > "$tmp" 2>/dev/null || { bad "写入 $tmp 失败（目录不可写？）"; rm -f "$tmp"; return 1; }
  chmod +x "$tmp" 2>/dev/null || { bad "无法设置可执行位：$path"; rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$path" 2>/dev/null || { bad "替换 $path 失败"; rm -f "$tmp"; return 1; }
}

# 不依赖 realpath 的绝对路径规范化；目标不存在时也能处理 . 和 ..。
normalize_agents_path() {
  local path="$1" base="$2" rest part result=""
  local -a parts=() stack=()
  case "$path" in
    /*) rest="${path#/}" ;;
    *)
      base="$(cd "$base" 2>/dev/null && pwd -P)" || return 1
      rest="${base#/}/$path"
      ;;
  esac
  IFS='/' read -r -a parts <<< "$rest"
  for part in ${parts[@]+"${parts[@]}"}; do
    case "$part" in
      ""|.) ;;
      ..)
        [ "${#stack[@]}" -eq 0 ] || unset "stack[$((${#stack[@]} - 1))]"
        ;;
      *) stack+=("$part") ;;
    esac
  done
  for part in ${stack[@]+"${stack[@]}"}; do result="$result/$part"; done
  printf '%s' "${result:-/}"
}

# 判断软链目标是否真正位于 AGENTS_HOME 内，避免 .agents-old 等同前缀目录误判。
is_own_symlink_target() {
  local link="$1" tgt norm home
  [ -n "${AGENTS_HOME:-}" ] || return 1
  tgt="$(readlink "$link" 2>/dev/null)" || return 1
  [ -n "$tgt" ] || return 1
  norm="$(normalize_agents_path "$tgt" "$(dirname "$link")")" || return 1
  home="$(normalize_agents_path "${AGENTS_HOME%/}" "/")" || return 1
  if [ "$home" = "/" ]; then
    [ "${norm#/}" != "$norm" ]
    return
  fi
  case "$norm" in
    "$home"|"$home"/*) return 0 ;;
  esac
  return 1
}

# 一个组件在入口目录里要暴露的命令名。多数组件只有一个（与目录名同名），
# 但 CodeBuddy 的包同时声明了 codebuddy / cbc / codebuddy-code / cbc-prewarm / codebuddy-lowmem，
# 只转发 codebuddy 会让 cbc 这类短名在 PATH 上找不到。
# 安装、卸载、校验都从这里取，避免各处再写死一份清单。
entry_names() {
  case "$1" in
    codebuddy) printf '%s\n' codebuddy cbc ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# 入口的唯一模板来源；install 与 setup 共用，避免两份代码漂移
# $1=bin 目录  $2=是否暴露 node/npm/npx（1/0）  $3+=要写入入口的组件（空 = claude codex pi codebuddy 全部）
# 返回非 0 表示有入口没写成功，调用方必须检查
write_entries() {
  local bin="$1" with_node="$2" existing f tgt bak components c
  shift 2
  components="${*:-claude codex pi codebuddy}"

  # 清场：只删自己写过的入口；外来的一律备份后让位
  # 按 entry_names 展开，一个组件可能对应多个入口名（如 CodeBuddy 的 codebuddy / cbc）
  for f in $(for c in $components; do entry_names "$c"; done); do
    if [ -L "$bin/$f" ]; then
      tgt="$(readlink "$bin/$f" 2>/dev/null || true)"
      if is_own_symlink_target "$bin/$f"; then
        rm -f "$bin/$f" || { bad "无法删除旧入口 $bin/$f"; return 1; }
      else
        bak="$(backup_entry "$bin/$f")" || return 1
        warn "原有 $f 软链（${tgt}）已备份为 $(basename "$bak")"
      fi
    elif [ -e "$bin/$f" ] && ! grep -qs "agents-green" "$bin/$f" 2>/dev/null; then
      bak="$(backup_entry "$bin/$f")" || return 1
      warn "原有 $f 已备份为 $(basename "$bak")"
    fi
  done

  # 写入口（内容从 printf 走管道进 write_shim，避免 heredoc 的转义地狱）
  for f in $components; do
    case "$f" in
      claude)
        printf 'exec "%s/claude/node_modules/.bin/claude" "$@"\n' "$AGENTS_HOME" \
          | write_shim "$bin/claude" || return 1 ;;
      codex)
        printf 'exec "%s" "%s/codex/node_modules/.bin/codex" "$@"\n' "$NODE" "$AGENTS_HOME" \
          | write_shim "$bin/codex" || return 1 ;;
      pi)
        printf 'exec "%s" "%s/pi/node_modules/.bin/pi" "$@"\n' "$NODE" "$AGENTS_HOME" \
          | write_shim "$bin/pi" || return 1 ;;
      codebuddy)
        # 它自带自动更新，会绕过本脚本的更新流程；这里固定关掉，版本统一由「更新」管。
        # 一个包声明多个命令名，全部指向同一个 bin，且都要带上关自动更新的那行。
        for f in $(entry_names codebuddy); do
          printf 'export DISABLE_AUTOUPDATER=1\nexec "%s" "%s/codebuddy/node_modules/.bin/%s" "$@"\n' \
            "$NODE" "$AGENTS_HOME" "$f" | write_shim "$bin/$f" || return 1
        done ;;
      *)
        warn "未知组件：$f，跳过" ;;
    esac
  done
  ok "已写入入口：$components"

  if [ "$with_node" != "1" ]; then
    warn "按调用方要求跳过 node / npm / npx（四个 CLI 仍用自带 Node）"
    return 0
  fi

  if [ -e "$bin/node" ] && [ ! -L "$bin/node" ]; then
    warn "已存在其他 node（$bin/node），保留系统版本，跳过 node / npm / npx"
    return 0
  fi

  existing="$(readlink "$bin/node" 2>/dev/null || true)"
  if [ "$existing" = "$NODE" ]; then
    ok "node 入口已存在且指向本目录"
  elif [ -n "$existing" ] && [ -e "$bin/node" ]; then
    warn "$bin/node 软链指向别处（${existing}），不覆盖；如需接管请手动处理"
    return 0
  else
    # 不存在，或是指向已消失目标的失效软链 → 重建
    [ -n "$existing" ] && warn "$bin/node 是失效软链（${existing}），重建"
    ln -sfn "$NODE" "$bin/node" 2>/dev/null || cp "$NODE" "$bin/node" 2>/dev/null \
      || { bad "无法创建 $bin/node 入口"; return 1; }
  fi

  local skip_runtime=0
  for f in npm npx; do
    if [ -L "$bin/$f" ]; then
      tgt="$(readlink "$bin/$f" 2>/dev/null || true)"
      if is_own_symlink_target "$bin/$f"; then
        rm -f "$bin/$f"
      else
        warn "$bin/$f 是其他工具的软链（${tgt}），保留不动"
        skip_runtime=1
      fi
    elif [ -e "$bin/$f" ] && ! grep -qs "agents-green" "$bin/$f" 2>/dev/null; then
      bak="$(backup_entry "$bin/$f")" || return 1
      warn "原有 $f 已备份为 $(basename "$bak")"
    fi
  done
  if [ "$skip_runtime" = "1" ]; then
    warn "已跳过 node / npm / npx 入口（不接管系统已有工具）"
    return 0
  fi

  printf 'export npm_config_cache="%s/.dependencies/.npm-cache"\nexec "%s" "%s" "$@"\n' \
    "$AGENTS_HOME" "$NODE" "$NPM_CLI" | write_shim "$bin/npm" || return 1
  printf 'export npm_config_cache="%s/.dependencies/.npm-cache"\nexec "%s" "%s/.dependencies/npm/bin/npx-cli.js" "$@"\n' \
    "$AGENTS_HOME" "$NODE" "$AGENTS_HOME" | write_shim "$bin/npx" || return 1
  ok "已写入 node / npm / npx（npm 缓存锁定在 .dependencies 内）"
}

# $1=bin 目录（空 = 未建入口，走绝对路径）  $2=node 是否应出现在 PATH（1/0）  $3+=要实测的组件（可空）
verify_commands() {
  local bin_dir="$1" node_on_path="$2" fail=0 v c rc
  local vpath="${bin_dir:-$(dirname "$NODE")}:/usr/bin:/bin:/usr/sbin:/sbin"
  shift 2
  step "实测命令（模拟无 node 的干净环境）"
  if [ "$node_on_path" = "1" ] && [ -n "$bin_dir" ]; then
    v="$(env -i HOME="$HOME" PATH="$vpath" node --version 2>&1)" \
      && ok "node：$v" || { bad "node 无法运行：$v"; fail=1; }
  else
    v="$("$NODE" --version 2>&1)" \
      && ok "node：$v" || { bad "便携 node 无法运行：$v"; fail=1; }
  fi
  for c in "$@"; do
    v=""
    rc=0
    if [ -n "$bin_dir" ]; then
      v="$(env -i HOME="$HOME" PATH="$vpath" "$c" --version 2>&1)" || rc=$?
    else
      case "$c" in
        claude) v="$("$AGENTS_HOME/claude/node_modules/.bin/claude" --version 2>&1)" || rc=$? ;;
        codex)  v="$("$NODE" "$AGENTS_HOME/codex/node_modules/.bin/codex" --version 2>&1)" || rc=$? ;;
        pi)     v="$("$NODE" "$AGENTS_HOME/pi/node_modules/.bin/pi" --version 2>&1)" || rc=$? ;;
        codebuddy) v="$("$NODE" "$AGENTS_HOME/codebuddy/node_modules/.bin/codebuddy" --version 2>&1)" || rc=$? ;;
        cbc)    v="$("$NODE" "$AGENTS_HOME/codebuddy/node_modules/.bin/cbc" --version 2>&1)" || rc=$? ;;
        *)      continue ;;
      esac
    fi
    v="$(printf '%s' "$v" | head -1)"
    if [ "$rc" -eq 0 ] && [ -n "$v" ]; then
      ok "${c}：$v"
    else
      bad "$c 无法运行${v:+：$v}"
      fail=1
    fi
  done
  return "$fail"
}

# 安装/更新完成后刷新状态：刚装的就是最新版，不必再问 registry（省 2-15 秒）
refresh_after_install() {
  local k
  for k in "$@"; do
    case "$k" in
      claude) CUR_CLAUDE="$(current_version claude)"; LATEST_CLAUDE="$CUR_CLAUDE" ;;
      codex)  CUR_CODEX="$(current_version codex)";   LATEST_CODEX="$CUR_CODEX" ;;
      pi)     CUR_PI="$(current_version pi)";         LATEST_PI="$CUR_PI" ;;
      codebuddy) CUR_CODEBUDDY="$(current_version codebuddy)"; LATEST_CODEBUDDY="$CUR_CODEBUDDY" ;;
    esac
  done
  CUR_NODE="$([ -x "$NODE" ] && "$NODE" -v 2>/dev/null)"
  CUR_NODE="${CUR_NODE#v}"
  CUR_NPM="$([ -x "$NODE" ] && [ -f "$NPM_CLI" ] && "$NODE" "$NPM_CLI" -v 2>/dev/null)"
  STATUS_FRESH=1
}

# 菜单与更新界面共用的状态数据：填 CUR_* / LATEST_* 八个全局变量
# 运行时可用时并行查最新版（约 1-2 秒）；否则离线降级，LATEST_* 置空
refresh_status() {
  if [ -x "$NODE" ] && [ -f "$NPM_CLI" ]; then
    printf "%s正在获取版本信息...%s\n" "$C_DIM" "$C_RESET"
    export npm_config_cache="$AGENTS_HOME/.dependencies/.npm-cache"
    export npm_config_update_notifier=false
    export npm_config_fetch_timeout=8000
    export npm_config_fetch_retries=1
    check_all
  else
    CUR_CLAUDE="$(current_version claude)"
    CUR_CODEX="$(current_version codex)"
    CUR_PI="$(current_version pi)"
    CUR_CODEBUDDY="$(current_version codebuddy)"
    LATEST_CLAUDE=""; LATEST_CODEX=""; LATEST_PI=""; LATEST_CODEBUDDY=""
  fi
  CUR_NODE="$([ -x "$NODE" ] && "$NODE" -v 2>/dev/null)"
  CUR_NODE="${CUR_NODE#v}"
  CUR_NPM="$([ -x "$NODE" ] && [ -f "$NPM_CLI" ] && "$NODE" "$NPM_CLI" -v 2>/dev/null)"
  LATEST_NODE="$(resolve_node_ver "")"
  LATEST_NPM="$(resolve_npm_ver "")"
  STATUS_FRESH=1
}

# 菜单共用：本会话已查过版本则跳过（首页查过子菜单秒开），否则查一次
ensure_status() {
  [ -n "$STATUS_FRESH" ] && return 0
  refresh_status
}

# ---------- install ----------
write_pkg_json() {
  local dir="$1" name="$2" allow="$3"
  if [ -n "$allow" ]; then
    cat > "$AGENTS_HOME/$dir/package.json" <<EOF
{
  "name": "$name",
  "version": "0.0.0",
  "private": true,
  "allowScripts": $allow
}
EOF
  else
    cat > "$AGENTS_HOME/$dir/package.json" <<EOF
{
  "name": "$name",
  "version": "0.0.0",
  "private": true
}
EOF
  fi
}

# 已安装时的覆盖确认（仅在交互环境调用）。返回 0 = 同意覆盖
confirm_overwrite() {
  local ans
  printf "\n  %s%s 已存在，覆盖重装？[y/n] %s" "$C_YELLOW" "$1" "$C_RESET"
  read -r ans || { printf "\n"; return 1; }
  case "$(printf '%s' "$ans" | tr -d '[:space:]')" in
    y|Y|yes|YES|Yes) printf "\n"; return 0 ;;
    *) printf "\n  %s已取消，未做任何改动。%s\n" "$C_DIM" "$C_RESET"; return 1 ;;
  esac
}

install_agent() {
  local dir="$1" pkg="$2" ver="$3" label="$4"
  printf "\n  %s→ %s %s%s\n" "$C_CYAN" "$label" "$ver" "$C_RESET"
  "$NODE" "$NPM_CLI" install --prefix "$AGENTS_HOME/$dir" "$pkg@$ver" \
    --no-audit --no-fund --loglevel=warn 2>&1 | tail -4
  [ "${PIPESTATUS[0]}" -eq 0 ] || { bad "$label 安装失败"; return 1; }
  ok "$label 完成"
}

# 外层包装：负责清理临时目录，并把失败变成返回值而不是退出进程
install_action() {
  local rc=0
  _install_action "$@" || rc=$?
  cleanup
  return "$rc"
}

_install_action() {
  local key="${1:-all}"
  local NODE_VER="${NODE_VER:-}" NPM_VER="${NPM_VER:-}"
  local CLAUDE_VER="${CLAUDE_VER:-latest}" CODEX_VER="${CODEX_VER:-latest}" PI_VER="${PI_VER:-latest}"
  local CODEBUDDY_VER="${CODEBUDDY_VER:-latest}"
  local SKIP_AGENTS="${SKIP_AGENTS:-0}" SKIP_LINKS="${SKIP_LINKS:-0}"
  local BIN_DIR="" fail=0 v check_list="" label
  set_home_paths
  # npm 生命周期脚本（例如 Claude 的 postinstall: node install.cjs）靠 PATH 找 node；
  # 安装阶段还没有写入口，必须先把便携 Node 放进 PATH，否则全新机器会报 node: command not found。
  export PATH="$(dirname "$NODE"):$PATH"

  case "$key" in
    all|claude|codex|pi|codebuddy) ;;
    *) bad "未知组件：${key}（可用 all / claude / codex / pi / codebuddy）"; return 1 ;;
  esac

  step "检查环境"
  [ "$(uname -m)" = "arm64" ] || { bad "只支持 Apple Silicon（当前 $(uname -m)）；Intel 机器需自行编译"; return 1; }
  ok "架构 arm64"
  command -v curl >/dev/null || { bad "缺少 curl"; return 1; }
  command -v tar  >/dev/null || { bad "缺少 tar"; return 1; }
  ok "curl / tar 可用"
  [ -n "${HOME:-}" ] || { bad "HOME 未设置"; return 1; }
  printf "  %s安装目标：%s%s\n" "$C_DIM" "$AGENTS_HOME" "$C_RESET"

  if [ "$key" = "all" ]; then
    if [ -d "$AGENTS_HOME/claude/node_modules" ] || [ -d "$AGENTS_HOME/codex/node_modules" ] \
      || [ -d "$AGENTS_HOME/pi/node_modules" ] || [ -d "$AGENTS_HOME/codebuddy/node_modules" ]; then
      if [ "$FORCE" != "1" ]; then
        if [ "$INTERACTIVE" = "1" ]; then
          confirm_overwrite "四个 CLI" || return 1
          FORCE=1; CONFIRMED=1
        else
          warn "检测到已有安装。如需覆盖请加 --force，或直接 setup 修复入口"
          return 1
        fi
      fi
      warn "覆盖：将替换现有目录"
    fi
  else
    label="$(display_name "$key")"
    if [ -d "$AGENTS_HOME/$key/node_modules" ]; then
      if [ "$FORCE" != "1" ]; then
        if [ "$INTERACTIVE" = "1" ]; then
          local desc="$label" cur_ver
          cur_ver="$(current_version "$key" 2>/dev/null)"
          [ -n "$cur_ver" ] && desc="${label}（${cur_ver}）"
          confirm_overwrite "$desc" || return 1
          FORCE=1; CONFIRMED=1
        else
          warn "$label 已安装（$(current_version "$key" 2>/dev/null)）。如需覆盖请用：./agents-green.command install --force $key"
          return 1
        fi
      fi
      warn "覆盖：将替换现有 $label"
    fi
  fi

  printf "  %s测试 registry 连通性...%s\n" "$C_DIM" "$C_RESET"
  curl -fsI -o /dev/null --max-time 10 https://registry.npmjs.org/ 2>/dev/null \
    || { bad "无法访问 registry.npmjs.org，检查网络或代理"; return 1; }
  curl -fsI -o /dev/null --max-time 10 https://nodejs.org/dist/ 2>/dev/null \
    || { bad "无法访问 nodejs.org"; return 1; }
  ok "网络正常"

  step "创建目录结构"
  if [ "$key" = "all" ]; then
    mkdir -p "$AGENTS_HOME"/{claude,codex,pi,codebuddy}
  else
    mkdir -p "$AGENTS_HOME/$key"
  fi
  mkdir -p "$AGENTS_HOME/.dependencies"/{node/bin,npm}
  mkdir -p "$AGENTS_HOME/.dependencies/.npm-cache"
  TMP="$AGENTS_HOME/.install-tmp"
  rm -rf "$TMP"; mkdir -p "$TMP"
  ok "$AGENTS_HOME/{claude,codex,pi,codebuddy,.dependencies}"

  local refresh_runtime=0
  # 菜单里确认覆盖不重下运行时；只有命令行显式 --force all 才刷新 Node/npm
  [ "$FORCE" = "1" ] && [ "$key" = "all" ] && [ "$CONFIRMED" != "1" ] && refresh_runtime=1
  if [ "$refresh_runtime" != "1" ] && [ -x "$NODE" ] && [ -f "$NPM_CLI" ]; then
    step "便携运行时"
    ok "Node $("$NODE" -v) / npm $("$NODE" "$NPM_CLI" -v) 已存在，跳过下载"
    export npm_config_cache="$AGENTS_HOME/.dependencies/.npm-cache"
  else
    if [ -z "$NODE_VER" ]; then
      step "解析最新 Node LTS"
      NODE_VER="$(resolve_node_ver)"
      ok "选定 v$NODE_VER"
    fi
    step "安装便携 Node v$NODE_VER"
    printf "  %s下载中（约 50 MB）...%s\n" "$C_DIM" "$C_RESET"
    fetch_file "https://nodejs.org/dist/v$NODE_VER/node-v$NODE_VER-darwin-arm64.tar.gz" "$TMP/node.tgz" \
      || { bad "Node 下载失败（检查版本号 v$NODE_VER 是否存在）"; return 1; }
    tar -xzf "$TMP/node.tgz" -C "$TMP" || { bad "Node 解压失败"; return 1; }
    cp "$TMP/node-v$NODE_VER-darwin-arm64/bin/node" "$NODE" || { bad "复制 node 失败"; return 1; }
    chmod +x "$NODE"
    ok "$("$NODE" -v) → $NODE"

    if [ -z "$NPM_VER" ]; then
      step "解析最新 npm"
      NPM_VER="$(resolve_npm_ver)"
      ok "选定 $NPM_VER"
    fi
    step "安装便携 npm v$NPM_VER"
    mkdir -p "$TMP/npm-extract"
    printf "  %s下载中（约 3 MB）...%s\n" "$C_DIM" "$C_RESET"
    fetch_file "https://registry.npmjs.org/npm/-/npm-$NPM_VER.tgz" "$TMP/npm.tgz" \
      || { bad "npm 下载失败"; return 1; }
    tar -xzf "$TMP/npm.tgz" -C "$TMP/npm-extract" || { bad "npm 解压失败"; return 1; }
    ditto "$TMP/npm-extract/package/" "$AGENTS_HOME/.dependencies/npm/" || { bad "复制 npm 失败"; return 1; }
    [ -f "$NPM_CLI" ] || { bad "npm 入口缺失：$NPM_CLI"; return 1; }
    ok "$("$NODE" "$NPM_CLI" -v) → $AGENTS_HOME/.dependencies/npm"

    export npm_config_cache="$AGENTS_HOME/.dependencies/.npm-cache"
  fi

  if [ "$key" = "all" ]; then
    if [ "$SKIP_AGENTS" = "1" ]; then
      step "跳过四个 AI（SKIP_AGENTS=1）"
    else
      step "安装四个 AI（下载约 950 MB，请耐心等待）"
      # allowScripts 必须写：claude 的原生二进制靠 postinstall 下载
      write_pkg_json claude agents-claude-code '{ "@anthropic-ai/claude-code": true }'
      write_pkg_json codex  agents-codex-cli  ''
      write_pkg_json pi     agents-pi         '{ "koffi": true, "protobufjs": true, "@google/genai": true }'
      write_pkg_json codebuddy agents-codebuddy-cli ''
      install_agent claude @anthropic-ai/claude-code "$CLAUDE_VER" "Claude Code" || { bad "Claude Code 安装失败"; return 1; }
      install_agent codex  @openai/codex            "$CODEX_VER"  "Codex CLI"   || { bad "Codex CLI 安装失败"; return 1; }
      install_agent pi     @earendil-works/pi-coding-agent "$PI_VER" "Pi"        || { bad "Pi 安装失败"; return 1; }
      install_agent codebuddy @tencent-ai/codebuddy-code "$CODEBUDDY_VER" "CodeBuddy" || { bad "CodeBuddy 安装失败"; return 1; }
      check_list="claude codex pi codebuddy cbc"
    fi
  else
    label="$(display_name "$key")"
    if [ "$SKIP_AGENTS" = "1" ]; then
      step "跳过 ${label}（SKIP_AGENTS=1，只装运行时）"
      check_list=""
    else
      step "安装 $label"
      case "$key" in
        claude)
          write_pkg_json claude agents-claude-code '{ "@anthropic-ai/claude-code": true }'
          install_agent claude @anthropic-ai/claude-code "$CLAUDE_VER" "Claude Code" || { bad "Claude Code 安装失败"; return 1; }
          ;;
        codex)
          write_pkg_json codex agents-codex-cli ''
          install_agent codex @openai/codex "$CODEX_VER" "Codex CLI" || { bad "Codex CLI 安装失败"; return 1; }
          ;;
        pi)
          write_pkg_json pi agents-pi '{ "koffi": true, "protobufjs": true, "@google/genai": true }'
          install_agent pi @earendil-works/pi-coding-agent "$PI_VER" "Pi" || { bad "Pi 安装失败"; return 1; }
          ;;
        codebuddy)
          write_pkg_json codebuddy agents-codebuddy-cli ''
          install_agent codebuddy @tencent-ai/codebuddy-code "$CODEBUDDY_VER" "CodeBuddy" || { bad "CodeBuddy 安装失败"; return 1; }
          ;;
      esac
      check_list="$(entry_names "$key" | tr '\n' ' ')"
    fi
  fi
  if [ "$SKIP_LINKS" = "1" ]; then
    step "跳过入口创建（SKIP_LINKS=1）"
  elif [ "$SKIP_AGENTS" = "1" ]; then
    step "跳过入口创建（未装任何 CLI，避免写出指向空文件的命令）"
  else
    step "建立命令入口"
    BIN_DIR="$(pick_bin_dir)"
    [ -n "$BIN_DIR" ] || { bad "找不到可写的 bin 目录"; return 1; }
    ok "入口目录：$BIN_DIR"
    if [ "$key" = "all" ]; then
      write_entries "$BIN_DIR" 1 || return 1
    else
      write_entries "$BIN_DIR" 1 "$key" || return 1
    fi
  fi

  local node_on_path=1
  [ "$SKIP_LINKS" = "1" ] && node_on_path=0
  # shellcheck disable=SC2086
  verify_commands "$BIN_DIR" "$node_on_path" $check_list || fail=1

  cleanup
  printf "\n%s体积：%s\n" "$C_DIM" "$(du -sh "$AGENTS_HOME" 2>/dev/null | cut -f1)"
  if [ "$fail" -eq 0 ]; then
    printf "%s%s安装完成。%s\n" "$C_GREEN" "$C_BOLD" "$C_RESET"
    printf "\n%s下一步：%s\n" "$C_BOLD" "$C_RESET"
    printf "  · 新开终端跑 claude / codex / pi / codebuddy（首次会引导登录）\n"
    printf "  · 登录态存在 ~/.claude、~/.codex、~/.pi、~/.codebuddy，不在 %s 内\n" "$AGENTS_HOME"
    if [ "$ACTION" = "menu" ]; then
      printf "  · 更新版本选「2 更新」，修入口选「4 设置环境」\n"
    else
      printf "  · 更新版本用 update，修入口用 setup\n"
    fi
  else
    printf "%s%s部分组件验证失败，请把上面报错发出来。%s\n" "$C_RED" "$C_BOLD" "$C_RESET"
  fi
  return "$fail"
}

# ---------- setup ----------
check_arch() {
  step "检查运行环境"
  local arch; arch="$(uname -m)"
  if [ "$arch" != "arm64" ]; then
    bad "当前架构是 ${arch}，但目录里的二进制全部是 arm64 版"
    warn "Intel Mac 上无法运行，需在目标机重新 npm install"
    return 1
  fi
  ok "架构 arm64（Apple Silicon）"

  if [ -x "$NODE" ]; then
    ok "便携 Node：$("$NODE" -v 2>/dev/null)"
  else
    bad "找不到便携 Node：$NODE"
    return 1
  fi

  local present=0 c
  PRESENT_COMPONENTS=""
  for c in claude codex pi codebuddy; do
    if [ -d "$AGENTS_HOME/$c/node_modules" ]; then
      present=$((present + 1))
      PRESENT_COMPONENTS="${PRESENT_COMPONENTS} ${c}"
    else
      warn "未安装 ${c}（跳过该组件的入口）"
    fi
  done
  PRESENT_COMPONENTS="${PRESENT_COMPONENTS# }"
  if [ "$present" -eq 0 ]; then
    bad "claude / codex / pi / codebuddy 一个都没装，无法继续"
    return 1
  fi
  ok "已安装 ${present}/4 个组件"
  return 0
}

clear_quarantine() {
  step "检查 quarantine 属性"
  # 抽检关键二进制，避免递归扫描上万文件
  if xattr -p com.apple.quarantine "$NODE" >/dev/null 2>&1; then
    printf "  %s清理中（整个目录，约需数十秒）...%s\n" "$C_DIM" "$C_RESET"
    if xattr -cr "$AGENTS_HOME" 2>/dev/null; then
      ok "已清除，否则 Gatekeeper 会拦截二进制"
    else
      warn "清理未完全成功（个别文件可能权限不足）"
      printf "  %s可手动执行：xattr -cr %s%s\n" "$C_DIM" "$AGENTS_HOME" "$C_RESET"
      return 1
    fi
  else
    ok "无 quarantine（本地复制/rsync 传输不会带）"
  fi
}

# 判定目录像不像本方案的安装根
looks_like_agents_home() {
  [ -d "$1/.dependencies/node/bin" ] || [ -d "$1/claude" ] \
    || [ -d "$1/codex" ] || [ -d "$1/pi" ]
}

# 未显式指定 AGENTS_HOME 时按顺序探测；找不到就失败，绝不猜
resolve_agents_home() {
  local c
  for c in "$SELF_DIR" "$HOME/.agents"; do
    if looks_like_agents_home "$c"; then printf '%s' "$c"; return 0; fi
  done
  return 1
}

setup_action() {
  local root
  if [ -z "$AGENTS_HOME_SET" ]; then
    if root="$(resolve_agents_home)"; then
      AGENTS_HOME="$root"
    else
      bad "找不到安装目录：$SELF_DIR 和 $HOME/.agents 都不像本方案的安装根"
      printf "  %s请显式指定：AGENTS_HOME=/实际路径 %s setup%s\n" "$C_DIM" "$0" "$C_RESET"
      return 1
    fi
  fi
  set_home_paths
  local bin_dir with_node
  local vfail=0

  printf "\n%s%s────  agents-green  部署检查  ────%s\n" "$C_BOLD" "$C_CYAN" "$C_RESET"
  printf "%s位置：%s%s\n" "$C_DIM" "$AGENTS_HOME" "$C_RESET"

  if ! check_arch; then
    printf "\n%s环境不满足，已中止。%s\n" "$C_RED" "$C_RESET"
    return 1
  fi

  clear_quarantine

  step "建立命令入口"
  bin_dir="$(pick_bin_dir)"
  if [ -z "$bin_dir" ]; then
    bad "找不到可写的 bin 目录"
    return 1
  fi
  ok "入口目录：$bin_dir"
  if [ "${NO_NODE_LINK:-0}" = "1" ]; then with_node=0; else with_node=1; fi
  # 只写这台机器上真正装了的组件，不造指向空文件的入口
  write_entries "$bin_dir" "$with_node" $PRESENT_COMPONENTS || return 1

  case ":$PATH:" in
    *":$bin_dir:"*) ok "该目录已在 PATH 中" ;;
    *) warn "$bin_dir 不在当前 PATH；Magpie 通常仍能扫到，终端需自行加入" ;;
  esac
  if [ "$bin_dir" = "$HOME/.local/bin" ]; then
    warn "该目录通常不被 Magpie 等 GUI 应用扫描"
    warn "若已装 Homebrew 或愿意用 sudo，改放系统目录更稳："
    printf "     sudo mkdir -p /usr/local/bin && sudo cp %s/claude %s/codex %s/pi %s/codebuddy /usr/local/bin/\n" \
      "$bin_dir" "$bin_dir" "$bin_dir" "$bin_dir"
  fi

  printf "\n"
  if verify_commands "$bin_dir" "$with_node" $PRESENT_COMPONENTS; then
    printf "%s%s全部就绪。%s\n" "$C_GREEN" "$C_BOLD" "$C_RESET"
  else
    vfail=1
    printf "%s有命令无法运行，请把上面报错发出来。%s\n" "$C_RED" "$C_RESET"
  fi

  printf "\n%s下一步：%s\n" "$C_BOLD" "$C_RESET"
  printf "  1. 新开终端窗口，敲 %s 即可\n" "$PRESENT_COMPONENTS"
  printf "  2. 首次运行会引导登录，登录态存在 ~/.claude、~/.codex、~/.pi、~/.codebuddy（不在本目录内）\n"
  printf "  3. 若用 Magpie，退出并重开一次，Agents 面板才会重新扫描\n"
  printf "  4. 更新版本：菜单选「2 更新」，或运行 ./agents-green.command update\n"
  return "$vfail"
}

# ---------- update ----------
PKG_CLAUDE="@anthropic-ai/claude-code"
PKG_CODEX="@openai/codex"
PKG_PI="@earendil-works/pi-coding-agent"
PKG_CODEBUDDY="@tencent-ai/codebuddy-code"
CUR_CLAUDE=""; CUR_CODEX=""; CUR_PI=""; CUR_CODEBUDDY=""
LATEST_CLAUDE=""; LATEST_CODEX=""; LATEST_PI=""; LATEST_CODEBUDDY=""
CUR_NODE=""; CUR_NPM=""; LATEST_NODE=""; LATEST_NPM=""

pkg_of() {
  case "$1" in
    claude) printf '%s' "$PKG_CLAUDE" ;;
    codex)  printf '%s' "$PKG_CODEX" ;;
    pi)     printf '%s' "$PKG_PI" ;;
    codebuddy) printf '%s' "$PKG_CODEBUDDY" ;;
  esac
}

display_name() {
  case "$1" in
    claude) printf 'Claude Code' ;;
    codex)  printf 'Codex CLI' ;;
    pi)     printf 'Pi' ;;
    codebuddy) printf 'CodeBuddy' ;;
  esac
}

current_version() {
  local dir="$AGENTS_HOME/$1/node_modules/.bin/$1"
  case "$1" in
    claude) [ -x "$dir" ] && "$dir" --version 2>/dev/null | head -1 | sed 's/ (Claude Code)$//' ;;
    codex)  [ -x "$dir" ] && "$NODE" "$dir" --version 2>/dev/null | head -1 | sed 's/^codex-cli //' ;;
    pi)     [ -f "$dir" ] && "$NODE" "$dir" --version 2>/dev/null | head -1 ;;
    codebuddy) [ -f "$dir" ] && "$NODE" "$dir" --version 2>/dev/null | head -1 ;;
  esac
}

fetch_latest() {
  "$NODE" "$NPM_CLI" view "$(pkg_of "$1")" version 2>/dev/null | tr -d '\r' | head -1
}

check_all() {
  local td
  td="$(mktemp -d 2>/dev/null)" || td="/tmp/agents-check.$$"
  mkdir -p "$td"
  CUR_CLAUDE="$(current_version claude)"
  CUR_CODEX="$(current_version codex)"
  CUR_PI="$(current_version pi)"
  CUR_CODEBUDDY="$(current_version codebuddy)"
  ( fetch_latest claude > "$td/c" 2>/dev/null ) &
  ( fetch_latest codex  > "$td/x" 2>/dev/null ) &
  ( fetch_latest pi     > "$td/p" 2>/dev/null ) &
  ( fetch_latest codebuddy > "$td/b" 2>/dev/null ) &
  wait
  LATEST_CLAUDE="$(head -1 "$td/c" 2>/dev/null)"
  LATEST_CODEX="$(head -1 "$td/x" 2>/dev/null)"
  LATEST_PI="$(head -1 "$td/p" 2>/dev/null)"
  LATEST_CODEBUDDY="$(head -1 "$td/b" 2>/dev/null)"
  rm -rf "$td"
}

status_line() {
  local name="$1" cur="$2" latest="$3" state color
  [ -n "$cur" ] || cur="-"
  if [ -z "$latest" ]; then
    state="最新版未知"; color="$C_DIM"
  elif [ "$cur" = "-" ]; then
    state="未安装 → $latest"; color="$C_RED"
  elif [ "$cur" = "$latest" ]; then
    state="已是最新"; color="$C_GREEN"
  else
    state="可更新 → $latest"; color="$C_YELLOW"
  fi
  printf "  %-13s %-12s %s%s%s\n" "$name" "$cur" "$color" "$state" "$C_RESET"
}

print_status() {
  # 行格式是 "  %-13s %-12s %s"：版本列从第 17 列起、状态列从第 30 列起。
  # 中文每字 3 字节但只占 2 列，%Ns 按字节补空格会错位，所以表头空格按显示列数写死。
  printf "  组件%10s当前版本%5s状态\n" "" ""
  printf "  %s\n" "──────────────────────────────────────────"
  status_line "Node.js"     "$CUR_NODE"   "$LATEST_NODE"
  status_line "npm"         "$CUR_NPM"    "$LATEST_NPM"
  printf "  %s\n" "╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌"
  status_line "Claude Code" "$CUR_CLAUDE" "$LATEST_CLAUDE"
  status_line "Codex CLI"   "$CUR_CODEX"  "$LATEST_CODEX"
  status_line "Pi"          "$CUR_PI"     "$LATEST_PI"
  status_line "CodeBuddy" "$CUR_CODEBUDDY" "$LATEST_CODEBUDDY"
}

draw_update_menu() {
  if [ -t 1 ]; then clear; fi
  printf "\n%s%s────  agents-green  版本更新  ────%s\n" "$C_BOLD" "$C_CYAN" "$C_RESET"
  printf "%s位置：%s%s\n" "$C_DIM" "$AGENTS_HOME" "$C_RESET"
  printf "\n"
  print_status
  printf "\n"
  printf "  %s1%s  更新 Claude Code\n" "$C_BOLD" "$C_RESET"
  printf "  %s2%s  更新 Codex CLI\n"   "$C_BOLD" "$C_RESET"
  printf "  %s3%s  更新 Pi\n"          "$C_BOLD" "$C_RESET"
  printf "  %s4%s  更新 CodeBuddy\n" "$C_BOLD" "$C_RESET"
  printf "  %s5%s  更新全部\n"          "$C_BOLD" "$C_RESET"
  printf "  %s6%s  只更新运行时（Node / npm）\n" "$C_BOLD" "$C_RESET"
  printf "  %sr%s  重新检查/刷新\n"     "$C_DIM"  "$C_RESET"
  if [ "$ACTION" = "menu" ]; then
    printf "  %sq%s  返回菜单\n\n"      "$C_DIM"  "$C_RESET"
  else
    printf "  %sq%s  退出\n\n"         "$C_DIM"  "$C_RESET"
  fi
  printf "请选择 [1-6/r/q]: "
}

do_update() {
  local key="$1" dir pkg label before after rc
  dir="$AGENTS_HOME/$key"; pkg="$(pkg_of "$key")"; label="$(display_name "$key")"
  printf "\n%s→ 更新 %s%s\n" "$C_CYAN" "$label" "$C_RESET"

  if [ ! -f "$dir/package.json" ]; then
    printf "  %s✗ 未安装：找不到 %s/package.json%s\n" "$C_RED" "$dir" "$C_RESET"
    return 1
  fi

  before="$(current_version "$key" | sed 's/^[[:space:]]*//')"
  printf "  %s当前：%s%s\n" "$C_DIM" "${before:-未知}" "$C_RESET"

  "$NODE" "$NPM_CLI" install --prefix "$dir" "${pkg}@latest" \
    --no-audit --no-fund --loglevel=warn 2>&1 | tail -6
  rc=${PIPESTATUS[0]}

  if [ "$rc" -ne 0 ]; then
    printf "  %s✗ 更新失败（退出码 %s），当前安装可能已部分变化，请检查或重装%s\n" "$C_RED" "$rc" "$C_RESET"
    return 1
  fi

  after="$(current_version "$key" | sed 's/^[[:space:]]*//')"
  case "$key" in
    claude) CUR_CLAUDE="$after"; LATEST_CLAUDE="$after" ;;
    codex)  CUR_CODEX="$after";  LATEST_CODEX="$after" ;;
    pi)     CUR_PI="$after";     LATEST_PI="$after" ;;
    codebuddy) CUR_CODEBUDDY="$after"; LATEST_CODEBUDDY="$after" ;;
  esac
  STATUS_FRESH=1
  if [ "$before" = "$after" ]; then
    printf "  %s✓ 已是最新：%s%s\n" "$C_GREEN" "$after" "$C_RESET"
  else
    printf "  %s✓ 已更新：%s → %s%s\n" "$C_GREEN" "${before:-未知}" "$after" "$C_RESET"
  fi
}

run_choice() {
  local failed=0
  case "$1" in
    1) do_update claude || failed=1 ;;
    2) do_update codex  || failed=1 ;;
    3) do_update pi     || failed=1 ;;
    4) do_update codebuddy || failed=1 ;;
    5)
      do_update claude || failed=1
      do_update codex  || failed=1
      do_update pi     || failed=1
      do_update codebuddy || failed=1
      ;;
    *) return 2 ;;
  esac
  return "$failed"
}


# 运行时更新失败后的恢复：npm 用整目录换回，Node 用同目录临时文件换回。
restore_runtime() {
  local node_old="$1" npm_old="$2" npm_dir="$3" rc=0
  if [ -d "$npm_old" ]; then
    if rm -rf "$npm_dir" 2>/dev/null && mv "$npm_old" "$npm_dir" 2>/dev/null; then
      :
    else
      bad "npm 恢复失败，旧目录保留在 $npm_old"
      rc=1
    fi
  fi
  if [ -f "$node_old" ]; then
    rm -f "$NODE.rollback" 2>/dev/null
    if cp -p "$node_old" "$NODE.rollback" 2>/dev/null \
         && chmod +x "$NODE.rollback" 2>/dev/null \
         && mv -f "$NODE.rollback" "$NODE" 2>/dev/null; then
      :
    else
      bad "Node 恢复失败，旧文件保留在 $node_old"
      rc=1
    fi
    rm -f "$NODE.rollback" 2>/dev/null
  fi
  return "$rc"
}

# 只更新便携运行时（Node / npm），不重装四个 CLI
update_runtime() {
  set_home_paths
  if [ ! -x "$NODE" ]; then
    bad "找不到便携 Node：$NODE"
    return 1
  fi

  step "检查当前运行时"
  local cur_node cur_npm new_node new_npm major_changed=0 omaj nmaj
  local stage_node="" stage_npm="" check_node check_npm actual_node actual_npm
  local node_old="" npm_dir="$AGENTS_HOME/.dependencies/npm"
  local npm_new="" npm_old="" apply_ok=0 fail_reason=""
  cur_node="$("$NODE" -v 2>/dev/null)"
  cur_npm="$("$NODE" "$NPM_CLI" -v 2>/dev/null)"
  ok "Node $cur_node / npm $cur_npm"

  step "解析最新版本"
  # 更新不能用安装时的内置旧版本兜底，否则查询失败可能把新版本降级。
  new_node="$(resolve_node_ver "")"
  new_npm="$(resolve_npm_ver "")"
  if [ -z "$new_node" ] || [ -z "$new_npm" ]; then
    bad "无法确认最新版本，本次未更新，当前版本保持不变"
    return 1
  fi
  ok "Node LTS v$new_node / npm $new_npm"

  if [ "$cur_node" = "v$new_node" ] && [ "$cur_npm" = "$new_npm" ]; then
    printf "\n%s✓ 运行时已是最新，无需下载。%s\n" "$C_GREEN" "$C_RESET"
    return 0
  fi

  TMP="$AGENTS_HOME/.update-tmp"
  if ! rm -rf "$TMP" 2>/dev/null || ! mkdir -p "$TMP"; then
    bad "无法准备更新临时目录：$TMP"
    TMP=""
    return 1
  fi

  # 先下载、解压并验证所有待更新组件，此阶段不碰现有运行时。
  if [ "$cur_node" != "v$new_node" ]; then
    step "准备 Node  $cur_node → v$new_node"
    printf "  %s下载中（约 50 MB）...%s\n" "$C_DIM" "$C_RESET"
    if ! fetch_file "https://nodejs.org/dist/v$new_node/node-v$new_node-darwin-arm64.tar.gz" "$TMP/node.tgz"; then
      bad "Node 下载失败，当前运行时未改动"
      cleanup
      return 1
    fi
    if ! tar -xzf "$TMP/node.tgz" -C "$TMP"; then
      bad "Node 解压失败，当前运行时未改动"
      cleanup
      return 1
    fi
    stage_node="$TMP/node-v$new_node-darwin-arm64/bin/node"
    actual_node="$("$stage_node" -v 2>/dev/null)"
    if [ "$actual_node" != "v$new_node" ]; then
      bad "新 Node 验证失败，当前运行时未改动"
      cleanup
      return 1
    fi
    omaj="${cur_node#v}"; omaj="${omaj%%.*}"
    nmaj="${new_node%%.*}"
    [ "$omaj" = "$nmaj" ] || major_changed=1
  else
    ok "Node 已是 ${cur_node}，跳过"
  fi

  if [ "$cur_npm" != "$new_npm" ]; then
    step "准备 npm  $cur_npm → $new_npm"
    mkdir -p "$TMP/npm-extract"
    printf "  %s下载中（约 3 MB）...%s\n" "$C_DIM" "$C_RESET"
    if ! fetch_file "https://registry.npmjs.org/npm/-/npm-$new_npm.tgz" "$TMP/npm.tgz"; then
      bad "npm 下载失败，当前运行时未改动"
      cleanup
      return 1
    fi
    if ! tar -xzf "$TMP/npm.tgz" -C "$TMP/npm-extract"; then
      bad "npm 解压失败，当前运行时未改动"
      cleanup
      return 1
    fi
    stage_npm="$TMP/npm-extract/package"
    check_node="${stage_node:-$NODE}"
    check_npm="$("$check_node" "$stage_npm/bin/npm-cli.js" -v 2>/dev/null)"
    if [ "$check_npm" != "$new_npm" ]; then
      bad "新 npm 验证失败，当前运行时未改动"
      cleanup
      return 1
    fi
  else
    ok "npm 已是 ${cur_npm}，跳过"
  fi

  # 先准备回滚副本及干净的新 npm 目录，仍然不替换现有文件。
  if [ -n "$stage_node" ]; then
    node_old="$TMP/node.old"
    if ! cp -p "$NODE" "$node_old"; then
      bad "无法备份当前 Node，更新已停止"
      cleanup
      return 1
    fi
  fi
  if [ -n "$stage_npm" ]; then
    npm_new="$AGENTS_HOME/.dependencies/.npm-new.$$"
    npm_old="$AGENTS_HOME/.dependencies/.npm-old.$$"
    if [ -e "$npm_new" ] || [ -e "$npm_old" ]; then
      bad "发现本次更新所需的临时目录已存在，更新已停止"
      cleanup
      return 1
    fi
    if ! ditto "$stage_npm/" "$npm_new/"; then
      bad "无法准备新 npm 目录，当前运行时未改动"
      rm -rf "$npm_new" 2>/dev/null
      cleanup
      return 1
    fi
  fi

  # 一次性执行替换；任何一步失败都落到统一恢复逻辑。
  while true; do
    if [ -n "$stage_node" ]; then
      rm -f "$NODE.new" 2>/dev/null
      cp "$stage_node" "$NODE.new" 2>/dev/null || { fail_reason="复制 Node 失败"; break; }
      chmod +x "$NODE.new" 2>/dev/null || { fail_reason="设置 Node 权限失败"; break; }
      mv -f "$NODE.new" "$NODE" 2>/dev/null || { fail_reason="替换 Node 失败"; break; }
    fi
    if [ -n "$stage_npm" ]; then
      mv "$npm_dir" "$npm_old" 2>/dev/null || { fail_reason="备份当前 npm 目录失败"; break; }
      mv "$npm_new" "$npm_dir" 2>/dev/null || { fail_reason="替换 npm 失败"; break; }
    fi
    actual_node="$("$NODE" -v 2>/dev/null)"
    actual_npm="$("$NODE" "$NPM_CLI" -v 2>/dev/null)"
    if [ "$actual_node" != "v$new_node" ] || [ "$actual_npm" != "$new_npm" ]; then
      fail_reason="更新后版本验证失败"
      break
    fi
    apply_ok=1
    break
  done

  if [ "$apply_ok" != "1" ]; then
    bad "$fail_reason，开始恢复原运行时"
    rm -f "$NODE.new" 2>/dev/null
    [ -n "$npm_new" ] && rm -rf "$npm_new" 2>/dev/null
    if restore_runtime "$node_old" "$npm_old" "$npm_dir"; then
      ok "原 Node / npm 未改动或已恢复"
      cleanup
    else
      bad "自动恢复未完成，更新备份已保留在 $TMP"
      TMP=""  # 禁止 EXIT 清理删除最后的回滚副本
    fi
    return 1
  fi

  [ -d "$npm_old" ] && rm -rf "$npm_old" 2>/dev/null
  ok "Node $actual_node / npm $actual_npm"
  cleanup
  if [ "$major_changed" = "1" ]; then
    warn "Node 主版本已变，原生模块（koffi 等）可能需要重装：./agents-green.command install --force all"
  fi
  printf "\n%s✓ 运行时已更新。%s\n" "$C_GREEN" "$C_RESET"
}

update_action() {
  set_home_paths
  if [ ! -x "$NODE" ]; then
    bad "找不到便携 Node：$NODE"
    if [ "$ACTION" = "menu" ]; then
      printf "  %s请先选「1 安装」装出运行时。%s\n" "$C_DIM" "$C_RESET"
    else
      printf "  %s请确认 %s/.dependencies 目录完整，或先运行 install。%s\n" "$C_DIM" "$AGENTS_HOME" "$C_RESET"
    fi
    return 1
  fi
  if [ ! -f "$NPM_CLI" ]; then
    bad "找不到便携 npm：$NPM_CLI"
    return 1
  fi
  export PATH="$(dirname "$NODE"):$PATH"
  export npm_config_cache="$AGENTS_HOME/.dependencies/.npm-cache"
  export npm_config_update_notifier=false
  export npm_config_fetch_timeout=8000
  export npm_config_fetch_retries=1

  if [ $# -gt 0 ]; then
    case "$1" in
      all)      run_choice 5; return ;;
      1|2|3|4|5) run_choice "$1"; return ;;
      runtime)  update_runtime; return ;;
      check)
        refresh_status
        printf "\n"
        print_status
        return 0
        ;;
      *)
        printf "用法：%s update [1-5|all|runtime|check]\n" "$0" >&2
        return 2
        ;;
    esac
  fi

  ensure_status
  local choice
  while true; do
    draw_update_menu
    if ! read -r choice; then
      printf "\n"
      return 0
    fi
    choice="$(printf '%s' "$choice" | tr -d '[:space:]')"
    case "$choice" in
      6) update_runtime; refresh_status ;;
      1|2|3|4|5)
        run_choice "$choice"
        ;;
      r|R)
        refresh_status
        ;;
      q|Q|quit|exit) return 0 ;;
      "") continue ;;
      *)
        printf "%s无效选择：%s（请输入 1-6、r 或 q）%s\n" "$C_YELLOW" "$choice" "$C_RESET"
        sleep 1
        ;;
    esac
  done
}

# ---------- uninstall ----------
# 判断 bin 目录里的一个文件是否为本方案为当前 AGENTS_HOME 写的入口：
# 既要带 agents-green 标记，标记那行指向的路径还必须是当前 AGENTS_HOME（或其物理路径）
is_ours_entry() {
  local p="$1" line tgt phys real_home
  real_home="$(cd "$AGENTS_HOME" 2>/dev/null && pwd -P)"

  if [ -L "$p" ]; then
    tgt="$(readlink "$p" 2>/dev/null)" || return 1
    [ -n "$tgt" ] || return 1
    [ -n "$real_home" ] || return 1
    phys="$(cd "$(dirname "$tgt")" 2>/dev/null && pwd -P)/$(basename "$tgt")"
    case "$phys" in
      "$real_home"/*) return 0 ;;
    esac
    return 1
  fi

  line="$(grep -m1 "agents-green:" "$p" 2>/dev/null)" || return 1
  tgt="${line##*-> }"
  tgt="${tgt%/}"
  [ -n "$tgt" ] || return 1
  [ "$tgt" = "${AGENTS_HOME%/}" ] && return 0
  [ -n "$real_home" ] || return 1
  phys="$(cd "$tgt" 2>/dev/null && pwd -P)" || return 1
  [ "$phys" = "$real_home" ]
}

uninstall_one() {
  local key="$1" label dir p tgt d e answer leftover
  local -a found=()
  local -a bin_candidates=(/opt/homebrew/bin /usr/local/bin "$HOME/.local/bin")
  label="$(display_name "$key")"
  dir="$AGENTS_HOME/$key"
  step "卸载 $label"
  if [ ! -d "$dir" ]; then
    warn "$label 未安装（$dir 不存在），无需卸载"
    return 0
  fi
  ok "目标：${dir}（$(du -sh "$dir" 2>/dev/null | cut -f1)）"
  for d in ${bin_candidates[@]+"${bin_candidates[@]}"}; do
    [ -d "$d" ] || continue
    # 一个组件可能对应多个入口名（如 CodeBuddy 的 codebuddy / cbc），逐个清
    for e in $(entry_names "$key"); do
      p="$d/$e"
      if [ -L "$p" ]; then
        tgt="$(readlink "$p" 2>/dev/null)"
        if is_ours_entry "$p"; then found+=("$p"); ok "$p → $tgt"
        else warn "$p 指向别处，跳过"; fi
      elif [ -f "$p" ]; then
        if is_ours_entry "$p"; then found+=("$p"); ok "${p}（wrapper）"
        else warn "$p 不是本方案生成，跳过"; fi
      fi
    done
  done
  [ "${#found[@]}" -eq 0 ] && printf "  %s（无入口）%s\n" "$C_DIM" "$C_RESET"

  if [ "$DRY" = "1" ]; then
    printf "\n%s（--dry-run：以上仅为预览，未做任何改动）%s\n" "$C_YELLOW" "$C_RESET"
    return 0
  fi

  printf "\n%s此操作不可撤销。%s\n" "$C_RED" "$C_BOLD"
  printf "  · 删除目录：%s\n" "$dir"
  printf "  · 删除入口：%s 个\n" "${#found[@]}"
  printf "  %s单个卸载不做备份，需要时用「安装」重新安装即可。%s\n" "$C_DIM" "$C_RESET"
  if [ "$ASSUME_YES" != "1" ]; then
    printf "\n确认请输入 %syes%s，其他任意输入取消：" "$C_BOLD" "$C_RESET"
    read -r answer
    [ "$answer" = "yes" ] || { printf "\n%s已取消。%s\n" "$C_DIM" "$C_RESET"; return 0; }
  fi

  for p in ${found[@]+"${found[@]}"}; do
    if rm -f "$p" 2>/dev/null; then ok "已删除 $p"; else bad "删除失败：${p}（可能需要 sudo）"; fi
  done
  if rm -rf "$dir" 2>/dev/null; then
    ok "已删除 $dir"
  else
    bad "删除失败：$dir"
    return 1
  fi
  leftover="$(command -v "$key" 2>/dev/null || true)"
  if [ -n "$leftover" ]; then
    warn "${key} 仍可用：${leftover}（可能是系统或 brew 装的，未动）"
  else
    ok "$label 已从 PATH 消失"
  fi
}

# 删除单个路径；路径不存在（含失效软链）也算成功
rm_path() {
  [ -e "$1" ] || [ -L "$1" ] || return 0
  rm -rf "$1" 2>/dev/null
}

uninstall_action() {
  local key="${1:-all}"
  case "$key" in
    all|claude|codex|pi|codebuddy) ;;
    *) die "未知组件：${key}（可用 all / claude / codex / pi / codebuddy）" ;;
  esac
  local -a entries=(claude codex pi codebuddy cbc node npm npx)
  local -a bin_candidates=(/opt/homebrew/bin /usr/local/bin "$HOME/.local/bin")
  local -a found_entries=()
  local -a files=()
  local -a failed_items=()
  local dir e p tgt sub f leftover answer backup backup_dir clean_fail=0 dep_fail=0

  step "确认目标"
  local real
  real="$(cd "$AGENTS_HOME" 2>/dev/null && pwd -P)" || real="$AGENTS_HOME"
  case "$real" in
    ""|"/") die "拒绝在 ${real:-空路径} 上操作" ;;
  esac
  if [ "$real" = "$HOME" ]; then
    die "拒绝删除 HOME 本身（${real}）"
  fi
  case "$HOME" in
    "$real"/*) die "拒绝删除 ${real}：它是 HOME（${HOME}）的上级目录" ;;
  esac
  AGENTS_HOME="$real"          # 后续所有操作都用解过软链的真实路径
  if [ "$key" != "all" ]; then
    uninstall_one "$key"
    return $?
  fi
  if [ ! -d "$AGENTS_HOME" ]; then
    warn "$AGENTS_HOME 不存在，无需卸载"
    if [ "$DRY" != "1" ]; then
      printf "  %s仍会清理残留的入口文件（如果有）%s\n" "$C_DIM" "$C_RESET"
    fi
  else
    [ -d "$AGENTS_HOME/.dependencies" ] || [ -d "$AGENTS_HOME/claude" ] \
      || die "$AGENTS_HOME 的结构不像本方案的安装目录，拒绝删除"
    ok "目标：${AGENTS_HOME}（$(du -sh "$AGENTS_HOME" 2>/dev/null | cut -f1)）"
  fi

  step "将清理的入口"
  for dir in ${bin_candidates[@]+"${bin_candidates[@]}"}; do
    [ -d "$dir" ] || continue
    for e in ${entries[@]+"${entries[@]}"}; do
      p="$dir/$e"
      if [ -L "$p" ]; then
        tgt="$(readlink "$p" 2>/dev/null)"
        if is_ours_entry "$p"; then found_entries+=("$p"); ok "$p → $tgt"
        else warn "$p 指向别处，跳过"; fi
      elif [ -f "$p" ]; then
        if is_ours_entry "$p"; then found_entries+=("$p"); ok "${p}（wrapper）"
        else warn "$p 不是本方案生成，跳过"; fi
      fi
    done
  done
  [ "${#found_entries[@]}" -eq 0 ] && printf "  %s（无）%s\n" "$C_DIM" "$C_RESET"

  step "将清理的脚本内容"
  printf "  %s·%s claude / codex / pi / codebuddy 中的 node_modules、package.json、package-lock.json 等\n" "$C_DIM" "$C_RESET"
  printf "  %s·%s .dependencies（Node、npm、缓存、临时目录）\n" "$C_DIM" "$C_RESET"
  printf "  %s·%s 保留 %s 本身及其中其他内容\n" "$C_DIM" "$C_RESET" "$AGENTS_HOME"

  step "不会改动的东西"
  for f in "$HOME/.claude" "$HOME/.codex" "$HOME/.pi" "$HOME/.codebuddy" "$HOME/.local/share/codebuddy"; do
    [ -e "$f" ] && printf "  %s·%s %s（登录态与配置）\n" "$C_DIM" "$C_RESET" "$f"
  done
  printf "  %s·%s 安装根目录本身，以及其中非本脚本生成的其他文件\n" "$C_DIM" "$C_RESET"
  printf "  %s·%s 其他 Homebrew 文件、系统 node/npm\n" "$C_DIM" "$C_RESET"

  if [ "$DRY" = "1" ]; then
    printf "\n%s（--dry-run：以上仅为预览，未做任何改动）%s\n" "$C_YELLOW" "$C_RESET"
    return 0
  fi

  printf "\n%s此操作不可撤销。%s\n" "$C_RED" "$C_BOLD"
  printf "  · 清理脚本内容：claude / codex / pi / codebuddy / .dependencies\n"
  printf "  · 保留目录：%s（及其中其他内容）\n" "$AGENTS_HOME"
  printf "  · 删除入口：%s 个\n" "${#found_entries[@]}"
  if [ "$ASSUME_YES" != "1" ]; then
    printf "\n确认请输入 %syes%s，其他任意输入取消：" "$C_BOLD" "$C_RESET"
    read -r answer
    [ "$answer" = "yes" ] || { printf "\n%s已取消。%s\n" "$C_DIM" "$C_RESET"; return 0; }
  fi

  if [ "$DO_BACKUP" = "1" ] && [ -d "$AGENTS_HOME" ]; then
    step "备份脚本与配置清单"
    for f in README.md agents-green.command \
             claude/package.json claude/package-lock.json \
             codex/package.json codex/package-lock.json \
             pi/package.json pi/package-lock.json \
             codebuddy/package.json codebuddy/package-lock.json; do
      [ -e "$AGENTS_HOME/$f" ] && files+=("$f")
    done
    if [ "${#files[@]}" -gt 0 ]; then
      backup_dir="$AGENTS_HOME/.backups"
      backup="$backup_dir/agents-backup-$(date +%Y%m%d-%H%M).tgz"
      if ! mkdir -p "$backup_dir" 2>/dev/null; then
        die "无法创建备份目录 ${backup_dir}，已停止卸载，未删除任何内容（如需无备份卸载，请明确使用 --no-backup）"
      fi
      if tar -czf "$backup" -C "$AGENTS_HOME" ${files[@]+"${files[@]}"} 2>/dev/null \
           && [ -s "$backup" ]; then
        ok "已备份到 ${backup}（$(du -sh "$backup" | cut -f1)，不含 node_modules）"
      else
        die "备份失败，已停止卸载，未删除任何内容（如需无备份卸载，请明确使用 --no-backup）"
      fi
    else
      die "没有可备份的文件，已停止卸载，未删除任何内容（如需继续，请明确使用 --no-backup）"
    fi
  fi

  step "清理入口"
  for p in ${found_entries[@]+"${found_entries[@]}"}; do
    if rm -f "$p" 2>/dev/null; then
      ok "已删除 $p"
    else
      bad "删除失败：${p}（可能需要 sudo）"
      failed_items+=("$p")
    fi
  done
  for dir in ${bin_candidates[@]+"${bin_candidates[@]}"}; do
    [ -d "$dir" ] || continue
    for e in ${entries[@]+"${entries[@]}"}; do
      p="$dir/$e"
      if [ -L "$p" ] && [ ! -e "$p" ]; then
        tgt="$(readlink "$p" 2>/dev/null || true)"
        case "$tgt" in
          *"$AGENTS_HOME"*)
            if rm -f "$p" 2>/dev/null; then
              warn "已清理失效软链 $p"
            else
              bad "删除失败：$p"
              failed_items+=("$p")
            fi
            ;;
        esac
      fi
    done
  done

  step "清理脚本生成的内容"
  if [ -d "$AGENTS_HOME" ]; then
    # 顶层临时目录（安装/更新中断时可能留下）
    for sub in "$AGENTS_HOME/.install-tmp" "$AGENTS_HOME/.update-tmp"; do
      [ -e "$sub" ] || [ -L "$sub" ] || continue
      if rm_path "$sub"; then
        ok "已清理 $sub"
      else
        bad "删除失败：$sub"
        failed_items+=("$sub")
      fi
    done

    # 四个组件目录：只删本脚本生成的文件，保留用户自己的文件
    for sub in claude codex pi codebuddy; do
      p="$AGENTS_HOME/$sub"
      [ -d "$p" ] || continue
      if [ -L "$p" ]; then
        warn "跳过软链目录：${p}（请手动确认）"
        continue
      fi
      clean_fail=0
      for f in node_modules package.json package-lock.json npm-shrinkwrap.json .package-lock.json; do
        [ -e "$p/$f" ] || [ -L "$p/$f" ] || continue
        if rm_path "$p/$f"; then
          :
        else
          bad "删除失败：$p/$f"
          failed_items+=("$p/$f")
          clean_fail=1
        fi
      done
      if [ "$clean_fail" = "0" ] && rmdir "$p" 2>/dev/null; then
        ok "已删除 $p"
      elif [ -n "$(ls -A "$p" 2>/dev/null)" ]; then
        if [ "$clean_fail" = "1" ]; then
          warn "部分内容未能删除，目录保留：$p"
        else
          warn "保留 ${p}（里面还有非本脚本的内容）"
        fi
      else
        bad "目录未能删除：$p"
        failed_items+=("$p")
      fi
    done

    # .dependencies：只删本脚本生成的内容
    p="$AGENTS_HOME/.dependencies"
    if [ -L "$p" ]; then
      warn "跳过软链目录：${p}（请手动确认）"
    elif [ -d "$p" ]; then
      dep_fail=0
      for sub in node npm .npm-cache .install-tmp .update-tmp; do
        [ -e "$p/$sub" ] || [ -L "$p/$sub" ] || continue
        if rm_path "$p/$sub"; then
          :
        else
          bad "删除失败：$p/$sub"
          failed_items+=("$p/$sub")
          dep_fail=1
        fi
      done
      for sub in "$p"/.npm-new.* "$p"/.npm-old.*; do
        [ -e "$sub" ] || [ -L "$sub" ] || continue
        if rm_path "$sub"; then
          :
        else
          bad "删除失败：$sub"
          failed_items+=("$sub")
          dep_fail=1
        fi
      done
      if [ "$dep_fail" = "0" ] && rmdir "$p" 2>/dev/null; then
        ok "已删除 $p"
      elif [ -n "$(ls -A "$p" 2>/dev/null)" ]; then
        if [ "$dep_fail" = "1" ]; then
          warn "部分内容未能删除，目录保留：$p"
        else
          warn "保留 ${p}（里面还有非本脚本的内容）"
        fi
      else
        bad "目录未能删除：$p"
        failed_items+=("$p")
      fi
    fi

    if [ -d "$AGENTS_HOME" ]; then
      ok "安装根目录已保留：$AGENTS_HOME"
    else
      bad "安装根目录不存在：$AGENTS_HOME"
      failed_items+=("$AGENTS_HOME")
    fi
  else
    ok "目录已不存在，无需清理"
  fi

  step "验证"
  leftover=0
  for e in ${entries[@]+"${entries[@]}"}; do
    if command -v "$e" >/dev/null 2>&1; then
      p="$(command -v "$e")"
      warn "$e 仍可用：${p}（可能是系统或 brew 装的，未动）"
      leftover=1
    fi
  done
  [ "$leftover" = "0" ] && ok "四个 AI 与 node/npm/npx 均已从 PATH 消失"

  if [ "${#failed_items[@]}" -gt 0 ]; then
    printf "\n%s%s卸载部分完成，以下 %s 项未能删除。%s\n" \
      "$C_RED" "$C_BOLD" "${#failed_items[@]}" "$C_RESET"
    for p in ${failed_items[@]+"${failed_items[@]}"}; do
      printf "  · %s\n" "$p"
    done
    return 1
  fi

  printf "\n%s%s卸载完成（安装根目录已保留）。%s\n" "$C_GREEN" "$C_BOLD" "$C_RESET"
  if [ "$DO_BACKUP" = "1" ]; then
    printf "%s如需恢复：把备份里的 agents-green.command 拷回任意目录，运行 install 重新安装。%s\n" \
      "$C_DIM" "$C_RESET"
  else
    printf "%s（未备份）如需恢复：重新获取 agents-green.command 后运行 install。%s\n" "$C_DIM" "$C_RESET"
  fi
}

# ---------- 菜单 ----------
menu_pause() {
  printf "\n%s按回车返回菜单...%s" "$C_DIM" "$C_RESET"
  read -r _ 2>/dev/null || true
}

component_menu() {
  local title="$1"
  local choice key
  set_home_paths
  [ -t 1 ] && clear
  ensure_status
  while true; do
    [ -t 1 ] && clear
    printf "\n%s%s────  agents-green  %s  ────%s\n" "$C_BOLD" "$C_CYAN" "$title" "$C_RESET"
    printf "%s位置：%s%s\n" "$C_DIM" "$AGENTS_HOME" "$C_RESET"
    printf "\n"
    print_status
    printf "\n"
    printf "  %s1%s  %s Claude Code\n" "$C_BOLD" "$C_RESET" "$title"
    printf "  %s2%s  %s Codex CLI\n"   "$C_BOLD" "$C_RESET" "$title"
    printf "  %s3%s  %s Pi\n"          "$C_BOLD" "$C_RESET" "$title"
    printf "  %s4%s  %s CodeBuddy\n" "$C_BOLD" "$C_RESET" "$title"
    printf "  %s5%s  %s全部\n"         "$C_BOLD" "$C_RESET" "$title"
    printf "  %sq%s  返回菜单\n\n"     "$C_DIM"  "$C_RESET"
    printf "请选择 [1-5/q]: "
    if ! read -r choice; then
      printf "\n"
      exit 0
    fi
    choice="$(printf '%s' "$choice" | tr -d '[:space:]')"
    case "$choice" in
      1|2|3|4)
        case "$choice" in 1) key=claude ;; 2) key=codex ;; 3) key=pi ;; 4) key=codebuddy ;; esac
        if install_action "$key"; then refresh_after_install "$key"; fi
        FORCE=0; CONFIRMED=0
        menu_pause
        ;;
      5) if install_action all; then refresh_after_install claude codex pi codebuddy; fi
         FORCE=0; CONFIRMED=0; menu_pause ;;
      q|Q|quit|exit) return 0 ;;
      "") ;;
      *)
        printf "%s无效选择：%s（请输入 1-5 或 q）%s\n" "$C_YELLOW" "$choice" "$C_RESET"
        sleep 1
        ;;
    esac
  done
}

uninstall_menu() {
  local choice key
  set_home_paths
  [ -t 1 ] && clear
  ensure_status
  while true; do
    [ -t 1 ] && clear
    printf "\n%s%s────  agents-green  卸载  ────%s\n" "$C_BOLD" "$C_CYAN" "$C_RESET"
    printf "%s位置：%s%s\n" "$C_DIM" "$AGENTS_HOME" "$C_RESET"
    printf "\n"
    print_status
    printf "\n"
    printf "  %s1%s  卸载 Claude Code\n" "$C_BOLD" "$C_RESET"
    printf "  %s2%s  卸载 Codex CLI\n"   "$C_BOLD" "$C_RESET"
    printf "  %s3%s  卸载 Pi\n"          "$C_BOLD" "$C_RESET"
    printf "  %s4%s  卸载 CodeBuddy\n" "$C_BOLD" "$C_RESET"
    printf "  %s5%s  卸载全部（清脚本内容 + 全部入口，保留目录）\n" "$C_BOLD" "$C_RESET"
    printf "  %sq%s  返回菜单\n\n"       "$C_DIM"  "$C_RESET"
    printf "请选择 [1-5/q]: "
    if ! read -r choice; then
      printf "\n"
      exit 0
    fi
    choice="$(printf '%s' "$choice" | tr -d '[:space:]')"
    case "$choice" in
      1|2|3|4)
        case "$choice" in 1) key=claude ;; 2) key=codex ;; 3) key=pi ;; 4) key=codebuddy ;; esac
        uninstall_action "$key"
        refresh_status
        menu_pause
        ;;
      5)
        uninstall_action all
        [ -d "$AGENTS_HOME" ] || exit 0
        refresh_status
        menu_pause
        ;;
      q|Q|quit|exit) return 0 ;;
      "") ;;
      *)
        printf "%s无效选择：%s（请输入 1-5 或 q）%s\n" "$C_YELLOW" "$choice" "$C_RESET"
        sleep 1
        ;;
    esac
  done
}

main_menu() {
  local choice
  set_home_paths
  [ -t 1 ] && clear
  ensure_status
  while true; do
    [ -t 1 ] && clear
    printf "\n%s%s────  agents-green  工具链  ────%s\n" "$C_BOLD" "$C_CYAN" "$C_RESET"
    printf "%s位置：%s%s\n" "$C_DIM" "$AGENTS_HOME" "$C_RESET"
    printf "\n"
    print_status
    printf "\n"
    printf "  %s1%s  安装\n"                        "$C_BOLD" "$C_RESET"
    printf "  %s2%s  更新（Agent/运行时）\n"         "$C_BOLD" "$C_RESET"
    printf "  %s3%s  卸载\n"                        "$C_BOLD" "$C_RESET"
    printf "  %s4%s  设置环境（重建入口/迁移修复）\n" "$C_BOLD" "$C_RESET"
    printf "  %sq%s  退出\n\n"                      "$C_DIM"  "$C_RESET"
    printf "请选择 [1-4/q]: "
    if ! read -r choice; then
      printf "\n"
      exit 0
    fi
    choice="$(printf '%s' "$choice" | tr -d '[:space:]')"
    case "$choice" in
      1) component_menu "安装" ;;
      2) update_action ;;
      3) uninstall_menu ;;
      4) setup_action; menu_pause ;;
      q|Q|quit|exit) exit 0 ;;
      "") ;;
      *)
        printf "%s无效选择：%s（请输入 1-4 或 q）%s\n" "$C_YELLOW" "$choice" "$C_RESET"
        sleep 1
        ;;
    esac
  done
}

# ---------- 入口 ----------
# 只在被直接执行时进入分发；被 source 时只定义函数，便于单测
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  if [ $# -gt 0 ]; then
    ACTION="$1"; shift
    case "$ACTION" in
      install|setup|update|uninstall|menu) ;;
      -h|--help|help) usage; exit 0 ;;
      *) die "未知动作：${ACTION}（可用 install / setup / update / uninstall）" ;;
    esac
  fi
  case "$ACTION" in
    install)
      component="all"
      for arg in "$@"; do
        case "$arg" in
          --force) FORCE=1 ;;
          --latest) printf "  %s! 默认已装最新版，--latest 不再需要%s\n" "$C_YELLOW" "$C_RESET" ;;
          all|claude|codex|pi|codebuddy) component="$arg" ;;
          -h|--help) usage; exit 0 ;;
          *) die "未知参数：${arg}（install 可用 --force / all|claude|codex|pi|codebuddy）" ;;
        esac
      done
      install_action "$component"
      ;;
    setup)
      for arg in "$@"; do
        case "$arg" in
          -h|--help) usage; exit 0 ;;
          *) die "未知参数：${arg}（setup 无额外参数，用 NO_NODE_LINK=1 跳过 node/npm/npx）" ;;
        esac
      done
      setup_action
      ;;
    update) update_action "$@" ;;
    uninstall)
      component="all"
      for arg in "$@"; do
        case "$arg" in
          --dry-run)   DRY=1 ;;
          --no-backup) DO_BACKUP=0 ;;
          --yes|-y)    ASSUME_YES=1 ;;
          all|claude|codex|pi|codebuddy) component="$arg" ;;
          -h|--help)   usage; exit 0 ;;
          *) die "未知参数：${arg}（uninstall 可用 --dry-run / --yes / --no-backup / all|claude|codex|pi|codebuddy）" ;;
        esac
      done
      uninstall_action "$component"
      ;;
    menu) main_menu ;;
  esac
fi
