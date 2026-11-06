调温大师 luci-app-fan-h69k 1.3-25（从用户提供的包内运行文件恢复）
目录结构：
- Makefile：OpenWrt/LuCI package Makefile
- files/：安装到固件根文件系统的文件

注意：
1. 这是从 IPK 的 data.tar.gz 恢复的构建目录，不包含原始开发源码/版本控制历史。
2. 编译前请核对目标分支的依赖是否存在：luci-base、luci-compat、luci-lua-runtime、kmod-hwmon-pwmfan。
3. 原包控制信息声明 Architecture: all；当前目录按 all 打包。若构建系统要求目标专用依赖或 kmod-hwmon-gpiofan，需按目标源码确认。
4. 建议在测试固件中验证，不要直接覆盖现有路由器系统。
