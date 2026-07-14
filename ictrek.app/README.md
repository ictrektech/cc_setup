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

`./scripts/package.sh` 成功执行后会自动递增 `ictrek.app/VERSION`，并在 `dist/` 下生成 pull 模式 tar 包。生成的 tar 包被 `.gitignore` 忽略，不提交到 git；需要把 `VERSION`、打包脚本、Compose/manifest/router/README 等源码改动提交并推送后，再创建 GitHub release 上传 tar 包。

标准流程：

```bash
cd apps/cc_setup/ictrek.app
./scripts/package.sh

# 确认 VERSION 中的新版本号，例如 0.1.2
VERSION=$(cat VERSION)

# 在对应仓库提交并推送源码改动后发布 pull 包
gh release create vos-agent-room-v${VERSION} dist/agent-room_${VERSION}_pull.tar \
  --repo ictrektech/cc_setup \
  --target main \
  --title "VOS agent-room $VERSION" \
  --notes "Pull-mode VOS app package for this release."
```

如果 release tag 已存在，应先确认是否是重发同一版本；不要覆盖未知来源的资产。确需补传同一版本产物时使用：

```bash
gh release upload vos-agent-room-v${VERSION} dist/agent-room_${VERSION}_pull.tar --repo ictrektech/cc_setup --clobber
```

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
