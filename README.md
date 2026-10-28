# H69K iStoreOS 定制固件

基于官方 [iStoreOS](https://github.com/istoreos/istoreos) 源码，为 **HINLINK OPC-H69K** 定制构建固件。

本项目维护两个固件版本：

- **iStoreOS 24.10**：原有稳定构建分支，保留现有配置与编译流程。
- **iStoreOS 25.12**：独立开发与适配分支，用于新版本源码、软件包和功能兼容性测试。

项目主要用于个人设备适配、固件定制与功能测试。欢迎 Fork 本仓库，根据自己的设备和使用需求进行修改。

[![iStoreOS](https://img.shields.io/badge/Base-iStoreOS%2024.10%20%7C%2025.12-brightgreen?style=flat-square)](https://github.com/istoreos/istoreos)
[![Platform](https://img.shields.io/badge/Platform-Rockchip%20RK3568-blue?style=flat-square)](https://github.com/istoreos/istoreos)
[![Device](https://img.shields.io/badge/Device-HINLINK%20OPC--H69K-blueviolet?style=flat-square)](https://github.com/istoreos/istoreos)
[![Build](https://img.shields.io/badge/Build-GitHub%20Actions-black?style=flat-square&logo=githubactions)](../../actions)

---
<img width="2540" height="1094" alt="image" src="https://github.com/user-attachments/assets/471abc6d-34f1-4d49-9095-5f3803129b0a" />
<img width="2550" height="1104" alt="9634f9fb90cbcdebff368dee3d69ec83" src="https://github.com/user-attachments/assets/5b9fc797-9996-4e95-8a63-46f4da60058b" />
<img width="2512" height="1088" alt="image" src="https://github.com/user-attachments/assets/be45b168-3081-417b-8e61-4863273baf70" />

## 目录

- [设备与系统信息](#设备与系统信息)
- [双版本编译方案](#双版本编译方案)
- [定制功能与软件包](#定制功能与软件包)
- [GitHub Actions 云端编译](#github-actions-云端编译)
- [仓库目录结构](#仓库目录结构)
- [固件下载与构建产物](#固件下载与构建产物)
- [刷机与使用说明](#刷机与使用说明)
- [免责声明](#免责声明)
- [致谢](#致谢)

## 设备与系统信息

| 项目 | 信息 |
|---|---|
| 设备型号 | HINLINK OPC-H69K |
| SoC 平台 | Rockchip RK3568 |
| CPU 架构 | ARM64 / AArch64 |
| 编译目标 | `rockchip/armv8` |
| 设备定义 | `hinlink_opc-h6xk` |
| 定制版本 | iStoreOS 24.10、25.12 |
| 编译平台 | GitHub Actions |

实际源码分支、设备支持情况和最终固件版本，以对应工作流的运行记录为准。

## 双版本编译方案

本仓库使用独立分支、配置文件和 GitHub Actions 工作流管理两个版本，尽量避免新版本适配影响原有构建流程。

| 项目 | iStoreOS 24.10 | iStoreOS 25.12 |
|---|---|---|
| 用途 | 原有固件构建与维护 | 新版本适配与测试 |
| Git 分支 | 原有 24.10 编译分支 | `build-25.12` |
| 配置文件 | `rk35xx/h69k-24.10.config` | `rk35xx/h69k-25.12.config` |
| 插件准备脚本 | `scripts/prepare-h69k-24.10.sh` | `scripts/prepare-h69k-25.12.sh` |
| 工作流 | `build-h69k-istoreos-24.10.yml` | `build-h69k-istoreos-25.12.yml` |
| 构建产物名称 | 由 24.10 工作流定义 | `H69K-iStoreOS-25.12-build-output` |

**双版本维护原则：**

- 24.10 和 25.12 使用各自的配置文件与工作流。
- 25.12 的设备定义、内核驱动和插件依赖需要单独检查。
- 两个工作流可以分别启动；实际是否能同时运行，取决于 GitHub Actions 的并发额度和排队情况。
- 25.12 仍需通过实际编译、刷机和功能测试验证，不能仅凭版本号认定所有插件均兼容。

## 定制功能与软件包

本项目计划在官方固件基础上集成或适配以下软件包。

| 软件包或功能 | 主要用途 |
|---|---|
| `luci-app-fan-h69k` | H69K 风扇控制与温度管理 |
| `luci-app-mt5700` | MT5700 模组管理及相关功能 |
| Docker / Dockerd | 容器运行环境与守护进程 |
| `adguardhome` | AdGuard Home 核心程序 |
| `luci-app-adguardhome` | AdGuard Home 管理界面 |
| `luci-app-openclash` | OpenClash 管理界面及相关功能 |
| `kmod-hwmon-pwmfan` | PWM 风扇驱动支持 |
| `kmod-thermal` | 内核温控相关功能 |

### 插件集成方式

- **H69K 风扇插件：** 使用仓库中的 `luci-app-fan-h69k-build-source-1.3-25.zip` 准备源码。
- **MT5700 插件：** 从 [LianXia233/luci-app-mt5700](https://github.com/LianXia233/luci-app-mt5700) 获取源码。
- **AdGuard Home LuCI 前端：** 从 [rufengsuixing/luci-app-adguardhome](https://github.com/rufengsuixing/luci-app-adguardhome) 获取源码。
- **OpenClash：** 从 [vernesong/OpenClash](https://github.com/vernesong/OpenClash) 获取插件源码。
- **Docker、内核模块及其他软件包：** 根据对应版本的源码、软件源和配置进行选择。

以上为项目的集成目标，不代表所有组件都已经成功编译或运行。不同版本的内核、软件源和依赖可能导致功能差异。

特别注意：AdGuard Home 的 LuCI 管理界面与核心程序是不同组件；Docker 运行环境、OpenClash 依赖以及 MT5700 驱动也需要在实际设备上分别验证。

## GitHub Actions 云端编译

本项目使用 GitHub Actions 在云端构建固件，无需在本地电脑安装完整的固件编译环境。

[**打开 GitHub Actions**](../../actions)

### 编译 iStoreOS 24.10

1. 打开 [Actions 页面](../../actions)。
2. 选择 `Build H69K iStoreOS 24.10` 工作流。
3. 如果存在 `Run workflow` 按钮，点击并选择对应的 24.10 分支。
4. 启动编译并等待任务完成。
5. 打开运行记录，在 **Artifacts** 区域下载构建产物。

24.10 应继续使用原有配置、脚本和工作流，避免无意中影响已有的构建流程。

### 编译 iStoreOS 25.12

1. 打开 [Actions 页面](../../actions)。
2. 选择 `Build H69K iStoreOS 25.12` 工作流。
3. 点击 `Run workflow`。
4. 分支选择 `build-25.12`。
5. 启动编译并检查每一步的运行日志。
6. 成功后，在 **Artifacts** 区域查找 `H69K-iStoreOS-25.12-build-output`。

25.12 的首次构建应重点检查源码分支是否可用、H69K 设备定义是否存在、插件源码是否准备成功，以及软件包是否通过配置检查。

> 如果某个工作流没有显示，或没有 `Run workflow` 按钮，请检查当前分支是否包含相应的 YAML 文件，以及工作流是否配置了 `workflow_dispatch`。

### 编译流程

两个版本通常会执行以下类型的操作，具体步骤以各自的工作流文件为准：

1. 检出仓库配置和构建脚本。
2. 安装云端编译依赖。
3. 下载对应版本的 iStoreOS 源码。
4. 检查目标设备定义。
5. 准备自定义插件。
6. 更新软件源并处理软件包依赖。
7. 应用配置并检查目标设备。
8. 下载编译所需源码包。
9. 编译固件。
10. 归档实际生成的文件。

## 仓库目录结构

以下是双版本构建预期使用的主要文件结构：

```text
.
├── .github/
│   └── workflows/
│       ├── build-h69k-istoreos-24.10.yml
│       └── build-h69k-istoreos-25.12.yml
├── rk35xx/
│   ├── h69k-24.10.config
│   └── h69k-25.12.config
├── scripts/
│   ├── prepare-h69k-24.10.sh
│   └── prepare-h69k-25.12.sh
├── luci-app-fan-h69k-build-source-1.3-25.zip
└── README.md
```

目录结构以各分支中的实际文件为准。

### 配置文件

- `rk35xx/h69k-24.10.config`：用于 24.10 固件的设备选择和软件包配置。
- `rk35xx/h69k-25.12.config`：用于 25.12 固件的设备选择和软件包配置。

两个配置文件应分别维护。修改某个版本的软件包时，先确认该版本的源码是否提供对应的软件包和依赖。

### 插件准备脚本

- `scripts/prepare-h69k-24.10.sh`：准备 24.10 构建所需的自定义插件。
- `scripts/prepare-h69k-25.12.sh`：准备 25.12 构建所需的自定义插件。

插件仓库、源码目录和依赖发生变化时，需要检查对应脚本是否仍然有效。

### 工作流文件

- `.github/workflows/build-h69k-istoreos-24.10.yml`：负责 24.10 的云端编译和产物归档。
- `.github/workflows/build-h69k-istoreos-25.12.yml`：负责 25.12 的云端编译和产物归档。

请保持两个工作流的配置路径、构建目录和产物名称相互独立。

## 固件下载与构建产物

编译完成后，在对应的 GitHub Actions 运行记录中查找 **Artifacts**。

根据工作流的实际配置，归档内容可能包括：

- H69K 固件镜像。
- 编译生成的软件包 IPK。
- 构建日志，例如 `build.log`。

只有成功生成并匹配归档路径的文件才会出现在 Artifacts 中。若编译失败，请优先查看第一个失败步骤及其日志。

GitHub Actions Artifacts 是临时构建产物归档，不等同于 GitHub Releases。保留期限由对应工作流中的 `retention-days` 决定。

## 刷机与使用说明

刷写固件前，请确认以下事项：

- **核对设备型号：** 本项目面向 HINLINK OPC-H69K，不要仅凭 RK3568 芯片型号判断固件兼容性。
- **核对版本和镜像：** 确认下载的是正确版本，并检查文件名、镜像格式和设备定义。
- **做好完整备份：** 建议备份系统配置和完整磁盘镜像，并验证备份文件可以正常读取。
- **准备救援方案：** 提前确认设备的救援启动方式和磁盘恢复方法。
- **首次启动后检查：** 验证 LAN/WAN 网络、管理地址、风扇控制、MT5700、Docker、AdGuard Home 和 OpenClash 等功能。
- **核对登录信息：** 默认 IP、登录密码、端口和首次启动行为以实际构建配置为准，不要直接假设与其他固件相同。

建议先在确认可恢复的条件下测试新版本。不要仅因为 25.12 编译成功，就认定所有硬件和插件功能都已验证。

## 免责声明

本项目为个人定制、设备适配与学习用途，不代表 iStoreOS 官方发布或背书。

固件的兼容性、稳定性和功能完整性以实际构建、刷机及测试结果为准。自定义软件包可能存在依赖冲突、驱动不兼容或运行异常。

刷写固件可能导致设备无法启动、系统配置丢失或数据损坏。请在操作前做好备份，并自行评估和承担刷写及使用风险。

## 致谢

感谢以下开源项目及其维护者：

- [iStoreOS 官方项目](https://github.com/istoreos/istoreos)
- [LianXia233/luci-app-mt5700](https://github.com/LianXia233/luci-app-mt5700)
- [rufengsuixing/luci-app-adguardhome](https://github.com/rufengsuixing/luci-app-adguardhome)
- [vernesong/OpenClash](https://github.com/vernesong/OpenClash)
- [GitHub Actions](https://github.com/features/actions)

感谢所有为开源固件、驱动与插件生态作出贡献的开发者。


-微信-

