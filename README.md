# skills-hub

Qianshou 的 coding agent skill 集合。收录的 skill 统一带 `qianshou-` 前缀，避免和用户已有的同名 skill 冲突。

## 包含的 skill

| Skill | 作用 | 来源 |
| --- | --- | --- |
| `qianshou-code-review` | 双轴代码评审：**Standards**（是否符合本仓库的编码规范）和 **Spec**（是否忠实实现了原始的 issue / 需求）。两个轴作为并行子 agent 跑，互不污染上下文，最后并排汇总。 | [mattpocock/skills](https://github.com/mattpocock/skills/tree/main/skills/engineering/code-review) |
| `qianshou-security-best-practices` | 按语言和框架做安全最佳实践评审。覆盖 Python（Django / Flask / FastAPI）、JavaScript / TypeScript（React / Vue / Next.js / Express / jQuery）和 Go，每种栈一份独立的 reference 文档。 | [openai/skills](https://github.com/openai/skills/tree/main/skills/.curated/security-best-practices) |
| `qianshou-i-have-adhd` | 把输出重排成 ADHD 友好的形式：先给下一步动作、多步任务编号、每轮复述进度、砍掉寒暄和废话。会话内持续生效，直到你说 "stop adhd mode"。 | [ayghri/i-have-adhd](https://github.com/ayghri/i-have-adhd) |

## 安装

`install.sh` 会把上面三个 skill 装到你的 coding agent 目录，默认是 `~/.cursor/skills`、`~/.claude/skills`、`~/.codex/skills`。

```bash
curl -fsSL https://raw.githubusercontent.com/Qianshou-Operations/skills-hub/main/install.sh | bash
```

### 安装逻辑

对每个 agent 根目录（比如 `~/.cursor`）：

| 情况 | 行为 |
| --- | --- |
| 根目录不存在 | 跳过 —— 说明你没装这个 agent，不创建多余目录 |
| 根目录存在，没有 `skills/` | 创建 `skills/` 后安装 |
| `skills/` 已存在 | 直接装进去 |
| 目标 skill 已存在 | 跳过，不覆盖；`--force` 才替换 |

文件从 `raw.githubusercontent.com` 下载，先落到临时目录，**全部文件下载并校验通过后**才会写入目标目录，所以下载中途失败不会留下半成品。下载并发 4 路，单文件失败会以 2s、4s 退避重试 3 次。

### 参数

```bash
./install.sh                       # 安装（默认模式）
./install.sh --list                # 列出仓库里的 skill
./install.sh --verify              # 校验已装内容与安装时记录是否一致
./install.sh --uninstall           # 卸载

-t, --target DIR   指定 agent 根目录，可重复
    --ref REF      分支或 tag，默认 main
    --local        从本地 ./skills 装，不走网络（开发用）
    --force        覆盖已安装的
    --no-backup    配合 --force，直接删除而不是备份
    --dry-run      只打印将要做什么，不写任何东西
-j, --jobs N       并发下载数，默认 4
    --retries N    单文件重试次数，默认 3
    --timeout N    连接超时秒数，默认 10
-q, --quiet        只输出警告和错误
-v, --verbose      额外打印每个下载的文件
-h, --help
```

### 覆盖与备份

`--force` 不会直接删掉旧目录，而是先把它移到 `<agent 根>/skills/.qianshou-backups/<时间戳>/`，同一轮覆盖的 skill 共用一个时间戳目录。你自己在 skill 目录里加的笔记、改动都留在备份里。不想要备份就加 `--no-backup`。

### 校验

安装时会为每个 skill 算一个内容摘要，记在 `<agent 根>/skills/.qianshou-skills.stamp`。`--verify` 重新计算当前内容并比对：

```
[ok]     qianshou-code-review matches its main install
[warn]   qianshou-security-best-practices has local modifications (digest differs)
[fail]   qianshou-i-have-adhd is incomplete — agents/gemini.toml is gone
```

`.qianshou-skills.stamp` 和 `.qianshou-backups/` 都以 `.` 开头，不会被 agent 当成 skill 加载。

### 手动安装

不想跑脚本的话，把 `skills/` 下任意一个目录整个拷到 `<agent 根目录>/skills/` 即可，`SKILL.md` 必须保留在该目录顶层。

## 目录结构

```
.
├── install.sh
└── skills/
    ├── qianshou-code-review/
    │   ├── SKILL.md
    │   └── agents/openai.yaml
    ├── qianshou-i-have-adhd/
    │   ├── SKILL.md
    │   └── agents/{openai.yaml,gemini.toml}
    └── qianshou-security-best-practices/
        ├── SKILL.md
        ├── LICENSE.txt
        ├── agents/openai.yaml
        └── references/            # 按语言/框架划分的安全文档
```

`agents/` 下是各平台的适配配置（OpenAI / Gemini），只面向 Claude Code 使用的话可以忽略或删除。

## 二次开发

新增 skill 或往 skill 里加文件时，需要同步更新 `install.sh` 顶部的 `MANIFEST` —— 它是手写的文件清单，脚本按它逐文件下载。漏加会导致安装时缺文件。

脚本要求 bash 3.2+（macOS 自带版本）和 `curl`，刻意没有使用 `mapfile`、关联数组、`${var,,}`、nameref 这些 bash 4+ 特性，保证在干净的 macOS 上直接可跑。

## 来源与许可

以上 skill 均来自第三方开源仓库，各自的著作权归原作者所有：

- `code-review` — mattpocock/skills
- `security-best-practices` — openai/skills（`LICENSE.txt` 随 skill 一并保留）
- `i-have-adhd` — ayghri/i-have-adhd（MIT）

本仓库只做重命名和前缀命名空间化，不改动 skill 的行为逻辑，迁移时也没有保留上游的 git 历史。

`qianshou-code-review` 原版依赖 mattpocock 生态的 `/setup-matt-pocock-skills` 来配置 issue tracker。这里改成了自包含逻辑：仓库里有 `docs/agents/issue-tracker.md` 就用，没有就跳过 issue tracker 查询、走其他 spec 来源，不阻塞评审流程。
