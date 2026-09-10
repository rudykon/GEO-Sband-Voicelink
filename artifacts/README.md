# 本地运行产物

该目录由启动器、MATLAB和检查脚本自动创建。除本说明外，不提交GitHub。

| 目录 | 内容 |
|---|---|
| results/step1_design/runs/ | 每次独立运行的配置、模块记录、统计、Simulink模型和报告 |
| logs/ | 原始测试日志、资源记录、仓库检查结果 |
| cache/simulink/ | Simulink缓存和代码生成目录 |
| debug/ | 本地诊断脚本、临时构建与发布检查目录 |

可以随仓库分发的小型验收摘要放在 [docs/validation](../docs/validation/README.md)，可复现配置放在 `config/examples/`。原始日志可能含本机路径和环境信息，不直接作为公开文档附件。
