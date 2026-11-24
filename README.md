# sh

一键安装脚本合集：下载即用，菜单式管理。

| 脚本 | 用途 | 一键安装 |
| --- | --- | --- |
| `cns-install.sh` | cns 服务端（Rust 重写版，v0.4.3） | `curl -kLO https://raw.githubusercontent.com/vvcik/sh/main/cns-install.sh && sudo bash cns-install.sh` |
| `mieru-install.sh` | mieru / mita 服务端（v3.40.0） | `curl -fSsLO https://raw.githubusercontent.com/vvcik/sh/main/mieru-install.sh && sudo bash mieru-install.sh` |

## 说明

- 所有脚本均需 root 运行，运行后进入菜单：安装 / 卸载 / 启动 / 停止 / 重启 / 改配置 / 查配置 / 查状态。
- 首次用 root 跑一次脚本后，即可直接用 `mieru` / `cns` 命令打开管理菜单，不用每次都下载脚本。
- mieru 一键安装（免确认）：`sudo bash mieru-install.sh install --port 2012 --user xxx --password yyy`，三个参数可单独使用，未给出的用默认值（端口 2012、用户 mieru、密码自动生成并只显示一次）；也可以直接用位置参数：`sudo bash mieru-install.sh 2012 xxx yyy`；装好后也可直接用 `mieru install ...` 或 `mieru 2012 xxx yyy`。
- cns 的源码与二进制 Release 仍在 [vvcik/cns](https://github.com/vvcik/cns)，这里只有安装脚本；cns 仓库原 `install.sh` 已改为跳转到这里，老命令继续可用。
- mieru 的服务端程序 `mita` 从上游 [enfein/mieru](https://github.com/enfein/mieru) 的 Release 下载（deb / rpm，amd64 / arm64）。
