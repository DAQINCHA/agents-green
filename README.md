# agents-green

`~/.agents` 工具链的唯一入口：在一个自包含目录里装好 **Claude Code / Codex CLI / Pi / CodeBuddy / agy（Google Antigravity CLI）** 五个命令行 AI，
连同要用的便携 Node 运行时（agy 是独立二进制，不需要 Node），再把 `claude`、`codex`、`pi`、`codebuddy`（CodeBuddy 另带短名 `cbc`）、`agy`、以及 `node`、`npm`、`npx` 暴露成普通命令。

一个 shell 脚本，零第三方依赖，只写 `AGENTS_HOME` 内部和入口目录，不碰系统自带的 node/npm。

## 它解决什么问题

macOS 上同时用几个 AI CLI 时，常见麻烦是：Node 版本互相打架、`npm install -g` 污染全局、
换机或迁移后命令入口全部失效。这里把整套东西收进一个目录：

```
~/.agents/                      ← AGENTS_HOME
├── .dependencies/
│   ├── node/bin/node           # 便携 Node，不动系统的
│   ├── npm/                    # 便携 npm
│   └── .npm-cache/             # npm 缓存也锁在这里
├── claude/node_modules/.bin/claude
├── codex/node_modules/.bin/codex
├── pi/node_modules/.bin/pi
├── codebuddy/node_modules/.bin/codebuddy
└── agy/
    ├── agy                     # 独立 Go 二进制（解包后的 antigravity 改名而来）
    └── .version                # 安装时记下的版本号，离线也能显示当前版本
```

登录态不在这个目录里：`~/.claude`、`~/.codex`、`~/.pi`、`~/.codebuddy`，以及 agy 的系统钥匙串和 `~/.gemini/antigravity-cli`。所以删掉 `~/.agents` 重装，登录状态仍然在。

## 用法

双击运行进入交互菜单（安装 / 更新 / 卸载 / 设置环境），或者走命令行：

```bash
./agents-green.command                                  # 交互菜单
./agents-green.command install                          # 装全部（Node + 五个 AI）
./agents-green.command install --force claude           # 只覆盖重装 Claude Code
./agents-green.command install --force codebuddy        # 只覆盖重装 CodeBuddy
./agents-green.command install --force agy              # 只覆盖重装 agy（Antigravity）
./agents-green.command setup                            # 迁移后修复 / 重建命令入口
./agents-green.command update                           # 交互式更新菜单
./agents-green.command update 1                         # 只更新 Claude Code（1-5 依次为 Claude / Codex / Pi / CodeBuddy / agy）
./agents-green.command update 5                         # 只更新 agy
./agents-green.command update all                       # 更新五个 AI
./agents-green.command update runtime                   # 只更新 Node / npm（等价 update 7）
./agents-green.command update check                     # 只看版本状态，不更新
./agents-green.command uninstall --dry-run all          # 预览卸载会删什么
./agents-green.command uninstall --dry-run agy          # 只预览卸载 agy 会删什么
./agents-green.command uninstall all                    # 卸载（会先备份）
```

`--help` 打印的就是脚本头部的注释块，和源码始终同步。

## 动作说明

| 动作 | 做什么 |
|---|---|
| `install [--force] [all\|claude\|codex\|pi\|codebuddy\|agy]` | 下载便携 Node + npm，装五个 AI，建命令入口，最后在「模拟无 node 的干净环境」里实测每个命令能否运行 |
| `setup` | 不下载任何东西，只检查架构、清 quarantine、按本机实际装了的组件重建入口。用于目录迁移、换机 rsync 之后 |
| `update [1-7\|all\|check\|runtime]` | 1-5 是五个 AI，6 是全部，7 是运行时（同 `runtime`）；四个 Node CLI 逐个 `npm install @latest`，agy 走 manifest + sha512；`runtime` 单独升 Node/npm，带下载→验证→替换→失败回滚的完整流程 |
| `uninstall [--dry-run\|--yes\|--no-backup] [all\|claude\|codex\|pi\|codebuddy\|agy]` | 只删脚本自己生成的文件和入口，保留 `AGENTS_HOME` 目录本身及其他内容 |

几个刻意的设计：

- **入口不认人**：`/opt/homebrew/bin` 里已有的同名文件若不是本脚本写的，一律先备份成 `.bak`（已有 `.bak` 就加时间戳），绝不静默覆盖。
- **一个包的多个命令名全部转发**：CodeBuddy 的包声明了 `codebuddy`、`cbc`、`codebuddy-code`、`cbc-prewarm`、`codebuddy-lowmem`，这里转发常用的 `codebuddy` 和 `cbc`。清单只在脚本的 `entry_names()` 里写一份，安装、卸载、校验共用，所以卸载不会留下孤儿入口。要加别的短名改那一处即可。
- **CodeBuddy 的自动更新被固定关掉**：它自带自动更新，会绕过这里的版本管理；入口里写死了 `DISABLE_AUTOUPDATER=1`（`cbc` 入口同样带这行），升版本一律走 `update`。想放开就自己改入口，重跑 `setup` 会再被关掉。
- **agy 完全收编**：独立 Go 二进制（约 15 MB，不依赖 Node），入口直接 `exec` 它，不带 Node 路径。下载走 manifest 里**原样**的 `url` 字段（路径是 `darwin-arm`，自己拼成 `darwin-arm64` 会 404），用 `sha512` 校验通过才解包，把里面的 `antigravity` 改名成 `agy`；版本记在 `$AGENTS_HOME/agy/.version`，离线也能显示。它的自动更新也被入口写死 `AGY_CLI_DISABLE_AUTO_UPDATE=true` 关掉，升级统一走 `update`。
- **卸载默认先备份**：把 `README.md`、`agents-green.command`、四个 `package.json` / `package-lock.json` 和 `agy/.version` 打包到 `AGENTS_HOME/.backups/`；备份失败就停止卸载，不动任何东西。确实不要备份时必须显式写 `--no-backup`。
- **运行时更新可回滚**：先下载并验证新版本，再一次性替换；任何一步失败都恢复原 Node/npm，备份留在临时目录里不自动删。
- **卸载只删自己的东西**：`claude/`、`codex/`、`pi/`、`codebuddy/` 目录里只清 `node_modules`、`package.json`、锁文件；`agy/` 里只清 `agy` 和 `.version`。你自己放进去的文件会让对应目录被保留。

## 环境变量

| 变量 | 作用 | 默认 |
|---|---|---|
| `AGENTS_HOME` | 安装根目录，任意可写绝对路径 | `~/.agents` |
| `NODE_VER` / `NPM_VER` | 指定 Node / npm 版本 | 自动取最新 LTS / latest |
| `CLAUDE_VER` / `CODEX_VER` / `PI_VER` / `CODEBUDDY_VER` | 指定四个 Node AI 的版本 | `latest` |
| `AGY_VER` | 指定 agy 版本；只接受 `latest` 或留空（manifest 只给最新版，旧版没有可靠下载地址） | `latest` |
| `SKIP_AGENTS=1` | `install` 只装 Node/npm 运行时 | — |
| `SKIP_LINKS=1` | `install` 不建命令入口 | — |
| `NO_NODE_LINK=1` | `setup` 不暴露 `node`/`npm`/`npx` | — |
| `AGENTS_BIN_DIR` | 指定入口目录，跳过自动探测（测试用） | 自动挑 `/opt/homebrew/bin` 等 |

## 限制与注意

- **只支持 Apple Silicon**：下载的是 `darwin-arm64` 二进制，Intel Mac 会在第一步架构检查时退出。
- **要联网**：nodejs.org 与 registry.npmjs.org 都要能访问（装另外四个 AI 和运行时）；装 agy 还需要 `storage.googleapis.com` 和 `antigravity-cli-auto-updater-*.run.app` 可达。首次装全部约 1 GB。本机网络里 `antigravity.google` 域名不通，所以**不走**官方 `curl .../install.sh | bash` 这条路线；下载一律用 manifest 返回的 URL 原样地址，并做 `sha512` 校验。
- **agy 不依赖 Node**：它是个独立 Go 二进制（约 15 MB），不是 npm 包（npm 上的同名包是空壳占位），因此不能 `npm install`；脚本直接 `exec`，不用便携 Node。
- **agy 的版本与更新**：版本以 `$AGENTS_HOME/agy/.version` 为准（离线也能显示），最新版本号从 manifest 解析；升级走「拉 manifest → 下载 → 校验 sha512 → 备份旧二进制 → 替换 → 失败回滚」，不碰 npm。`AGY_VER` 只接受 `latest` 或留空，因为 manifest 只提供最新版。它的自动更新被脚本写死关掉，升级统一用 `update`。
- **agy 的登录态**：在系统钥匙串和 `~/.gemini/antigravity-cli/`，不在 `AGENTS_HOME` 内，卸载不会动它们。
- **CodeBuddy 要 Node 18.20 以上**：它本身就是个 Node 程序，全靠目录里的便携 Node 拉起，不需要系统装 Node。它的包比较大（解压后 200 MB 上下），安装包自身没有安装脚本，所以不像 Claude Code 那样需要 `allowScripts`。
- 入口目录优先 `/opt/homebrew/bin`，其次 `/usr/local/bin`，最后 `~/.local/bin`。落在 `~/.local/bin` 时 GUI 应用（如 Magpie）通常扫不到，脚本会提示。
- 首次运行 `claude` / `codex` / `pi` / `codebuddy` / `agy` 会引导登录。

## 本文件在哪

这份是**仓库里的源**，不是运行必需的位置——脚本用 `$0` 定位自身，`setup` 会在脚本所在目录和 `~/.agents` 之间自动识别安装根，
所以放在任意目录都能跑。真正跑起来的机器上，可以只在需要时从这里取一份。
