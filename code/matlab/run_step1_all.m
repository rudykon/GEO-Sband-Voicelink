function status = run_step1_all(varargin)
%RUN_STEP1_ALL Run the bounded, modular macro chain.
%   Profile="design" is the default. "quick" selects the same macro workflow.
%   Modules overrides cfg.design.modules by stage; CompareBaseline requests
%   a paired comparison against the built-in modules using the same inputs.
%   The positional run_step1_all(CONFIGPATH, PROFILE, ...) API remains valid.

parser = inputParser();
parser.FunctionName = 'run_step1_all';
isText = @(value) ischar(value) || (isstring(value) && isscalar(value));
isFlag = @(value) islogical(value) && isscalar(value);
parser.addParameter('Profile', 'design', isText);
parser.addParameter('ConfigPath', '', isText);
parser.addParameter('RunId', '', isText);
parser.addParameter('SkipPlots', false, isFlag);
parser.addParameter('SkipReport', false, isFlag);
parser.addParameter('UseSimulink', false, isFlag);
parser.addParameter('CompareBaseline', false, isFlag);
parser.addParameter('Modules', struct(), @(value) isstruct(value) && isscalar(value));
knownNames = lower(string(parser.Parameters));
values = varargin;
if ~isempty(values) && isText(values{1}) && ~any(strcmpi(string(values{1}), knownNames))
    configPath = string(values{1});
    profile = "design";
    consumed = 1;
    if numel(values) >= 2 && isText(values{2}) ...
            && any(strcmpi(strtrim(string(values{2})), ["design", "quick", "full"]))
        profile = string(values{2});
        consumed = 2;
    end
    values = [{"ConfigPath", configPath, "Profile", profile}, values(consumed + 1:end)];
end
parser.parse(values{:});
options = parser.Results;
profile = lower(strtrim(string(options.Profile)));
if profile == "full"
    error('step1:RetiredProfile', ...
        'Profile="full" is not supported. Use Profile="design" for the bounded modular macro workflow.');
end
if ~any(profile == ["design", "quick"])
    error('step1:UnknownProfile', 'Profile must be design or quick; both run the macro workflow.');
end
runTimer = tic;
paths = step1.defaultPaths();
cfg = step1.loadConfig(options.ConfigPath, "design");
if ~isfield(cfg.design, 'modules'), cfg.design.modules = struct(); end
for moduleName = string(fieldnames(options.Modules)).'
    cfg.design.modules.(moduleName) = options.Modules.(moduleName);
end
if options.UseSimulink
    % Check each case's first contiguous 60 seconds at the default frame
    % interval; long runs retain full statistics without exporting all frames.
    sampling = step1.designOptions(cfg);
    cfg.design.trace_points = min(sampling.frames_per_replicate, 1500);
end
budget = step1.designBudget(cfg, CompareBaseline=options.CompareBaseline);
effectiveConfig = cfg;
for metadataField = ["paths", "runtime", "configPath", "configSha256", ...
        "baseConfigPath", "baseConfigSha256"]
    if isfield(effectiveConfig, metadataField)
        effectiveConfig = rmfield(effectiveConfig, metadataField);
    end
end
step1.checkDesignBudget(budget, runTimer, 'create_output');
% Every run owns its result namespace and cannot overwrite an earlier run.
output = cfg.output;
output.runs_relative_dir = "artifacts/results/step1_design/runs";
context = step1.io.newRunContext(string(paths.rootDir), "design", ...
    options.RunId, output);
status = struct("schema_version", "step1-design-run-v1", ...
    "profile", "design", "status", "running", "authoritative", false, ...
    "run_id", context.runId, "run_dir", context.runDir, ...
    "config_path", string(cfg.configPath), "config_sha256", string(cfg.configSha256), ...
    "started_at", localNow(), "matlab_release", string(version('-release')), ...
    "source", "matlab_modular_macro_service_chain", ...
    "effective_config_sha256", step1.io.sha256Text(jsonencode(effectiveConfig)), ...
    "comparison", struct("requested", options.CompareBaseline, "status", "not_requested"), ...
    "resource_budget", budget);
if isfield(cfg, 'baseConfigPath') && strlength(string(cfg.baseConfigPath)) > 0
    status.base_config_path = string(cfg.baseConfigPath);
    status.base_config_sha256 = string(cfg.baseConfigSha256);
end
step1.io.writeRunStatus(context, status);
fprintf('Step 1 design screening: %s\n', context.runDir);
try
    status = localCheckpoint(context, status, budget, runTimer, 'compute');
    phaseTimer = tic;
    results = step1.designScreening(cfg);
    status.timings.compute_seconds = toc(phaseTimer);
    if options.CompareBaseline
        status = localCheckpoint(context, status, budget, runTimer, 'baseline_comparison');
        phaseTimer = tic;
        baselineCfg = cfg;
        baselineCfg.design.modules = struct();
        if isfield(baselineCfg.design, 'simulink_overrides')
            baselineCfg.design = rmfield(baselineCfg.design, 'simulink_overrides');
        end
        baseline = step1.designScreening(baselineCfg);
        results.module_comparison = step1.compareDesignResults(baseline, results);
        results.baseline_end_to_end_summary = baseline.end_to_end_summary;
        status.comparison.status = "completed";
        status.comparison.policy = "identical_configuration_and_seed_only_module_implementations_and_parameters_differ";
        status.comparison.cases = height(results.module_comparison);
        status.comparison.baseline_modules = table2struct(baseline.module_manifest);
        status.timings.comparison_seconds = toc(phaseTimer);
        clear baseline
    end
    phaseTimer = tic;
    status = localCheckpoint(context, status, budget, runTimer, 'export');
    names = ["summary", "end_to_end_summary", "chain_stages", ...
        "link_budget", "sensitivity", "trace"];
    if options.CompareBaseline
        names = [names, "module_comparison", "baseline_end_to_end_summary"];
    end
    status.files = struct();
    for name = names
        resultPath = fullfile(context.resultDir, name + ".csv");
        step1.io.writeTableAtomic(resultPath, results.(name));
        status.files.(name) = resultPath;
    end
    assumptionsPath = fullfile(context.resultDir, "assumptions.json");
    step1.io.writeJsonAtomic(assumptionsPath, results.assumptions);
    status.files.assumptions = assumptionsPath;
    moduleManifestPath = fullfile(context.resultDir, 'module_manifest.json');
    step1.io.writeJsonAtomic(moduleManifestPath, struct( ...
        'schema_version', 'step1-module-manifest-v1', ...
        'interface_version', 'step1-frame-module-v1', ...
        'modules', table2struct(results.module_manifest)));
    status.files.module_manifest = moduleManifestPath;
    effectiveConfigPath = fullfile(context.resultDir, 'effective_config.json');
    step1.io.writeJsonAtomic(effectiveConfigPath, effectiveConfig);
    status.files.effective_config = effectiveConfigPath;
    status.effective_design_options = results.assumptions.options;
    status.timings.export_seconds = toc(phaseTimer);

    phaseTimer = tic;
    status = localCheckpoint(context, status, budget, runTimer, 'simulink');
    status.simulink = struct("status", "not_requested", ...
        "scope", "Optional frame-level abstract decision check; no waveform validation.");
    if options.UseSimulink
        status.simulink = step1.runDesignSimulink(cfg, results, ...
            fullfile(context.stagingDir, "simulink"));
    end
    status.timings.simulink_seconds = toc(phaseTimer);
    phaseTimer = tic;
    status = localCheckpoint(context, status, budget, runTimer, 'plots');
    status.plots = struct("status", "skipped_by_request");
    if ~options.SkipPlots
        status.files.overview = localPlot(results, context.figureDir);
        status.plots.status = "completed";
    end
    status.timings.plot_seconds = toc(phaseTimer);

    status.language_policy = struct("policy", "advisory", ...
        "matlab_target_share", 0.60, "enforced", false);
    phaseTimer = tic;
    status = localCheckpoint(context, status, budget, runTimer, 'report');
    status.report = struct("status", "skipped_by_request");
    if ~options.SkipReport
        reportPath = fullfile(context.reportDir, "design_report.md");
        localReport(cfg, results, status, reportPath);
        status.files.report = reportPath;
        status.report.status = "completed";
    end
    status.timings.report_seconds = toc(phaseTimer);
    step1.checkDesignBudget(budget, runTimer, 'complete');
    status.elapsed_seconds = toc(runTimer);
    status.completed_at = localNow();
    status.status = "completed";
    status.current_stage = "completed";
    step1.io.writeRunStatus(context, status);
    fprintf('Completed design screening in %.2f s (compute %.2f s).\n', ...
        status.elapsed_seconds, status.timings.compute_seconds);
    fprintf('Results: %s\n', status.files.summary);
catch exception
    status.status = "failed";
    status.elapsed_seconds = toc(runTimer);
    status.completed_at = localNow();
    status.error = step1.io.exceptionStruct(exception);
    step1.io.writeRunStatus(context, status);
    rethrow(exception);
end
end

function status = localCheckpoint(context, status, budget, runTimer, stage)
status.elapsed_seconds = step1.checkDesignBudget(budget, runTimer, stage);
status.current_stage = stage;
step1.io.writeRunStatus(context, status);
end

function stamp = localNow()
stamp = string(datetime("now", "TimeZone", "UTC", ...
    "Format", "yyyy-MM-dd'T'HH:mm:ss.SSSXXX"));
end

function path = localPlot(results, outputDir)
rows = results.summary;
scenarioKeys = unique(string(rows.scenario_key), 'stable');
rates = unique(rows.voice_rate_bps, 'stable');
availability = zeros(numel(scenarioKeys), numel(rates));
margin = availability;
for s = 1:numel(scenarioKeys)
    for r = 1:numel(rates)
        row = rows(string(rows.scenario_key) == scenarioKeys(s) ...
            & rows.voice_rate_bps == rates(r), :);
        availability(s,r) = 100 * row.end_to_end_availability;
        margin(s,r) = row.p10_margin_db;
    end
end
f = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 1180 660]);
cleanup = onCleanup(@() close(f)); %#ok<NASGU>
layout = tiledlayout(f, 1, 2, 'TileSpacing', 'compact', 'Padding', 'compact');
nexttile(layout);
bar(availability);
ylim([0 100]); grid on;
xticks(1:numel(scenarioKeys)); xticklabels(replace(scenarioKeys, '_', ' '));
xtickangle(25); ylabel('Both service directions available (%)');
title('End-to-end macro availability');
legend(compose('%.1f kbps', rates/1000), 'Location', 'southoutside', 'Orientation', 'horizontal');
nexttile(layout);
bar(margin); yline(0, '--'); grid on;
xticks(1:numel(scenarioKeys)); xticklabels(replace(scenarioKeys, '_', ' '));
xtickangle(25); ylabel('10th-percentile margin (dB)');
title('Uplink low-tail margin');
title(layout, 'GEO S-band bidirectional service chain | explicit design assumptions');
path = fullfile(outputDir, 'design_overview.png');
exportgraphics(f, path, 'Resolution', 150);
end

function localReport(cfg, results, status, path)
rows = results.summary;
endToEnd = results.end_to_end_summary;
lines = ["# GEO S-band 总体设计快速评估"; ""; ...
    "本报告模拟可替换模块组成的手机上/下行、双向馈电、卫星转发和地面网。" + ...
    "默认实现为宏观工程模型，自定义算法/器件实现及其参数见模块清单。"; ""; ...
    "- 配置 SHA-256：`" + string(cfg.configSha256) + "`"; ...
    "- 随机种子：" + string(cfg.seed); ...
    "- 核心计算耗时：" + compose('%.3f', status.timings.compute_seconds) + " 秒（不含 MATLAB 启动）。"; ...
    "- Simulink：`" + string(status.simulink.status) + "`。模块端口与验证范围详见 run_status.json 中的 simulink 记录。"; ...
    "- 资源：启动器上限 600 秒、进程树 8 GiB；CPU 串行，GPU 计算不参与。"; ...
    "- MATLAB 占比约 60% 是软目标，不作为运行或结果验收门槛。"; ""; ...
    "| 场景 | 速率 kbps | 上行模块成功比例 | 近似 95% 区间 | P10 余量 dB | 最长中断 ms |"; ...
    "|---|---:|---:|---:|---:|---:|"];
for i = 1:height(rows)
    lines(end+1) = compose('| %s | %.1f | %.2f%% | %.2f–%.2f%% | %.2f | %.0f |', ...
        string(rows.scenario_key(i)), rows.voice_rate_bps(i)/1000, ...
        100*rows.availability(i), 100*rows.availability_ci_low(i), ...
        100*rows.availability_ci_high(i), rows.p10_margin_db(i), ...
        rows.max_outage_ms(i)); %#ok<AGROW>
end
lines = [lines; ""; "## 完整宏观业务链"; ""; ...
    "| 场景 | 速率 kbps | 双向业务可用率 | 近似 95% 区间 | 最长业务中断 ms | 单向时延 ms | 往返时延 ms |"; ...
    "|---|---:|---:|---:|---:|---:|---:|"];
for i = 1:height(endToEnd)
    row = endToEnd(i,:);
    lines(end+1) = compose('| %s | %.1f | %.2f%% | %.2f–%.2f%% | %.0f | %.2f | %.2f |', ...
        string(row.scenario_key), row.voice_rate_bps/1000, ...
        100*row.end_to_end_availability, 100*row.end_to_end_availability_ci_low, ...
        100*row.end_to_end_availability_ci_high, row.max_outage_ms, ...
        row.assumed_call_one_way_ms, row.assumed_call_rtt_ms); %#ok<AGROW>
end
lines = [lines; ""; "各环节成功比例见 `../results/chain_stages.csv`，全部业务指标见 `../results/end_to_end_summary.csv`。"; ...
    "模块实现、参数和源码哈希见 `../results/module_manifest.json`；有效配置见 `../results/effective_config.json`。"];
if isfield(results, 'module_comparison')
    lines = [lines; ""; "## 与默认模块的配对对比"; ""; ...
        "两次计算共享场景、帧编号、独立重复和随机种子，仅替换模块实现/参数。"; ...
        "可用率变化采用百分点；时延为模块模型的逐帧累计时延。"; ""; ...
        "| 场景 | 速率 kbps | 可用率变化 pp | 改善帧 | 退化帧 | 前向时延变化 ms | 返回时延变化 ms |"; ...
        "|---|---:|---:|---:|---:|---:|---:|"];
    for i = 1:height(results.module_comparison)
        row = results.module_comparison(i,:);
        lines(end+1) = compose('| %s | %.1f | %+.3f | %d | %d | %+.3f | %+.3f |', ...
            string(row.scenario_key), row.voice_rate_bps/1000, row.availability_delta_pp, ...
            row.improved_frames, row.regressed_frames, ...
            row.forward_delay_delta_ms, row.return_delay_delta_ms); %#ok<AGROW>
    end
    lines = [lines; ""; "完整配对结果见 `../results/module_comparison.csv`，默认模块结果见 `../results/baseline_end_to_end_summary.csv`。"];
end
lines = [lines; ...
    ""; "## 使用边界"; ""; ...
    "上行预算使用配置中的链路参数；下行相对上行余量、双向馈电余量、转发/地面网丢包和时延均为可配置设计假设。" + ...
    "尚未具备实测下行 EIRP、终端接收 G/T 与全网校准数据，不能将设计结果当成真实设备性能。"; ""; ...
    "链路时延由各模块输出逐段累计。默认实现计入传播、组帧、卫星与地面网处理；" + ...
    "接入新器件或算法后，时延统计跟随其输出变化。"; ""; ...
    "短样本区间反映模型内抽样波动，不能证明 99% 或更高的服务保证。中断统计只覆盖已模拟时段。"; ...
    "门限、信道假设和统计口径见 `../results/assumptions.json`；" + ...
    "净预算 ±3 dB 等参数权衡见 `../results/sensitivity.csv`（实际扫描值以该文件为准）。"; ""; ...
    "需要更细的局部模型时，可通过统一模块接口接入自定义算法或器件模型，并与默认模块进行配对比较。"];
step1.io.writeTextAtomic(path, strjoin(lines, newline) + newline);
end
