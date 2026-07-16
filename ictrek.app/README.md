# Agent Room VOS 应用打包说明

本目录包含 VOS app `com.ictrek.agent-room` 的安装包模板。
发布流程以 `update_version.sh` 触发的 GitHub Actions 为准。

## 打包

正式发布不要在本地读取飞书并打包。发布入口是 `scripts/update_version.sh`：它只更新 `VERSION`、提交 release commit、推送 `vos-agent-room-v${VERSION}` 触发 tag；GitHub Actions 收到 tag 后才会读取飞书组件版本、生成 pull 包并更新 GitHub release。

本地 `package.sh` 只用于调试模板或手动验证。它不会递增或写回 `VERSION`；未设置 `PACKAGE_VERSION` 时读取当前 `ictrek.app/VERSION`，CI 会显式传入 tag 中解析出的 `PACKAGE_VERSION`。

```bash
cd apps/cc_setup/ictrek.app
./scripts/package.sh
```

脚本只生成一个 pull 模式安装包：

```text
dist/agent-room_${VERSION}_pull.tar
```

安装包内只有一个 `docker-compose.yml`，其中包含 `arm` 和 `amd` 两个 Docker Compose profile。打包脚本会优先读取 `~/.feishu.components.json`，若文件不存在或读取失败则回退到 `~/.feishu.json`，从对应 sheet 读取 `agent-room` 镜像最新版本，并写入包内 `.env`。

`agent-room` 镜像由仓库根目录执行 `./docker/build_images.sh <profile>` 构建、推送并写入飞书发布表：

```bash
./docker/build_images.sh amd
./docker/build_images.sh arm
```

默认写表范围：

- `amd` 写入 `AMD_with_cuda`、`AMD_with_mxn100`
- `arm` 写入 `l4t`、`ARM_without_cuda`、`ARM_with_cuda`、`thor_spark`、`SOPHON_bm1688`

写表时只查找精确表头 `agent-room`。若该列不存在，脚本只在最后一个非空表头/仓库列后新增一列，并写入表头和镜像仓库地址，避免重复扩出空列。


## 版本更新与 Release

推荐通过 `ictrek.app/scripts/update_version.sh` 触发版本更新和 GitHub Actions release。脚本只更新 `VERSION`、提交、打 tag 并 push；真正的 pull 包打包、release notes 生成和 tar 上传由 `.github/workflows/vos-release.yml` 完成。

发布前先提交业务代码改动，保持工作区干净，然后运行：

```bash
./scripts/update_version.sh patch
```

可选参数为 `patch`、`minor`、`major`，默认是 `patch`。脚本会生成并推送 `vos-agent-room-v${VERSION}` 形式的 CI 触发 tag。GitHub Actions 收到 tag 后会：

- 使用 tag 中的版本号作为 `PACKAGE_VERSION` 调用 `package.sh`，生成 `dist/agent-room_${VERSION}_pull.tar`。
- 读取 `~/.feishu.components.json` 所需的 GitHub Secrets：`FEISHU_APP_ID`、`FEISHU_APP_SECRET`，可选 `FEISHU_SPREADSHEET_TOKEN`。
- 在 CI 中通过飞书发布表读取 `agent-room` 最新镜像 tag；当前不读取其他 VOS app release，因此不需要 `VOS_DEPENDENCY_RELEASE_TOKEN`。
- 查找上一个 VOS release tag，把两个 tag 之间的提交记录写入 release notes。
- 创建标准 SemVer GitHub release tag `v${VERSION}`，标题使用 `v${VERSION}`，并上传 pull 模式 tar 包。`vos-agent-room-v${VERSION}` 只用于触发 CI，不作为公开 release tag。

如果 release tag 已存在，应先确认是否是重发同一版本；不要覆盖未知来源的资产。确需补传同一版本产物时再手动使用 `gh release upload --clobber`。

## 安装

安装时由 VOS 指定目标计算平台 profile：

| profile | 飞书 sheet | 适用平台 |
| --- | --- | --- |
| `arm` | `ARM_with_cuda` | ARM / L4T 类设备 |
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
docker compose --profile arm config
```

安装表单可配置 `AGENT_ROOM_DATA_PATH`、`AGENT_ROOM_CONFIG_PATH` 和 `AGENT_ROOM_WORKSPACE_PATH`。默认分别使用宿主机 `/data/vos_workspace/agentroom/data`、`/data/vos_workspace/agentroom/config` 和 `/data/vos_workspace/agentroom/workspace`；需要把会话数据、登录配置或 Agent 工作区放到其他磁盘时，直接在安装 UI 中填写宿主机绝对路径。

安装后入口为：

```text
https://<vos-host>:1180/app/com.ictrek.agent-room/
```

`routers.yml` 使用完整的 group/page 结构。页面入口必须写 `entry-point: true`，同域嵌入页面必须保留 `keep-alive: true` 和 `embed: true`。Agent Room 的固定入口契约是：

- `app id`: `com.ictrek.agent-room`
- `group.id`: `com-ictrek-agent-room`
- `page.id`: `dashboard`
- `iframe-src`: `/app/com.ictrek.agent-room/?v=20260716`
- VOS 内部侧边栏路径：`#/app/com.ictrek.agent-room/com-ictrek-agent-room/dashboard`

`scripts/package.sh` 会在生成 `app.tar.gz` 后校验以上字段；不匹配时直接失败。新增或修改入口时必须同步更新模板和脚本校验值。`group.id` 使用 `com-ictrek-agent-room`，避免动态路由合并时和其他应用或平台内置分组冲突。
