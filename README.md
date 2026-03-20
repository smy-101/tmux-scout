# tmux-scout

一个用于监控和导航 tmux 中 Claude Code 会话的插件。提供实时状态监控、fzf 弹窗选择器和状态栏小组件。

## 特性

- **会话选择器** — `prefix + V` 打开 fzf 弹窗，显示所有活跃的 Claude Code 会话
- **实时状态** — 显示会话状态标签：`[ WAIT ]` / `[ BUSY ]` / `[ DONE ]` / `[ IDLE ]`
- **面板预览** — 右侧预览面板显示每个会话的最后 40 行输出
- **自动刷新** — `Ctrl-T` 切换每 2 秒自动刷新
- **崩溃检测** — 自动检测并清理已终止的会话
- **状态栏小组件** — 在 tmux 状态栏显示会话计数

## 要求

- tmux >= 3.2
- fzf >= 0.51（支持 `--listen` 和 `--tmux`）
- jq（用于 JSON 处理）

## 安装

### 使用 TPM

```bash
# 添加到 ~/.tmux.conf
set -g @plugin 'your-username/tmux-scout'
```

按 `prefix + I` 安装。

### 手动安装

```bash
git clone https://github.com/your-username/tmux-scout.git ~/.tmux/plugins/tmux-scout
```

添加到 `~/.tmux.conf`：

```bash
run-shell ~/.tmux/plugins/tmux-scout/scout.tmux
```

重新加载 tmux：

```bash
tmux source ~/.tmux.conf
```

## Hook 安装

tmux-scout 需要在 Claude Code 中安装 hooks 来追踪会话状态：

```bash
# 获取插件目录
eval "$(tmux show-env -g SCOUT_DIR)"

# 安装 hooks
"$SCOUT_DIR/scripts/setup.sh" install

# 其他操作
"$SCOUT_DIR/scripts/setup.sh" uninstall  # 卸载 hooks
"$SCOUT_DIR/scripts/setup.sh" status     # 检查安装状态
```

### 修改的文件

安装 hooks 会修改 `~/.claude/settings.json`，添加以下 6 个事件的 hook：

- `SessionStart` — 会话开始
- `UserPromptSubmit` — 用户提交提示
- `PreToolUse` — 工具使用前
- `PostToolUse` — 工具使用后
- `Stop` — 停止
- `SessionEnd` — 会话结束

## 使用方法

### 选择器

按 `prefix + V`（默认）打开会话选择器。

| 按键 | 操作 |
|------|------|
| `Enter` | 跳转到选中会话的面板 |
| `Ctrl-R` | 刷新会话列表 |
| `Ctrl-T` | 切换自动刷新（每 2 秒） |
| `Esc` | 关闭选择器 |

每行显示：

```
* [ BUSY ] claude  my-project                "implement the login page"  Bash: npm test
```

- `*` — 当前面板指示器
- `[ WAIT ]` / `[ BUSY ]` / `[ DONE ]` / `[ IDLE ]` — 会话状态
- `claude` — 代理类型
- `my-project` — 项目目录名
- `"..."` — 会话标题（第一个提示）
- `Bash: npm test` — 当前工具详情

### 状态栏小组件

状态栏小组件不会自动注入，需要手动添加到配置中：

```bash
# 添加到 ~/.tmux.conf
set -g status-right '#($SCOUT_DIR/scripts/status-widget.sh) #S'
set -g status-interval 2
```

显示格式：`W|B|D`

- `W` = 等待注意（红色）
- `B` = 处理中（黄色）
- `D` = 完成（绿色）

## 配置

### 快捷键

```bash
# 在 ~/.tmux.conf 中自定义快捷键（默认：V）
set -g @scout-key "O"
```

## 数据存储

会话数据存储在 `~/.tmux-scout/` 目录：

```
~/.tmux-scout/
├── status.json          # 聚合的会话索引
└── sessions/            # 每个会话的 JSON 文件
    ├── {session-id}.json
    └── ...
```

超过 24 小时的会话会自动清理。

## 工作原理

### Hook 机制

当 Claude Code 触发事件时，会调用 `hook.sh` 脚本，该脚本：

1. 从 stdin 读取 JSON 数据
2. 解析事件类型和相关信息
3. 更新 `~/.tmux-scout/sessions/{session-id}.json`
4. 同步更新 `~/.tmux-scout/status.json`

### 状态检测

`sync.sh` 脚本负责：

1. 获取所有 tmux 面板的快照
2. 检测崩溃的进程（通过 PID 检查）
3. 检测返回到 shell 的面板
4. 从面板内容推断当前状态

### 状态类型

| 状态 | 描述 | 颜色 |
|------|------|------|
| `WAIT` | 等待用户注意/审批 | 红色 |
| `BUSY` | 正在处理 | 黄色 |
| `DONE` | 已完成 | 绿色 |
| `IDLE` | 空闲 | 蓝色 |

## 许可证

MIT
