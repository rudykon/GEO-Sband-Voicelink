# 模块接口与开发对比

八个槽按两个方向串接，未声明的槽使用默认实现。

| 槽位 | 默认实现 |
|---|---|
| handset_uplink、feeder_downlink、feeder_uplink、handset_downlink | step1.modules.rfLink |
| satellite_forward、ground_forward、ground_return、satellite_return | step1.modules.transfer |

## MATLAB合同

```matlab
function [out,state] = myDevice(in,parameters,context,state)
out = in;
out.margin_db = context.reference_margin_db + parameters.gain_db;
out.local_success = out.margin_db >= 0;
out.valid = in.valid & out.local_success;
out.delay_ms = in.delay_ms + context.default_delay_ms + parameters.processing_ms;
out.signals.my_feature = out.margin_db;
state = struct('frames_processed',numel(in.valid));
end
```

推荐保存为 `code/matlab/+myproject/myDevice.m`，对应 `implementation='myproject.myDevice'`。启动器会新开MATLAB并加入 `code/matlab`，不会继承交互会话中临时添加的路径。每次接收一个场景、一个速率、一个独立重复的连续N帧。

| 字段 | 合同 |
|---|---|
| in.frame_index、in.time_s | N×1帧编号和时间，输出不得重排 |
| in.valid | N×1 logical，上游累计有效性 |
| in.delay_ms | N×1累计时延，单位ms |
| in.payload_bits | N×1宏观帧载荷位数元数据 |
| in.signals | scalar struct，下游可读取的自定义数据 |
| context.reference_margin_db | N×1当前RF腿的参考余量 |
| context.default_delay_ms | 当前槽的默认局部时延 |
| context.uniform_draw、context.stream | 独立、可配对复现的随机输入/流 |
| out.local_success | N×1 logical，该模块自身成功判决 |
| out.valid | 必须等于in.valid & out.local_success |
| out.margin_db | N×1有限RF余量，单位dB；非RF默认模块为0占位，不是事件概率 |
| out.delay_ms | N×1有限累计时延，不得小于输入 |

输出保留输入帧元数据和signals结构。前段丢失的帧不能被后段复活；重传等算法可在目标模块内部完成，把最终成功和消耗时延折算到相同帧合同。

state=[]在每个独立重复开始时重置，输出是该次调用的终态，不跨独立试验复用。完整连续批次可在函数内部按时间迭代。使用context.stream，避免依赖全局rng或persistent状态。框架保护调用者随机状态。

signals的意义、单位由作者定义。它可传波形或软判决等数据，但额外工作仍受600秒/8 GiB预算约束。

## 配置替换

可在默认配置副本的design中加入modules，也可复制config/examples/rf_device_comparison.json，只维护差异：

```json
{
  "base_config": "../step1_macro_chain.json",
  "overrides": {
    "design": {
      "modules": {
        "handset_uplink": {
          "implementation": "step1.examples.rfDevice",
          "parameters": {"margin_gain_db": 3, "extra_delay_ms": 5}
        }
      }
    }
  }
}
```

基础文件路径相对于示例文件所在目录。只支持一层继承；普通对象递归合并，数组整体替换，modules与simulink_overrides两个映射整体替换，由示例完整指定所需模块和参数。未声明模块槽使用默认实现。

使用完整配置时，把上例的modules对象放在design.modules下。每个模块还可设置label作为报告中的显示名称。

RF内置实现参数为margin_gain_db、extra_delay_ms；转发实现支持loss_probability、extra_delay_ms。具名自定义实现可自行定义参数，作者应校验字段、单位、范围和维度。

step1.examples.rfDevice演示包装RF算法并增加signals数据。step1.examples.deviceCurve演示“余量→成功概率”曲线接入，含随机输入和曲线检查；示例曲线仅为演示。

## 全量配对对比

```matlab
addpath("code/matlab")
addpath("code/matlab/examples")
status = run_module_comparison(UseSimulink=true);
```

module_comparison.csv中变化为候选减基线，availability_delta_pp单位为百分点。improved_frames指基线失败/候选成功，regressed_frames相反，二者加unchanged_frames等于全部帧数。前向和返回时延分别比较，不把单向改动误算为两倍。

基线/候选共享场景、种子、帧编号与全部独立重复。框架拒绝非模块配置指纹不同的配对。结果记录实现入口源码哈希与参数。

## 原生Simulink替换

每个模块子系统统一端口顺序：

| 输入 | 输出 |
|---|---|
| 1 valid_in | 1 valid_out |
| 2 reference_margin_db | 2 local_success |
| 3 random_draw | 3 cumulative_delay_out_ms |
| 4 loss_probability | 4 margin_db |
| 5 base_local_delay_ms | 5 local_delay_ms |
| 6 cumulative_delay_in_ms | — |

信号可为场景/速率向量；每个仿真时刻对应一帧。valid和累计时延从前一子系统接到下一子系统。

```matlab
projectPaths = step1.defaultPaths;
template = step1.buildMacroModuleTemplate( ...
    fullfile(projectPaths.rootDir,"artifacts/debug/my_rf_library"), ...
    GainDb=3, ExtraDelayMs=5);
cfg = step1.loadConfig;
cfg.design.modules.handset_uplink = struct( ...
    'implementation','step1.modules.rfLink', ...
    'parameters',struct('margin_gain_db',3,'extra_delay_ms',5));
cfg.design.simulink_overrides.handset_uplink = template;
results = step1.designScreening(cfg);
check = step1.runDesignSimulink(cfg,results,"artifacts/debug/my_rf_check");
```

模板返回library_path与block_path。上例使用绝对目录，返回路径可直接存入JSON；启动器中的MATLAB工作目录为code/matlab，不要在JSON中使用依赖交互会话工作目录的相对库路径。在模板内部替换算法块即可接入。框架检查端口合同并复制为独立子系统，保存后的顶层模型不依赖外部库链接。MATLAB与Simulink对应实现不一致时明确报错。

默认及原生替换模块从输入重算。任意MATLAB自定义实现采用显式适配器回放本地成功、余量和局部时延；Simulink仍重算累计有效性、时延和双向汇总。状态标明回放范围，它不构成自定义算法的独立验证。

Simulink检查每组第一重复前至多1500帧；长时统计及配对比较使用所有帧。局部详细算法先独立测试，再接入宏观整链。
