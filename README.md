# tmux-scout

一个用于监控和导航 tmux 中 Claude Code 会话的插件。提供实时状态监控、fzf 弹窗选择器和状态栏小组件。

## 特性

- **会话选择器** — `prefix + v` 打开 fzf 弹窗，显示所有活跃的 Claude Code 会话
- **实时状态** — 显示会话状态标签：`[ WAIT ]` / `[ BUSY ]` / `[ DONE ]` / `[ IDLE ]`
- **代理类型** — 显示代理类型（claude/cursor/copilot）并用颜色区分
- **自动刷新** — `Ctrl-T` 切换每 2 秒自动刷新
- **崩溃检测** — 自动检测并清理已终止的会话
- **状态栏小组件** — 在 tmux 状态栏显示会话计数

## 要求

- tmux >= 3.2
- fzf >= 0.51（支持 `--listen` 和 `--tmux`）
- jq（用于 JSON 处理）

## 安装

### 手动安装

```bash
# 克隆仓库
git clone https://github.com/your-username/tmux-scout.git ~/.tmux/plugins/tmux-scout

# 添加到 ~/.tmux.conf
echo 'run-shell ~/.tmux/plugins/tmux-scout/scout.tmux' >> ~/.tmux.conf

# 重新加载配置
tmux source ~/.tmux.conf
```

### 使用 TPM

```bash
# 在 ~/.tmux.conf 中添加
set -g @plugin 'your-username/tmux-scout'
```

按 `prefix + I` 安装。

## Hook 安装

tmux-scout 需要在 Claude Code 中安装 hooks 来追踪会话状态：

```bash
# 安装 hooks
~/.tmux/plugins/tmux-scout/scripts/setup.sh install

# 其他命令
~/.tmux/plugins/tmux-scout/scripts/setup.sh uninstall  # 卸载 hooks
~/.tmux/plugins/tmux-scout/scripts/setup.sh status     # 检查状态
```

### Hook 事件

安装 hooks 会在 `~/.claude/settings.json` 中添加以下事件的监听：

| 事件 | 触发时机 |
|------|----------|
| `SessionStart` | Claude Code 会话开始 |
| `UserPromptSubmit` | 用户发送消息 |
| `PreToolUse` | 工具执行前 |
| `PostToolUse` | 工具执行后 |
| `Stop` | 会话停止 |
| `SessionEnd` | 会话结束 |

## 使用方法

### 会话选择器

按 `prefix + v` 打开会话选择器弹窗。

| 按键 | 操作 |
|------|------|
| `Enter` | 跳转到选中会话的面板 |
| `Ctrl-R` | 刷新会话列表 |
| `Ctrl-T` | 切换自动刷新（每 2 秒） |
| `Esc` | 关闭选择器 |

### 显示格式

```
* [ BUSY ]  claude  my-project                "implement login page"  Bash: npm test
│ │           │       │                         │                       └─ 当前工具
│ │           │       │                         └─ 会话标题
│ │           │       └─ 项目目录
│ │           └─ 代理类型（claude/cursor/copilot）
│ └─ 状态标签
└─ 当前面板指示器
```

### 代理颜色

| 代理 | 颜色 |
|------|------|
| `claude` | 橙色 |
| `cursor` | 蓝色 |
| `copilot` | 绿色 |
| 其他 | 灰色 |

### 状态说明

| 状态 | 描述 | 颜色 |
|------|------|------|
| `WAIT` | 等待用户确认（如权限请求） | 红色 |
| `BUSY` | 正在处理中 | 黄色 |
| `DONE` | 已完成 | 绿色 |
| `IDLE` | 空闲等待输入 | 蓝色 |

### 状态栏小组件

添加到 `~/.tmux.conf` 以在状态栏显示会话统计：

```bash
set -g status-right '#($SCOUT_DIR/scripts/status-widget.sh) | #S'
set -g status-interval 2
```

显示格式：`W|B|D`（等待数|处理数|完成数）

## 自定义

### 更改快捷键

```bash
# 在 ~/.tmux.conf 中（加载插件后）
set-hook -g pane-mode-changed 'bind-key O run-shell -b "$SCOUT_DIR/scripts/picker.sh"'
```

或直接编辑 `scout.tmux` 中的 `bind-key v` 行。

## 数据存储

```
~/.tmux-scout/
├── status.json          # 聚合的会话索引
└── sessions/            # 每个会话的独立文件
    ├── {session-id}.json
    └── ...
```

- 超过 24 小时的会话会自动清理
- 每个会话文件包含完整的状态历史

## 工作原理

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│   Claude Code   │────▶│    hook.sh      │────▶│  sessions/*.json│
│   (hook event)  │     │  (parse & save) │     │  (session data) │
└─────────────────┘     └─────────────────┘     └─────────────────┘
                                                        │
                        ┌─────────────────┐             │
                        │   picker.sh     │◀────────────┘
                        │  (fzf popup)    │     read & display
                        └─────────────────┘
```

### 状态检测

`sync.sh` 通过以下方式检测会话状态：

1. **PID 检查** — 验证进程是否存活
2. **面板命令** — 检测是否返回到 shell
3. **内容分析** — 从面板输出推断状态：
   - `✻ Thinking` → working
   - `✻ Idle` → completed
   - `Do you want to proceed` → needsAttention

## 故障排除

### 弹窗显示 "No active sessions found"

1. 确认 hooks 已安装：
   ```bash
   ~/.tmux/plugins/tmux-scout/scripts/setup.sh status
   ```

2. 检查 `~/.tmux-scout/status.json` 是否存在且有内容

3. 确认当前有 Claude Code 会话在运行

### Hooks 未生效

1. 检查 `~/.claude/settings.json` 中的 hooks 配置
2. 确认 `hook.sh` 有执行权限
3. 重启 Claude Code 会话

## 许可证

MIT
