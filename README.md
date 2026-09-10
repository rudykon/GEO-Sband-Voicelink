# GEO卫星通话：模块化宏观链路平台

项目用于展示双向链路，以及比较新算法、新器件和总体方案。每个环节具有统一接口和默认实现；通过配置替换目标模块后，完整链路重新计算，并可与默认实现做配对对比。

MATLAB承担主计算，Simulink展示有端口的子系统并执行检查。模块内部可封装其他语言实现；语言比例不作为验收门槛。

## 项目结构

```text
code/matlab/        MATLAB入口、模块实现、Simulink构建、示例和测试
config/            默认配置及可直接运行的对比/压力示例
docs/              项目结构、模块开发、维护及公开验收材料
scripts/           Windows运行器、资源限制、测试及GitHub准备脚本
artifacts/         自动生成的本地运行产物（不上传）
```

详细位置与新文件放置规则见[项目结构](docs/project_overview.md)。

## 完整运行

已验证环境：Windows、MATLAB R2026a；启用 `-UseSimulink` 时需要Simulink。默认计算不依赖Python环境。先在项目根目录执行：

```powershell
.\scripts\run_step1_matlab.ps1 -UseSimulink
.\scripts\run_step1_matlab.ps1 -UseSimulink -CompareBaseline -ConfigPath .\config\examples\rf_device_comparison.json
```

找不到MATLAB时，在命令后附加 `-MatlabExe "实际安装目录\bin\matlab.exe"`，或设置 `MATLAB_EXE`。没有Simulink时省略 `-UseSimulink`，仍可运行MATLAB整链和对比。

默认配置为 `config/step1_macro_chain.json`。自定义时复制配置，在 `design.modules` 中选择自己的模块实现，再用 `-ConfigPath` 指向新文件。启动器保留 **600秒总时限、进程树8 GiB私有提交内存限制**，包含启动、计算、对比、Simulink、图表、报告和退出；超限记录失败。默认实现只使用CPU，不需要GPU或并行池。

MATLAB中替换一个RF器件并对比：

```matlab
addpath("code/matlab")
modules.handset_uplink = struct( ...
    'implementation', 'step1.examples.rfDevice', ...
    'parameters', struct('margin_gain_db',3,'extra_delay_ms',5));
status = run_step1_all(Modules=modules, CompareBaseline=true, UseSimulink=true);
```

示例器件增加3 dB余量和5 ms处理时延。`step1.examples.deviceCurve` 演示如何接入“余量→成功概率”曲线，示例数值应替换为自己的测量或标定数据。

## 双向模块链

```text
手机上行 → 卫星前向转发 → 馈电下行 → 地面前向
地面返回 → 馈电上行     → 卫星返回 → 手机下行
```

八个配置槽：`handset_uplink`、`satellite_forward`、`feeder_downlink`、`ground_forward`、`ground_return`、`feeder_uplink`、`satellite_return`、`handset_downlink`。

模块签名统一为 `[out,state] = implementation(in,parameters,context,state)`。帧编号、有效状态、累计时延和 `signals` 扩展数据真实传给下一个模块。用户实现可内部运行新算法、读取器件模型或封装其他语言工具，返回满足接口合同的结果即可。

Simulink模型包含八个可替换子系统，统一6个输入、5个输出端口。默认模块由原生块重算；任意MATLAB自定义算法以显式适配器回放接入，仍检查有效状态和时延串接。也可通过 `design.simulink_overrides` 接入原生子系统。详见[模块开发指南](docs/module_development.md)。

## 输出

每次运行写入 `artifacts/results/step1_design/runs/<run-id>/`：

- `run_status.json`、`resource_status.json`：运行阶段、检查结果和资源实测。
- `staging/results/end_to_end_summary.csv`：双向可用率、帧数、中断与时延。
- `staging/results/chain_stages.csv`：模块自身及逐段累计结果。
- `staging/results/module_manifest.json`：实现名称、参数、源码路径与SHA-256。
- `staging/results/effective_config.json`：包含运行时模块覆盖的有效配置。
- `staging/results/module_comparison.csv`：请求对比时，全量配对帧改善/退化和指标变化。
- `staging/results/baseline_end_to_end_summary.csv`：同配置、同种子的默认模块结果。
- `staging/simulink/`、`staging/figures/`、`staging/report/`：模型、图表和报告。

统计和配对使用所有帧、所有独立重复。Simulink展示/检查每组第一重复前至多1500帧，覆盖所有配置的场景/速率组合。`end_to_end_availability` 是同一帧时隙双向服务都成功的比例。默认参数是工程假设，不能直接视为实测通话性能。

## 验收结果

98项测试通过。在16 GB内存、RTX 4070 Laptop 8 GB机器上，包含Simulink、图表和报告的默认整链实测65.37秒，自定义器件与基线对比65.49秒；进程树私有内存峰值均低于3.89 GiB。详见[验收记录](docs/validation/README.md)。

测试与资源说明见[维护指南](docs/maintenance.md)，结构见[项目说明](docs/project_overview.md)。

## GitHub准备

```powershell
.\scripts\prepare_github.ps1
.\scripts\prepare_github.ps1 -CreateArchive
```

脚本按Git忽略规则核对上传文件、文档链接、凭据模式和单文件大小；第二条命令另生成 `dist/` 下的源码ZIP。不会创建远程仓库、提交或推送。详见[GitHub准备说明](docs/github.md)。
