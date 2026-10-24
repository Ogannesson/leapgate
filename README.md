# Leapgate

[English](#english) | [中文](#中文)

## English

Leapgate is a remote desktop built on [RustDesk](https://github.com/rustdesk/rustdesk). It keeps RustDesk's engine (screen capture, codecs, input, transport) and reworks the server and the connection path around it. The name is *leap* + *gate*; the Chinese name is 跃门.

Leapgate is in early development. There is no release and no installer to download. The first stage targets Windows 10 and later only, for both the controlling and the controlled side. It is not ready for production use. The design documents and implementation notes are currently written in Chinese only.

### What it adds to open-source RustDesk

Implemented:

- A server with its own HTTP API for login, address books (personal and shared, with user groups and permissions), the device list and audit logs. The third-party rustdesk-api is no longer needed.
- Relay selection across several relays. The server estimates latency from GeoIP and ASN data, and Leapgate clients measure their connection time to each relay and report it; measurements take precedence over estimates. Open-source hbbs rotates through its relays round-robin without looking at either side's location, and the client's relay setting takes a single address.
- Direct LAN connections while a TUN-mode proxy is running on either side. The controlled side reports the addresses of its physical network adapters and the controlling side tries them in parallel. This applies when both ends reach the server from the same public address (the proxy sends rendezvous traffic out directly rather than through a remote exit) and both ends run Leapgate. End-to-end testing of this feature is not finished.
- Signed device reports. Leapgate clients sign heartbeat, system-info and audit requests with the device key, the server pins that key on first use, and the server signs its responses.
- TCP key exchange on the rendezvous port and forwarding of IPv6 hole-punching addresses, both missing from the open-source hbbs.

Planned, not implemented:

- Exit Node: using a controlled device as an application-level exit (SOCKS5 and HTTP CONNECT, TCP only).
- A redesigned client UI.
- Leapgate's own ICE-style NAT traversal (currently being designed).

### Repository layout

| Path | Repository | Contents |
|---|---|---|
| `client/` | [leapgate-client](https://github.com/Ogannesson/leapgate-client) | Fork of rustdesk/rustdesk |
| `server/` | [leapgate-server](https://github.com/Ogannesson/leapgate-server) | Hard fork of rustdesk/rustdesk-server |
| `client/libs/hbb_common`, `server/libs/hbb_common` | [leapgate-cardo](https://github.com/Ogannesson/leapgate-cardo) | Fork of rustdesk/hbb_common |
| `docs/` | this repository | Architecture, research notes, implementation contracts |
| `scripts/windows/` | this repository | Windows client build scripts |

### Documentation

The overall design is in `docs/architecture.md`, and the research behind it is under `docs/research/`. leapgate-server and leapgate-client each have a `LEAPGATE.md` describing their changes. All of these are in Chinese.

### Getting the source

```
git clone --recurse-submodules https://github.com/Ogannesson/leapgate.git
```

### License and credits

Leapgate is licensed under AGPL-3.0, inherited from rustdesk/rustdesk and rustdesk/rustdesk-server. It is derived from [rustdesk/rustdesk](https://github.com/rustdesk/rustdesk), [rustdesk/rustdesk-server](https://github.com/rustdesk/rustdesk-server) and [rustdesk/hbb_common](https://github.com/rustdesk/hbb_common), and thanks their authors. Leapgate is not affiliated with or endorsed by the RustDesk project; the RustDesk name belongs to its owners.

## 中文

Leapgate（跃门）是基于 [RustDesk](https://github.com/rustdesk/rustdesk) 改进的远程桌面。它沿用 RustDesk 的引擎（抓屏、编解码、输入、传输），重做服务端和连接路径。名字取 leap（一跃）加 gate（门）。

项目处在早期开发阶段，还没有发布，没有可下载的安装包。第一阶段只支持 Windows 10 及以上，控制端和被控端都是。不建议用于生产环境。设计文档和实施说明目前只有中文。

### 相对开源版 RustDesk 补了什么

已实现：

- 服务端自带 HTTP API，提供登录、地址簿（个人簿和共享簿，支持用户组和权限）、设备列表和审计日志，不再需要第三方的 rustdesk-api。
- 在多台中继之间选路。服务端用 GeoIP 和 ASN 数据估算延迟，Leapgate 客户端实测到各中继的建连耗时并上报，有实测时优先用实测。开源版 hbbs 在多台中继之间只做轮询、不看两端在哪，客户端的中继设置也只能填一个地址。
- 任一端开着 TUN 模式的代理时也能局域网直连。被控端上报自己物理网卡的地址，控制端并发尝试。前提是两端到服务端的公网地址相同（代理对会合服务器的流量走直连、不经远端出口），且两端都是 Leapgate 客户端。这项功能的端到端测试还没做完。
- 设备签名上报。Leapgate 客户端用设备私钥给心跳、系统信息和审计请求签名，服务端首次验签通过后锁定这把公钥，并给自己的响应签名。
- 会合端口上的 TCP 密钥交换和 IPv6 打洞地址转发，这两项开源版 hbbs 都没有。

计划中，尚未实现：

- Exit Node：把被控端当作应用层出口（SOCKS5 和 HTTP CONNECT，只支持 TCP）。
- 重新设计的客户端界面。
- Leapgate 自研的 ICE 式 NAT 穿透（正在设计）。

### 仓库结构

`client/` 是子模块 [leapgate-client](https://github.com/Ogannesson/leapgate-client)，即 rustdesk/rustdesk 的 fork。`server/` 是子模块 [leapgate-server](https://github.com/Ogannesson/leapgate-server)，即 rustdesk/rustdesk-server 的硬分叉。两者的 `libs/hbb_common` 都是 [leapgate-cardo](https://github.com/Ogannesson/leapgate-cardo)，即 rustdesk/hbb_common 的 fork。本仓库自己放 `docs/`（架构方案、调研笔记、实施契约）和 `scripts/windows/`（Windows 客户端构建脚本）。

### 文档

总体方案在 `docs/architecture.md`，调研依据在 `docs/research/`。leapgate-server 和 leapgate-client 各有一份 `LEAPGATE.md` 说明自己的改动。以上文档都是中文。

### 获取源码

```
git clone --recurse-submodules https://github.com/Ogannesson/leapgate.git
```

### 许可证与致谢

Leapgate 采用 AGPL-3.0，继承自 rustdesk/rustdesk 和 rustdesk/rustdesk-server。它衍生自 [rustdesk/rustdesk](https://github.com/rustdesk/rustdesk)、[rustdesk/rustdesk-server](https://github.com/rustdesk/rustdesk-server) 和 [rustdesk/hbb_common](https://github.com/rustdesk/hbb_common)，感谢上游作者。Leapgate 与 RustDesk 项目没有关联，也未获其认可；RustDesk 这个名字归其所有者。
