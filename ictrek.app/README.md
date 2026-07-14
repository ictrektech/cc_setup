# Agent Room VOS 应用打包说明

本目录包含 VOS app `com.ictrek.agent-room` 的安装包模板。

## 打包

```bash
cd apps/cc_setup/ictrek.app
./scripts/package.sh
```

脚本只生成一个 pull 模式安装包：

```text
dist/agent-room_${VERSION}_pull.tar
```

安装包内只有一个 `docker-compose.yml`，当前包含 `amd` Docker Compose profile。打包脚本会优先读取 `~/.feishu.components.json`，若文件不存在或读取失败则回退到 `~/.feishu.json`，从对应 sheet 读取 `agent-room` 镜像最新版本，并写入包内 `.env`。


## 版本更新与 Release

推荐通过 `ictrek.app/scripts/update_version.sh` 触发版本更新和 GitHub Actions release。脚本只更新 `VERSION`、提交、打 tag 并 push；真正的 pull 包打包、release notes 生成和 tar 上传由 `.github/workflows/vos-release.yml` 完成。

发布前先提交业务代码改动，保持工作区干净，然后运行：

```bash
./scripts/update_version.sh patch
```

可选参数为 `patch`、`minor`、`major`，默认是 `patch`。脚本会生成并推送 `vos-agent-room-v${VERSION}` 形式的 tag。GitHub Actions 收到 tag 后会：

- 使用 tag 中的版本号作为 `PACKAGE_VERSION` 调用 `package.sh`，生成 `dist/agent-room_${VERSION}_pull.tar`。
- 读取 `~/.feishu.components.json` 所需的 GitHub Secrets：`FEISHU_APP_ID`、`FEISHU_APP_SECRET`，可选 `FEISHU_SPREADSHEET_TOKEN`。
- 查找上一个同前缀 VOS release tag，把两个 tag 之间的提交记录写入 release notes。
- 创建 GitHub release 并上传 pull 模式 tar 包。

如果 release tag 已存在，应先确认是否是重发同一版本；不要覆盖未知来源的资产。确需补传同一版本产物时再手动使用 `gh release upload --clobber`。

## 安装

安装时由 VOS 指定目标计算平台 profile：

| profile | 飞书 sheet | 适用平台 |
| --- | --- | --- |
| `amd` | `AMD_with_cuda` | x86_64 / AMD64 类设备 |

示例：

```bash
vos-platform-cli app install-local \
  --temp-dir ./tmp-agent-room-install \
  --admin-password Aa123456 \
  --package-path ./agent-room_${VERSION}_pull.tar \
  --volume app_space \
  -v
```

如需手动验证 Compose 文件，应只启用一个 profile：

```bash
docker compose --profile amd config
```

当前飞书发布表只有 `AMD_with_cuda` sheet 包含 `agent-room` / `agent_room` 组件列，`l4t` 和 `ARM_without_cuda` 没有对应列。因此本次只保留 `amd` profile；arm 镜像发布后再补 `arm` profile。

安装后入口为：

```text
https://<vos-host>:1180/app/com.ictrek.agent-room/
```
