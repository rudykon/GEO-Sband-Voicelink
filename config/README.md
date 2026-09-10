# 配置

- `step1_macro_chain.json`：默认双向宏观链路。
- `examples/rf_device_comparison.json`：手机上行替换为示例RF器件，增加3 dB余量、5 ms时延。
- `examples/stress_comparison.json`：扩大帧数和敏感性范围的对比示例，独立重复仍为4次。

默认配置是完整文件。示例使用单层 `base_config`＋`overrides`，只写与基础配置不同的部分，同样可直接传给启动器的 `-ConfigPath`。

`base_config` 相对于当前JSON文件所在目录解析。普通对象递归合并，数组整体替换；`design.modules` 和 `design.simulink_overrides` 两个映射整体替换，由示例完整指定所需模块和参数。基础配置必须是完整文件，不能继续继承。复制示例时建议仍放在 `config/examples/`，这样基础配置的相对位置不变。

运行记录分别保存示例原文、基础配置原文的SHA-256，以及最终展开配置的SHA-256。

自定义模块写入 `design.modules`，原生Simulink子系统写入 `design.simulink_overrides`。字段合同和路径规则见 [模块开发指南](../docs/module_development.md)。
