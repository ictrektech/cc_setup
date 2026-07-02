# cc_setup VOS 应用目录

本目录用于维护 `cc_setup` 的 VOS 应用定义、打包脚本和安装说明。

当前 `cc_setup` 主要是 Claude、Codex、RTK、skills 和 digital-workers 的安装脚本集合，还没有固定的 VOS 运行时服务、Compose 编排或前端入口。因此本目录先作为 VOS 应用交付入口保留；后续确定应用 ID、服务形态、配置项和路由后，再补齐 `src/`、`scripts/package.sh` 和应用商店说明。

生成的安装包、临时目录和 tar 文件不应提交，见本目录 `.gitignore`。

# cc_setup VOS App Directory

This directory is the entry point for future VOS app metadata, packaging scripts, and installation notes for `cc_setup`.

`cc_setup` is currently a script collection for Claude, Codex, RTK, skills, and digital-workers. It does not yet define a stable VOS runtime service, Compose stack, or frontend route. Keep this directory as the packaging entry point first; add `src/`, `scripts/package.sh`, and app-store documentation after the app ID, services, configuration, and routes are fixed.

Generated packages, temporary directories, and tar files should not be committed; see `.gitignore` in this directory.
