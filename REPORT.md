# Windows 静默安装复现结果

上次使用的 `0.7.0` 候选包在 Windows Server 2025 runner 上存在可重复的静默安装故障。四种路径均复现访问冲突，程序文件没有落盘；这不是仅凭测试脚本退出码推断的结果。

[原生 Windows 运行与日志](https://github.com/98624017/aiwork-installer-repro-20261020-vxrjbc/actions/runs/39359497622)

## 对照结果

| 安装包 | Runner | 路径 | 安装器退出码 | 实际文件结果 |
| --- | --- | --- | --- | --- |
| 0.7.0 候选 | Windows 2025 | 中文与空格 | `0xC0000005` | EXE / ASAR 均不存在 |
| 0.7.0 候选 | Windows 2025 | 纯英文 | `0xC0000005` | EXE / ASAR 均不存在 |
| 0.7.0 候选 | Windows 2025 | 英文与空格 | `0xC0000005` | EXE / ASAR 均不存在 |
| 0.7.0 候选 | Windows 2025 | 中文、无空格 | `0xC0000005` | EXE / ASAR 均不存在 |
| 同一 0.7.0 候选 | Windows 2022 | 中文与空格 | `0` | EXE / ASAR 哈希匹配；卸载记录与文件存在 |
| 0.7.0-beta.5 基线 | Windows 2025 | 纯英文 | `0` | EXE / ASAR 正常落盘；卸载记录与文件存在 |

候选失败案例的父 `setup.exe` 在约 3–5 秒内退出，十进制退出码均为 `-1073741819`。每例另有一个同路径 `setup.exe` 子进程未退出，驱动等待至 240 秒后取证并清理。四个案例均没有发现已安装的主程序、ASAR、卸载器或卸载项。

JSON 中的 `verdict: timeout` 包含残留子进程的等待超时；直接访问冲突证据位于 `parent.exitCode` 和 `observedAccessViolation: true`。六份报告均没有 `harnessError`，检测脚本本身正常完成。成功对照均约 33 秒完成全程观察。

六个案例使用独立新 VM、相同的 Node 22 / Codex CLI 0.162.0 / Playwright 1.59.1 工具环境，以及同一 PowerShell 7 调用方式：`Start-Process setup.exe -ArgumentList "/S /D=<路径>" -PassThru`。没有渠道码、`/currentuser` 或额外强制安装参数，没有调用模型 API。

## 候选身份与限制

- 候选 Setup SHA256：`3a6860d8d546055393c451f487f6240c5570f982b5038370978efc82cda8d091`，来源提交 `a905f75313ad78c714b4e0499d4a4d8128d16641`。
- 基线 Setup SHA256：`8c6e65404bb751ab674f70dc41a9a9ff2a9eb4f82ad69814a2251bb8f6d2102a`。
- Windows 2025 镜像：`20261007.264.1`；Windows 2022 镜像：`20261012.333.1`。
- 本轮测试的是上次失败的原始候选，不是当前源码 `57a5b640` 重新构建的安装包；后者尚无可复用的完整 Setup 产物。
- 已排除“仅由中文或空格路径触发”这一解释。现有证据证明候选与 Windows 2025 的组合失败，尚不能确定具体故障函数、NSIS 插件或系统机制，也不能推广为 Windows 10/11 的结论。
- 所有快捷方式数组均为空；当前脚本只记录目标完全匹配的链接，尚未区分链接缺失与目标不匹配，因此不宣称快捷方式验收通过。
- 没有可用的故障模块事件或 dump，本轮未修改产品安装器。

脱敏原始 JSON 保存在 [recorded-evidence](recorded-evidence/)；没有应用源码、渠道绑定、凭据或原生 dump。临时仓库归档后保留报告和脚本供复核。
