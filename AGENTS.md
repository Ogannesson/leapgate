# Leapgate（跃门）

Leapgate 是基于 [RustDesk](https://github.com/rustdesk/rustdesk) 深度改进的远程桌面，AGPL-3.0。功能和路线图见 `README.md`，设计和取舍的理由见 `docs/architecture.md`。本文件只写在这个仓库里干活要知道的约定。

原工作名 Porta，部分带日期的调研笔记里还是旧名。

## 仓库结构
- 本仓库是总仓库，用子模块挂两个代码仓库：
  - `client/`：`leapgate-client`，RustDesk 的 fork；
  - `server/`：`leapgate-server`，rustdesk-server 的硬分叉。
  - 两者的 `libs/hbb_common` 都指向 `leapgate-cardo`（上游 hbb_common 的 fork），分两条线：`leapgate/server`、`leapgate/client`。
  - 子模块地址是相对路径，检出用 `git clone --recurse-submodules`。
- 各代码仓库自己的实现说明在 `client/LEAPGATE.md`、`server/LEAPGATE.md`。`client/`、`server/` 里上游自带的 `AGENTS.md` 讲上游代码的约定，原样保留。
- `docs/`：
  - `architecture.md`：架构方案；
  - `research/`：调研笔记；
  - 各期实施契约；
  - `新界面/`：新客户端界面的说明和样稿。
- `scripts/`：
  - `windows/`：Windows 客户端构建链；
  - `linux/`：Linux 上的测试脚本；
  - `e2e/`：端到端测试用的端点脚本。
- 维护者本地另有一个不公开的 `internal/` 目录（独立的私有仓库，被 `.git/info/exclude` 排除）。有它时先读 `internal/README.md`；公开仓库不依赖它。

## 构建
- Windows 客户端只能在 Windows 上编：先跑 `scripts/windows/setup-toolchain.ps1` 装工具链，再用 `scripts/windows/build-client.ps1` 编。版本钉在 `scripts/windows/env.ps1`。Flutter 引擎是自编、带补丁的版本，补丁和构建脚本在 `scripts/windows/engine-patches/`、`build-engine.ps1`。
- 新界面在 `client/leapgate_ui/`（core、app 两个包），旧界面是上游的 `client/flutter/`。
- 服务端在 Linux 上用 cargo 编。

## 改上游代码的方式
- 客户端跟随上游正式版本，用 merge 合并，不 rebase；服务端是硬分叉。
- 上游文件里只加薄挂钩，一般一行，前面用 `// leapgate:` 注释说明原因。逻辑放进 Leapgate 自己的模块，如 `libs/leapgate`、`src/leapgate_*`、`client/leapgate_ui/`，这样合并上游时冲突只落在几行上。
- 新界面不改 `client/flutter/`。从上游复制进新界面的文件，按 `client/LEAPGATE.md` 登记来源。
- 要改 hbb_common 的，改在 `leapgate-cardo` 对应的那条线上。

## 公开内容的边界
- 仓库全部公开。只放适合开源的通用内容：方案、调研、代码、构建脚本。
- 不写真实的部署信息：服务器 IP、内部域名、设备 ID、机器配置。
- 测试夹具、示例和文档里的地址：
  - 用文档地址段：192.0.2.0/24、198.51.100.0/24、203.0.113.0/24、2001:db8::/32；
  - 需要"公网地址"语义、文档地址段又会被判成保留地址时，用和项目无关的公网地址（例如 93.184.216.0/24）。
- 提交前用 `git diff --cached` 看一眼。

## 品牌与许可证
- 上游客户端和服务端都是 AGPL-3.0，Leapgate 也是。分发客户端时要同时提供源码。改过的服务端通过网络提供服务时，也要向使用者提供源码（AGPL 第 13 条），仓库公开就满足。
- 分发的构建里不出现 RustDesk 的名字和标志。关于页保留上游版权行，并注明"基于 RustDesk"。

## 上游参考源码
- 本地可以把上游部分克隆在 `upstream/`（`rustdesk`、`rustdesk-server`、`hbb_common` 等）。这个目录已在 `.git/info/exclude` 里排除，不进提交。
- 文档里引用上游代码，写成 `仓库@提交:路径`，再加上函数名。

## 约定
- 不建 `CLAUDE.md`，仓库说明只写在本文件。
- 文档用中文。
- 总仓库 README 分中文 `README.md` 和英文 `README.en.md` 两份，章节、表格、徽章一一对应，改一份就同步改另一份。
  - 只写公开来源能核实的功能和状态。
  - 子模块里的文档用 GitHub 绝对链接，因为相对路径在 GitHub 上进不了子模块。
- 四个公开仓库（`leapgate`、`leapgate-client`、`leapgate-server`、`leapgate-cardo`）的提交说明一律用英文。
- 子模块工作区用 LF：在 Windows 上检出后，在各子模块里设 `core.eol=lf`、`core.autocrlf=false`。原因是 sqlx 迁移文件的校验和按字节算，CRLF 检出编出来的程序会和 Linux 构建的对不上。
- Issues 统一提到 GitHub 上的总仓库 `Ogannesson/leapgate`，三个代码仓库的 Issues 是关闭的。
