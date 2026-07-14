# Agent Room VOS 应用打包说明

本目录包含 VOS app `com.ictrek.agent-room` 的安装包模板。

## 打包

```bash
cd apps/cc_setup/ictrek.app
./scripts/package.sh
```

脚本只生成一个 pull 模式安装包：

```text
dist/agent-room_<version>_pull.tar
```

安装包内只有一个 `docker-compose.yml`，当前包含 `amd` Docker Compose profile。打包脚本会优先读取 `~/.feishu.components.json`，若文件不存在或读取失败则回退到 `~/.feishu.json`，从对应 sheet 读取 `agent-room` 镜像最新版本，并写入包内 `.env`。

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
  --package-path ./agent-room_<version>_pull.tar \
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
