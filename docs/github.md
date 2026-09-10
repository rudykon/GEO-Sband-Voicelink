# GitHub准备

仓库包含模块化链路源码、配置、文档和测试。克隆后可按首页命令运行MATLAB整链，并选择启用Simulink。

## 检查和导出

在项目根目录执行（需要Git）：

```powershell
.\scripts\prepare_github.ps1
.\scripts\prepare_github.ps1 -CreateArchive
```

第一条按Git实际忽略规则列出待上传文件，检查文件存在、文档链接是否随包携带、常见凭据模式、本地产物误收录，以及本项目设定的20 MiB单文件阈值。已有Git仓库中的已跟踪文件也会检查，即使后来加入了忽略规则。

第二条通过检查后生成 `dist/step1-macro-chain-<时间>-<标识>.zip`，ZIP根目录就是项目根目录，包含.gitignore和.gitattributes。该脚本不会创建当前项目的Git仓库、设置remote、提交、推送或读取本地凭据；无Git仓库时，只在被忽略的artifacts/debug中建立临时清单库。

检查结果和逐文件SHA-256保存在本地 `artifacts/logs/repository_preflight_latest.json`。原始日志和这个完整文件清单不作为公开附件。模式检查只是上传前的明确检查项，不能替代对拟公开内容的审阅。

## 默认上传范围

| 收录 | 不收录 |
|---|---|
| code/matlab源码、示例、测试 | artifacts中的运行产物、日志和缓存 |
| config默认配置与对比示例 | .local凭据、.venv、本地临时目录 |
| docs及公开验收摘要 | slprj、slxc、MEX、编辑器备份 |
| scripts运行器、检查脚本及测试 | dist导出的ZIP自身 |
| README、Git规则、运行产物目录说明 | 本机环境设置 |

手动创建上传包时同样使用上述范围。GitHub网页上传或Git推送由仓库拥有者执行。

## 克隆后的验证

先按[首页](../README.md)运行默认或自定义器件示例，再按[维护指南](maintenance.md)运行MATLAB和Windows测试。需要Simulink时安装并启用对应许可；MATLAB未被找到时用 `-MatlabExe` 指定实际可执行文件。

Simulink模型会在首次运行时生成，运行目录和缓存目录不存在时由程序创建。可以先运行GitHub检查，确认本地验证后生成的缓存与原始日志仍不会进入提交。

源码包已通过98项测试，并完成默认整链和自定义器件对比，详见[验收记录](validation/README.md)。
