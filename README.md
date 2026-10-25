# H69K iStoreOS 24.10 定制固件

基于官方 iStoreOS 24.10 源码，为 HINLINK OPC-H69K 定制构建。

本项目用于个人设备适配与固件定制。欢迎 Fork 后按自己的需求修改。

[![iStoreOS](https://img.shields.io/badge/Base-iStoreOS%2024.10-brightgreen?style=flat-square)](https://github.com/istoreos/istoreos)
[![Platform](https://img.shields.io/badge/Platform-Rockchip%20RK3568-blue?style=flat-square)](https://github.com/istoreos/istoreos)
[![Device](https://img.shields.io/badge/Device-HINLINK%20OPC--H69K-blueviolet?style=flat-square)](https://github.com/istoreos/istoreos)
[![Build](https://img.shields.io/badge/Build-GitHub%20Actions-black?style=flat-square&logo=githubactions)](../../actions)

## 设备与系统信息

| 项目 | 信息 |
| --- | --- |
| 设备型号 | HINLINK OPC-H69K |
| SoC 平台 | Rockchip RK3568 |
| 操作系统 | iStoreOS 24.10 |
| 官方源码 | `istoreos/istoreos` |
| 源码分支 | `istoreos-24.10` |
| 编译目标 | `rockchip/armv8` |
| 设备定义 | `hinlink_opc-h6xk` |
| CPU 架构 | ARM64 / AArch64 |

## 定制功能与软件包

本项目在官方固件基础上，尝试集成以下软件包。

| 软件包 | 用途 | 集成方式 |
| --- | --- | --- |
| 调温大师 `luci-app-fan-h69k` | H69K 风扇控制与温度管理 | 从本仓库内的源码 ZIP 构建 |
| `luci-app-mt5700` | MT5700 模组管理及相关功能 | 从插件仓库获取源码 |
| Docker | 容器运行环境 | 通过 iStoreOS 软件包配置 |
| AdGuard Home LuCI 前端 | AdGuard Home 管理界面及相关脚本 | 从前端插件仓库获取源码 |
| `kmod-hwmon-pwmfan` | PWM 风扇驱动支持 | 通过固件配置选择 |
| `kmod-thermal` | 温控相关内核功能 | 通过固件配置选择 |

**注意：** 上述内容是计划集成的软件包清单，不代表所有功能均已通过编译、刷机和运行测试。AdGuard Home LuCI 前端与核心程序是不同组件，核心程序的下载、安装及启动需要另外验证。

## GitHub Actions 云编译

本项目使用 GitHub Actions 在云端构建固件。

### 手动启动编译

1. 打开本仓库的 `Actions` 页面。
2. 选择 `Build H69K iStoreOS 24.10` 工作流。
3. 点击 `Run workflow`。
4. 等待依赖安装、源码准备、配置检查和编译完成。
5. 打开成功的运行记录，在页面底部的 `Artifacts` 区域下载构建产物。

[进入 Actions 编译页面](../../actions)

### 构建产物

工作流会尝试归档以下文件：

- H69K 固件及相关镜像文件。
- 编译生成的软件包 IPK。
- 构建日志 `build.log`。

只有实际成功生成的文件才会出现在归档中。若编译失败，请优先检查运行记录中的失败步骤和日志。

当前工作流使用 GitHub Actions Artifacts 保存构建产物，保留期限由工作流中的 `retention-days` 设置。它不等同于 GitHub Releases 自动发布。

## 仓库目录说明

```text
.
├── .github/
│   └── workflows/
│       └── build-h69k-istoreos-24.10.yml
├── rk35xx/
│   └── h69k-24.10.config
├── scripts/
│   └── prepare-h69k-24.10.sh
└── luci-app-fan-h69k-build-source-1.3-25.zip
```

目录结构以当前仓库实际内容为准。

### 配置文件

`rk35xx/h69k-24.10.config` 用于指定目标设备和需要集成的软件包。

### 自定义插件准备脚本

`scripts/prepare-h69k-24.10.sh` 负责准备调温大师、MT5700 和 AdGuard Home LuCI 前端源码，并向固件配置追加相应软件包选项。

### 固件构建工作流

`.github/workflows/build-h69k-istoreos-24.10.yml` 负责安装构建依赖、下载官方源码、准备插件、检查配置、编译固件和归档产物。

## 刷机与使用提示

- 刷机前请确认设备型号为 HINLINK OPC-H69K，并核对固件文件名、镜像格式和适用设备。
- 建议在刷机前备份当前系统配置，并保存完整磁盘备份，以便发生启动故障时恢复。
- 不要将其他 RK3568 设备的固件直接刷入 H69K。
- 首次启动后，请检查网络接口、LAN IP、风扇控制、MT5700 模组、Docker 和 AdGuard Home 是否正常工作。
- 固件默认 IP、登录密码和端口设置应以实际构建结果及首次启动配置为准，不应直接假设与其他定制固件一致。

## 免责声明

本项目为个人定制与学习用途。固件功能和兼容性以实际构建、刷机及测试结果为准。

刷写固件存在设备无法启动、配置丢失或数据损坏的风险。请在操作前做好备份，并自行承担刷机和使用风险。

## 致谢

- [iStoreOS 官方项目](https://github.com/istoreos/istoreos)
- [LianXia233/luci-app-mt5700](https://github.com/LianXia233/luci-app-mt5700)
- [rufengsuixing/luci-app-adguardhome](https://github.com/rufengsuixing/luci-app-adguardhome)
- [GitHub Actions](https://github.com/features/actions)

-微信-
# <img src="https://raw.githubusercontent.com/xiaomeng9597/webfiles/refs/heads/main/weixin.jpg" alt="微信收款码" width="200" />
