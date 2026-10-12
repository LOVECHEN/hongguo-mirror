# 红果镜像仓(hongguo-mirror)

本仓库是【红果短剧】项目的**自动镜像**,由 GitHub Actions 每 6 小时同步一次,上游一有新提交 / 新发布最多 6 小时内跟上。

## 镜像了什么

| 内容 | 上游 | 本仓位置 |
| --- | --- | --- |
| Android TV 客户端源码 | [N3urda/hongguoTV](https://github.com/N3urda/hongguoTV) | [`sources/hongguoTV/`](sources/hongguoTV/) |
| 桌面/发布仓文档与素材 | [waligoraamodio288-rgb/hongguo-desktop-releases](https://github.com/waligoraamodio288-rgb/hongguo-desktop-releases) | [`sources/hongguo-desktop-releases/`](sources/hongguo-desktop-releases/) |
| Windows 安装包 / TV APK 等二进制 | 上述发布仓的 GitHub Releases | 本仓 **[Releases](../../releases)** |

- **源码**:每次同步取上游默认分支的最新快照覆盖到 `sources/`(仅最新状态,不含上游 git 历史)。每个子目录下的 `.mirror-upstream` 记录该快照对应的上游 commit。
- **二进制**:上游每个 release(含预发布)的资产原样镜像成本仓同名 tag 的 release;已镜像且资产齐全的自动跳过。二进制只在 Actions runner 上临时流转,不占用任何人的本地磁盘。

各源码快照对应的上游 commit 见 [`MIRROR_STATE.md`](MIRROR_STATE.md);每次运行的时间见 [Actions 运行记录](../../actions/workflows/sync.yml)。

## 自持(keepalive)

GitHub 会在仓库**连续 60 天无活动**后自动停用定时(cron)工作流。为避免镜像在上游长期不更新时被悄悄停掉,`sync.sh` 内置心跳:距上次提交 ≥ 50 天就推一个心跳提交(写 `.keepalive` 时间戳),把 60 天计时器重置。只要工作流还在每 6 小时跑,就永远不会触及阈值 —— **自己养活自己**。

> 可选增强:有说法认为由内置 `GITHUB_TOKEN`(github-actions[bot])产生的提交不一定能重置 60 天计时器。若想 100% 保证,在仓库 **Settings → Secrets and variables → Actions** 新增一个 secret `KEEPALIVE_PAT`(值为一枚 fine-grained PAT,仅对本仓授予 `contents: write`)。工作流会优先用它推送,使提交以你本人身份算作仓库活动;不配置则回退到 `GITHUB_TOKEN`,通常也够用。

## 手动触发同步

GitHub 页面:**Actions → mirror-sync → Run workflow**。

本地运行(需已 `gh auth login` 且装有 `jq` / `rsync`):

```bash
MIRROR_REPO=LOVECHEN/hongguo-mirror bash sync.sh
```

## 说明

- 本仓仅作备份/镜像用途;源码与二进制版权归上游项目所有,`sources/` 内保留了上游各自的 LICENSE 与声明文件。
- `sources/hongguoTV/.github/workflows/` 内的工作流嵌套在子目录中,**不会**被本仓 GitHub Actions 执行;本仓只运行 `.github/workflows/sync.yml` 这一个工作流。
