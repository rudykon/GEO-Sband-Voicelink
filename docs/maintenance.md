# 维护指南

## 当前入口

使用 `scripts/run_step1_matlab.ps1`，默认design；`-UseSimulink`增加链路展示/检查，`-CompareBaseline`增加默认模块对比。MATLAB入口run_step1_all也接受Modules运行时覆盖。

仿真与导出由run_step1_all实现。测试统一使用run_step1_design_tests，源码统计使用step1.auditSourceShare。

## 资源预算

Windows启动器限制本次MATLAB及子进程合计私有提交内存8 GiB，完整命令600秒。MaxRuntimeSeconds和MemoryLimitGB只能收紧。计时覆盖预检、MATLAB新进程、计算、对比、可选Simulink、图表报告、校验与退出。超时、超内存或产物不完整均为失败。

MATLAB内部默认540秒期限，在阶段边界检查。自定义模块可能在一次回调中执行长任务，只有外部启动器能强制结束。用户算法启动的外部程序和消耗的资源同样计入预算。默认实现不使用GPU或并行池。

分配前限制帧数、总信道帧、场景/速率数量、敏感性工作量和轨迹量。请求配对比较时预留两份结果的数组估计；超预算报错，不隐式减少样本。

## 模块比较

复制默认配置或使用Modules，仅替换目标槽。详见[模块开发指南](module_development.md)。

CompareBaseline使用相同非模块配置和种子再运行默认模块，逐帧比较所有独立重复；对比不从采样trace推断全量结果。默认基线清空design.modules和design.simulink_overrides，保留物理场景和采样参数。

结果包含实现路径/SHA-256、配置文件哈希与有效配置哈希。差异配置还记录base_config_path与base_config_sha256，便于追溯共享基础参数。外部器件数据和其他语言子程序应由作者一并版本化；框架记录入口.m源码哈希，不宣称覆盖所有外部依赖。

Simulink缓存和代码生成输出统一进入artifacts/cache/simulink；运行结束恢复调用者的fileGenControl设置。源码占比报告写入artifacts/logs/source_share，语言比例只作记录。

## 测试

```matlab
addpath("code/matlab/tests")
results = run_step1_design_tests;
```

按测试类实时写入artifacts/logs/design_fast_tests_latest.json。默认包含Simulink、模块替换与配对比较；无Simulink时可显式IncludeSimulink=false，记录会标明范围。

```powershell
.\scripts\tests\test_bounded_process.ps1
.\scripts\tests\test_design_launcher.ps1
```

模块修改至少检查默认基线、失败不得复活、时延累计、扩展数据传播、状态重置、随机可复现、异常输出拒绝以及全量配对计数守恒。

Simulink原生替换检查端口、实际接线和MATLAB对应实现一致性。任意MATLAB算法的适配器回放只验证接口及串接，状态必须区分，不能称作独立算法验证。

## 验收与发布检查

[验收记录](validation/README.md)包含测试范围、运行时间和资源实测。上传前运行scripts/prepare_github.ps1，详见[GitHub准备说明](github.md)。
