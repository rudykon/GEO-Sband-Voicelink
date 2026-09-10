# 项目结构与文件放置

本项目用于链路展示和开发对比。完整性由双向链路环节与数据流决定，局部精度由模块实现决定。需要详细算法时，通过统一接口替换目标模块。

| 位置 | 职责 |
|---|---|
| config/step1_macro_chain.json | 场景、链路、采样预算与模块选择 |
| code/matlab/run_step1_all.m | 唯一宏观运行入口，负责计算、对比、Simulink与结果导出 |
| code/matlab/+step1/designScreening.m | 场景/速率采样和全量统计 |
| code/matlab/+step1/designOptions.m | 采样默认值、参数校验与工作量上限的统一来源 |
| code/matlab/+step1/systemChainOptions.m | 双向链路工程默认值与范围的统一来源 |
| code/matlab/+step1/designSystemChain.m | 八个模块调用与数据传递 |
| code/matlab/+step1/+modules/ | 默认模块、接口校验与实现解析 |
| code/matlab/+step1/+examples/ | 自定义RF器件与概率曲线示例 |
| code/matlab/+step1/runDesignSimulink.m | 统一端口的双向子系统模型 |
| code/matlab/+step1/buildMacroModuleTemplate.m | 可替换RF子系统模板 |
| code/matlab/+step1/compareDesignResults.m | 同种子、全量帧配对对比 |
| scripts/run_step1_matlab.ps1 | 600秒/8 GiB资源限制及产物校验 |
| code/matlab/tests/、scripts/tests/ | 当前模块合同和运行器测试 |
| artifacts/results/step1_design/ | 当前运行产物 |

模块实现是MATLAB路径上可解析的具名.m函数。内部可封装其他算法或器件模型，但输出必须满足帧维度、有效状态与时延合同。

signals扩展域可传特征、软信息或其他算法数据；作者负责定义物理意义和单位。state在每个独立重复开始时重置，避免试验之间污染。

## 新文件放在哪里

| 文件类型 | 放置位置 |
|---|---|
| 用户算法或器件的MATLAB包 | code/matlab/+myproject/，配置引用myproject.functionName |
| 框架模块和接口检查 | code/matlab/+step1/+modules/ |
| 可直接调用的开发示例 | code/matlab/examples/；默认示例实现放+step1/+examples/ |
| 场景或器件配置 | config/；可复现示例放config/examples/ |
| 回归测试 | code/matlab/tests/；Windows工具测试放scripts/tests/ |
| 文档与可发布图表 | docs/；当前验收记录放docs/validation/ |
| 运行结果、原始日志、缓存 | artifacts/，由程序创建，不放回源码目录 |

Simulink顶层模型由代码构建并保存在各次运行目录内；生成的.slx、slxc和slprj不应混入源码。用户自己维护的原生库可放在自定义模块目录，并在配置中声明库路径。源码.slx可被Git收录，.slxc缓存被忽略。

## 上传内容

GitHub默认内容是源码、配置、文档、脚本及运行产物目录说明。artifacts的运行产物、.local凭据、.venv、编译缓存均被忽略；[验收记录](validation/README.md)可随仓库分发。准备方法见[GitHub说明](github.md)。
