Steam 与 Astrill LSP 兼容性工具
版本：1.0 / 2026-10-29

用途
针对 Steam 提示 ASProxy64.dll 不兼容的情况，将 Windows 的按程序 Winsock LSP 分类方法应用于 Steam。
沿用 astrill-chatgpt-fix 对 Codex 使用的思路，但这份脚本是独立编写的 Steam 工具，不是原仓库发布的版本。
保留 Astrill LSP 全局安装状态；只处理选定 Steam 安装目录中的 steam.exe，以及 bin 子目录内实际存在的 steamwebhelper.exe。

适用环境
Windows 10/11 x64，内置 Windows PowerShell 5.1。
脚本通过管理员权限调用 Windows WSCGetApplicationCategory / WSCSetApplicationCategory。
操作依据已核对；Steam 能否恢复启动，需要在你的 Windows 电脑上实际验证。

一、修复
1. 将 ZIP 全部解压到一个普通文件夹，保持 CMD 与 PS1 文件在一起。
2. 退出所有正在运行的游戏，再通过 Steam 菜单或托盘图标完全退出 Steam。
   如果错误弹窗关闭后仍残留 Steam / Steam Client WebHelper，可在任务管理器中结束这两个客户端进程。
3. 右键 01-Apply.cmd → 以管理员身份运行。
4. 查看列出的 Steam 安装目录是否正确。成功修改的路径显示 APPLIED。
   ALREADY APPLIED：本工具已经处理过该路径。
   SKIPPED existing category：Windows 已有分类，本工具保留原设置。
5. 关闭命令窗口，从你原有的快捷方式正常启动 Steam。
   无需把 Steam 本身设成“以管理员身份运行”。

工具不会自动结束进程；如果提示 Steam 仍在运行，完全退出后重试。
若电脑上有多个有效 Steam 安装，工具会要求你指定其中一个。
路径未找到或发现多个安装时，在解压目录打开管理员 Windows PowerShell：

powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Steam-Lsp-Compatibility.ps1 -Action Apply -SteamPath "D:\Steam"

请把 D:\Steam 换成实际包含 steam.exe 的安装文件夹；不是 steamapps 游戏库文件夹。
-ExecutionPolicy Bypass 仅用于这一次 PowerShell 进程，不会持久修改系统执行策略。

二、验证
Steam 启动后，右键 02-Status.cmd → 以管理员身份运行。
分类应显示 0x80000000（LSP_SYSTEM），模块检查应显示 NOT LOADED at this snapshot。
LOADED 表示当前进程仍有 ASProxy*.dll。
UNKNOWN 表示无法读取模块或进程已经退出，不能视作已验证通过。
Steam/WebHelper is not running 表示当前没有可检查的进程，不能据此判断修复成功。

如果报错仍存在，请保留并提供 01-Apply 和 02-Status 的完整输出及当前 Steam 错误原文。
如果 Steam 更新后更换了 steamwebhelper.exe 的路径，完全退出 Steam 后重新运行 01-Apply 即可检查新增路径。
此工具不添加自动计划任务。

三、撤回
1. 完全退出 Steam / Steam WebHelper。
2. 右键 03-Undo.cmd → 以管理员身份运行。
3. 正常重新启动 Steam。

原始状态和本工具创建的条目记录保存在：
%ProgramData%\SteamLspCompatibility\state.json

请保留此状态文件，它用于确定哪些条目由本工具创建。
本工具只为原本没有分类的目标增加 LSP_SYSTEM；已有分类一律保留。
Undo 只删除本工具记录、且当前仍等于本工具设置值的分类。
若发现分类已被其他程序修改或操作存在并发冲突，将保留该条目并提示，避免覆盖后来的修改。
先写恢复记录，再调用 Windows 接口；重复运行 Apply 不会覆盖原始状态。

四、与下载分流的关系
本工具处理的是 Steam 进程是否加载相应 LSP，不能直接保证 Steam 下载走本地直连。
StealthVPN 全隧道下，跳过 LSP 的程序仍可能经过系统 VPN 路由。
保留你当前可用的 Astrill 配置，先验证 Steam 能正常启动，再验证下载是否符合分流目标。
LSP_SYSTEM 按 LSP 类别决定可加载的组件，不是仅针对某个 DLL 名称的黑名单。

五、处理范围
只操作上述 Steam 程序的 Winsock 应用分类和自己的恢复记录。
不会修改已成功的 Codex/ChatGPT 分类；不会删除 ASProxy DLL、卸载 LSP、重置 Winsock、修改代理/路由、创建计划任务或更改游戏文件。
未覆盖 SteamService.exe 或游戏进程；当前证据不足以要求修改这些程序。

六、技术依据
1. 用户使用的 ChatGPT 修复库及其源代码：
https://github.com/mondalafighting/astrill-chatgpt-fix
https://github.com/mondalafighting/astrill-chatgpt-fix/blob/main/codex-lsp-exclusion.ps1
2. Microsoft WSCSetApplicationCategory：完整路径、管理员权限、进程重启后生效、非零类别按位合并。
https://learn.microsoft.com/en-us/windows/win32/api/ws2spi/nf-ws2spi-wscsetapplicationcategory
3. Microsoft WSCGetApplicationCategory：10108 / WSASERVICE_NOT_FOUND 表示应用未分类。
https://learn.microsoft.com/en-us/windows/win32/api/ws2spi/nf-ws2spi-wscgetapplicationcategory
4. Microsoft WSL 安装器：以 LSP_SYSTEM 注册，以 flags=0 删除应用分类。
https://github.com/microsoft/WSL/blob/master/src/windows/wslinstall/DllMain.cpp

测试范围
打包前检查 PowerShell 语法及 C# 接口声明，并对新增、重复执行、撤回、既存类别和冲突处理进行模拟验证。
本环境不是 Windows，尚未执行真实 Winsock 写入，也未在本环境运行 Steam/Astrill。
