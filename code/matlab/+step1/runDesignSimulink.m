function validation = runDesignSimulink(cfg, results, outputDir)
%RUNDESIGNSIMULINK Execute a replaceable, bidirectional macro-chain model.
% Each atomic slot has six input and five output ports; validity and delay
% are physically wired from one stage to the next. Custom MATLAB modules
% use labelled adapter replay for local outputs while native blocks still
% verify chain composition. Native library overrides must agree with MATLAB.
arguments
    cfg (1,1) struct
    results (1,1) struct
    outputDir (1,1) string
end
if isempty(which('new_system')) || isempty(which('sim')) || ~license('test', 'Simulink')
    error('step1:design:SimulinkUnavailable', 'The requested macro-chain check requires Simulink.');
end
stages = ["handset_uplink", "satellite_forward", "feeder_downlink", "ground_forward", ...
    "ground_return", "feeder_uplink", "satellite_return", "handset_downlink"];
aggregates = ["uplink_service_closed", "downlink_service_closed", "end_to_end_rf_closed", "end_to_end_closed"];
numericNames = ["ebn0_db", "threshold_ebn0_db", "margin_db", "reference_ebn0_db", "reference_uplink_margin_db"];
decisionNames = ["link_closed", aggregates];
for stage = stages
    numericNames = [numericNames, stage + ["_reference_margin_db", "_base_local_delay_ms", ...
        "_margin_gain_db", "_extra_delay_ms", "_loss_probability", "_uniform_draw", ...
        "_input_cumulative_delay_ms", "_margin_db", "_local_delay_ms", "_cumulative_delay_ms"]]; %#ok<AGROW>
    decisionNames = [decisionNames, stage + ["_input_valid", "_valid", "_local_success", "_closed"]]; %#ok<AGROW>
end
required = ["scenario_key", "voice_rate_bps", "replicate_index", "frame_index", "time_s", numericNames, decisionNames];
if ~isfield(results, 'trace') || ~istable(results.trace) ...
        || ~all(ismember(required, string(results.trace.Properties.VariableNames))) ...
        || ~isfield(results, 'module_manifest') || ~istable(results.module_manifest)
    error('step1:design:SimulinkTraceMissing', 'The module trace and eight-slot module manifest are required.');
end
if height(results.trace) > 200000
    error('step1:design:SimulinkTraceLength', 'The macro check accepts at most 200000 trace rows.');
end
[input, coverage, n, dt, framesPerReplicate] = localInputs(cfg, results.trace, numericNames, decisionNames);
overrides = localOverrides(cfg, stages);
if strlength(outputDir) == 0
    error('step1:design:SimulinkOutputDirectory', 'A model output directory is required.');
end
if ~isfolder(outputDir), mkdir(outputDir); end
[cacheCleanup, cachePaths] = step1.useSimulinkCache(); %#ok<ASGLU>
caseCount = height(coverage);
[~, tag] = fileparts(tempname());
tag = regexprep(tag, '[^A-Za-z0-9_]', '');
model = ['step1_design_chain_' tag(1:min(24,numel(tag)))];
modelPath = fullfile(outputDir, string(model) + ".slx");
new_system(model);
cleanup = onCleanup(@() localCloseModel(model)); %#ok<NASGU>
time = (0:n-1).' * dt;
set_param(model, 'SolverType', 'Fixed-step', 'Solver', 'FixedStepDiscrete', ...
    'FixedStep', localNumber(dt), 'StartTime', '0', 'StopTime', localNumber(time(end)), ...
    'SimulationMode', 'normal', 'ReturnWorkspaceOutputs', 'on');
workspace = get_param(model, 'ModelWorkspace');
workspace.DataSource = 'Model File';
assignin(workspace, 'design_case_scenario_keys', cellstr(coverage.scenario_key));
assignin(workspace, 'design_case_voice_rate_bps', coverage.voice_rate_bps.');
assignin(workspace, 'design_case_frame_indices', (1:n).');
add_block('simulink/Sources/Constant', [model '/Frame present'], ...
    'Value', sprintf('true(1,%d)',caseCount), 'OutDataTypeStr', 'boolean', 'Position', [30 200 150 240]);
add_block('simulink/Sources/Constant', [model '/Initial delay ms'], ...
    'Value', sprintf('zeros(1,%d)',caseCount), 'Position', [30 310 150 350]);
modules = repmat(struct('stage_id',"",'implementation',"",'execution_mode',"", ...
    'implementation_sha256',"",'effective_parameters_json',"", ...
    'native_override',false,'library_path',"",'library_sha256',"",'block_path',""), 8, 1);
for k = 1:8
    stage = stages(k);
    x = 260 + mod(k-1,4)*630;
    y = 330 + floor((k-1)/4)*720;
    destination = string(model) + "/" + stage;
    metadata = results.module_manifest(string(results.module_manifest.stage_id)==stage,:);
    if height(metadata) ~= 1
        error('step1:design:SimulinkModuleManifest', 'Exactly one manifest entry is required for %s.', stage);
    end
    implementation = string(metadata.implementation(1));
    modules(k).stage_id = stage;
    modules(k).implementation = implementation;
    modules(k).implementation_sha256 = string(metadata.implementation_sha256(1));
    modules(k).effective_parameters_json = string(metadata.effective_parameters_json(1));
    if isfield(overrides,stage) && ~isempty(overrides.(stage))
        override = overrides.(stage);
        localCopyOverride(override, destination);
        modules(k).execution_mode = "native_override";
        modules(k).native_override = true;
        modules(k).library_path = string(override.library_path);
        modules(k).library_sha256 = string(step1.sha256File(override.library_path));
        modules(k).block_path = string(override.block_path);
    elseif implementation == "step1.modules.rfLink" || implementation == "step1.modules.transfer"
        gain = localConstant(input.(stage+"_margin_gain_db"), stage+"_margin_gain_db");
        extra = localConstant(input.(stage+"_extra_delay_ms"), stage+"_extra_delay_ms");
        mode = "rf";
        if implementation == "step1.modules.transfer", mode = "transfer"; end
        step1.populateMacroSubsystem(destination, Mode=mode, GainDb=gain, ExtraDelayMs=extra);
        modules(k).execution_mode = "native_blocks";
    else
        replay = struct();
        for suffix = ["local_success","margin_db","local_delay_ms"]
            variable = "design_replay_" + stage + "_" + suffix;
            assignin(workspace, char(variable), [time,input.(stage+"_"+suffix)]);
            replay.(suffix) = variable;
        end
        step1.populateMacroSubsystem(destination, Mode="replay", ReplayVariables=replay, FrameSeconds=dt);
        modules(k).execution_mode = "adapter_replay";
        set_param(destination, 'BackgroundColor', 'yellow');
    end
    set_param(destination, 'Position', [x y x+340 y+240], 'ShowPortLabels', 'FromPortIcon');
    contextName = stage + "_inputs";
    localContext(model, workspace, contextName, stage, input, time, dt, [x y-155 x+340 y-70]);
    for port = 1:4
        add_line(model, char(contextName+"/"+port), char(stage+"/"+(port+1)), 'autorouting','on');
    end
    if k == 1 || k == 5
        validSource = 'Frame present/1';
        delaySource = 'Initial delay ms/1';
    else
        validSource = char(stages(k-1)+"/1");
        delaySource = char(stages(k-1)+"/3");
    end
    add_line(model, validSource, char(stage+"/1"), 'autorouting','on');
    add_line(model, delaySource, char(stage+"/6"), 'autorouting','on');
    localRecorder(model, stage, [x y+305 x+340 y+365]);
end
localSinkPort(model, 'ground_forward/1', 'design_uplink_service_closed', [2840 390 3110 420]);
localSinkPort(model, 'handset_uplink/4', 'design_margin_db', [260 715 600 745]);
localSinkPort(model, 'handset_downlink/1', 'design_downlink_service_closed', [2840 1110 3110 1140]);
localSinkPort(model, 'ground_forward/3', 'design_uplink_delay_ms', [2840 445 3110 475]);
localSinkPort(model, 'handset_downlink/3', 'design_downlink_delay_ms', [2840 1165 3110 1195]);
localAndPorts(model, 'end_to_end_rf_closed', stages([1 3 6 8])+"/2", [2870 665 2910 755]);
localAndPorts(model, 'end_to_end_closed', ["ground_forward/1","handset_downlink/1"], [2870 830 2910 885]);
add_block('simulink/Math Operations/Sum', [model '/Round trip delay'], ...
    'Inputs','++','Position',[2870 950 2900 1000]);
add_line(model,'ground_forward/3','Round trip delay/1','autorouting','on');
add_line(model,'handset_downlink/3','Round trip delay/2','autorouting','on');
localSinkPort(model,'Round trip delay/1','design_round_trip_delay_ms',[2980 950 3280 980]);
annotation = Simulink.Annotation(model, sprintf([ ...
    'Bidirectional replaceable macro chain | %d cases x %d frames | %.0f ms/frame\n' ...
    'Top: handset to ground. Bottom: ground to handset. Each stage passes valid and cumulative delay.\n' ...
    'Grey/default slots: native macro arithmetic. Yellow slots: labelled MATLAB adapter replay.\n' ...
    'Six input / five output ports are fixed. All trace inputs are stored in this model.'],caseCount,n,1000*dt));
annotation.Position = [240 20 2640 125];
save_system(model,char(modelPath));
simulation = sim(model);
mismatches = 0;
mismatchBySignal = struct();
maxMarginDifference = 0;
maxDelayDifference = 0;
actual = struct();
for k = 1:8
    stage = stages(k);
    for suffix = ["valid","local_success","cumulative_delay_ms","margin_db","local_delay_ms"]
        name = stage+"_"+suffix;
        actual.(name) = localOutput(simulation,"design_"+name,n,caseCount);
        expected = input.(name);
        if ismember(suffix,["valid","local_success"])
            count = sum(actual.(name) ~= expected,'all');
            mismatchBySignal.(name) = count;
            mismatches = mismatches+count;
        elseif suffix == "margin_db"
            maxMarginDifference = max(maxMarginDifference,max(abs(actual.(name)-expected),[],'all'));
        else
            maxDelayDifference = max(maxDelayDifference,max(abs(actual.(name)-expected),[],'all'));
        end
    end
    aliasCount = sum(actual.(stage+"_local_success") ~= input.(stage+"_closed"),'all');
    mismatchBySignal.(stage+"_closed") = aliasCount;
    mismatches = mismatches+aliasCount;
    if k == 1 || k == 5
        previousValid = ones(n,caseCount);
        previousDelay = zeros(n,caseCount);
    else
        previousValid = actual.(stages(k-1)+"_valid");
        previousDelay = actual.(stages(k-1)+"_cumulative_delay_ms");
    end
    count = sum(previousValid ~= input.(stage+"_input_valid"),'all');
    mismatchBySignal.(stage+"_input_valid") = count;
    mismatches = mismatches+count;
    maxDelayDifference = max(maxDelayDifference,max(abs(previousDelay-input.(stage+"_input_cumulative_delay_ms")),[],'all'));
end
for name = aggregates
    value = localOutput(simulation,"design_"+name,n,caseCount);
    count = sum(value ~= input.(name),'all');
    mismatchBySignal.(name) = count;
    mismatches = mismatches+count;
end
uplinkMargin = actual.handset_uplink_margin_db;
maxMarginDifference = max([maxMarginDifference, ...
    max(abs(uplinkMargin-input.margin_db),[],'all'), ...
    max(abs(uplinkMargin+input.threshold_ebn0_db-input.ebn0_db),[],'all'), ...
    max(abs(input.reference_ebn0_db-input.threshold_ebn0_db-input.reference_uplink_margin_db),[],'all')]);
count = sum(actual.handset_uplink_local_success ~= input.link_closed,'all');
mismatchBySignal.link_closed = count;
mismatches = mismatches+count;
if mismatches ~= 0 || maxMarginDifference > 1e-9 || maxDelayDifference > 1e-8
    error('step1:design:SimulinkDecisionMismatch', ...
        'Module chain mismatch: %d decisions, %.12g margin units, %.12g ms delay. Check MATLAB/Simulink slot parameters.', ...
        mismatches,maxMarginDifference,maxDelayDifference);
end
modes = string({modules.execution_mode});
validation = struct('status','completed','model_path',string(modelPath),'cache_paths',cachePaths, ...
    'samples',n*caseCount,'samples_per_case',n,'coverage_count',caseCount, ...
    'coverage',table2struct(coverage),'replicate_index',1,'frame_duration_ms',1000*dt, ...
    'simulation_steps',n,'max_samples_per_case',1500,'max_case_count',64, ...
    'all_configured_cases_covered',true,'frames_per_replicate',framesPerReplicate, ...
    'full_first_replicate_covered',n==framesPerReplicate, ...
    'max_abs_margin_difference',maxMarginDifference,'max_abs_delay_difference_ms',maxDelayDifference, ...
    'decision_mismatches',mismatches,'mismatches_by_signal',mismatchBySignal, ...
    'stage_count',8,'aggregate_decision_count',4,'modules',modules, ...
    'native_module_count',sum(modes=="native_blocks"), ...
    'native_override_count',sum(modes=="native_override"), ...
    'adapter_replay_count',sum(modes=="adapter_replay"), ...
    'scope','replaceable_bidirectional_macro_chain_with_explicit_adapter_provenance', ...
    'description',['Native slots recompute local decisions and delay; adapter slots replay local MATLAB results. ' ...
        'All slots independently propagate wired validity and cumulative delay. Native overrides must match MATLAB outputs.']);
end

function [input, coverage, n, dt, framesPerReplicate] = localInputs(cfg, trace, numericNames, decisionNames)
rates = double(cfg.voice.rate_bps(:));
scenarioKeys = string({cfg.scenarios.scenario_key}).';
caseCount = numel(rates) * numel(scenarioKeys);
if isempty(rates) || isempty(scenarioKeys) || caseCount > 64 ...
        || numel(unique(rates)) ~= numel(rates) ...
        || numel(unique(scenarioKeys)) ~= numel(scenarioKeys)
    error('step1:design:SimulinkCaseLimit', ...
        'The bounded macro model requires 1 to 64 distinct scenario/rate cases.');
end
dt = double(cfg.channel.frame_duration_ms) / 1000;
if ~isscalar(dt) || ~isfinite(dt) || dt <= 0
    error('step1:design:SimulinkTraceDiscontinuous', 'The frame interval must be finite and positive.');
end
sampleLimit = 1500;
framesPerReplicate = 1500;
if isfield(cfg, 'design') && isfield(cfg.design, 'frames_per_replicate')
    framesPerReplicate = double(cfg.design.frames_per_replicate);
end
if ~isscalar(framesPerReplicate) || ~isfinite(framesPerReplicate) ...
        || framesPerReplicate ~= floor(framesPerReplicate) || framesPerReplicate < 2
    error('step1:design:SimulinkTraceLength', 'The configured first replicate must contain at least two frames.');
end
if isfield(cfg, 'design') && isfield(cfg.design, 'trace_points')
    requested = double(cfg.design.trace_points);
    if ~isscalar(requested) || ~isfinite(requested) || requested ~= floor(requested) || requested < 2
        error('step1:design:SimulinkTraceLength', 'The macro check requires at least two configured trace points.');
    end
    sampleLimit = min(sampleLimit, requested);
end
selected = cell(caseCount, 1);
coverage = table('Size', [caseCount 5], ...
    'VariableTypes', {'string', 'double', 'double', 'double', 'double'}, ...
    'VariableNames', {'scenario_key', 'voice_rate_bps', 'frames_available', 'frames_checked', 'replicate_index'});
caseIndex = 0;
for scenario = scenarioKeys.'
    for rate = rates.'
        caseIndex = caseIndex + 1;
        rows = trace(string(trace.scenario_key) == scenario ...
            & double(trace.voice_rate_bps) == rate & double(trace.replicate_index) == 1, :);
        rows = sortrows(rows, 'frame_index');
        if height(rows) < 2
            error('step1:design:SimulinkScenarioMissing', ...
                'Missing first-replicate trace for %s at %.0f bps.', scenario, rate);
        end
        selected{caseIndex} = rows;
        coverage(caseIndex, :) = {scenario, rate, height(rows), 0, 1};
    end
end
n = min(sampleLimit, framesPerReplicate);
if any(coverage.frames_available < n)
    error('step1:design:SimulinkTraceLength', ...
        'Each configured case must provide all %d requested consecutive frames.', n);
end
coverage.frames_checked(:) = n;
names = [numericNames, decisionNames];
input = struct();
for name = names, input.(name) = zeros(n, caseCount); end
for caseIndex = 1:caseCount
    rows = selected{caseIndex}(1:n, :);
    frames = double(rows.frame_index(:));
    times = double(rows.time_s(:));
    if any(~isfinite([frames; times])) || frames(1) ~= 1 || any(diff(frames) ~= 1) ...
            || abs(times(1)) > 1e-9 || any(abs(diff(times) - dt) > 1e-9 * max(1, dt))
        error('step1:design:SimulinkTraceDiscontinuous', ...
            'Every case requires consecutive frames beginning at frame 1, time zero.');
    end
    for name = names
        values = rows.(name);
        if ~(isnumeric(values) || islogical(values)) || ~isreal(values) ...
                || ~iscolumn(values) || any(~isfinite(values))
            error('step1:design:SimulinkTraceInvalid', '%s must contain finite real scalar frame values.', name);
        end
        input.(name)(:, caseIndex) = double(values);
    end
end
for name = decisionNames
    if any(~ismember(input.(name), [0 1]), 'all')
        error('step1:design:SimulinkTraceInvalid', '%s must contain binary frame decisions.', name);
    end
end
for name = numericNames(endsWith(numericNames,"_uniform_draw"))
    if any(input.(name) < 0 | input.(name) >= 1, 'all')
        error('step1:design:SimulinkTraceInvalid', '%s must be a uniform draw in [0,1).', name);
    end
end
for name = numericNames(endsWith(numericNames,"_loss_probability"))
    if any(input.(name) < 0 | input.(name) > 1, 'all')
        error('step1:design:SimulinkTraceInvalid', '%s must lie in [0,1].', name);
    end
end
end

function value = localConstant(values, name)
value = values(1);
if any(abs(values-value)>1e-12,'all')
    error('step1:design:SimulinkModuleParameter','Native slot parameter %s must be constant across cases.',name);
end
end

function overrides = localOverrides(cfg, stages)
overrides = struct();
if isfield(cfg,'design') && isfield(cfg.design,'simulink_overrides')
    overrides = cfg.design.simulink_overrides;
    if ~isstruct(overrides) || ~isscalar(overrides)
        error('step1:design:SimulinkModuleOverride','design.simulink_overrides must be a scalar struct.');
    end
    if any(~ismember(string(fieldnames(overrides)),stages))
        error('step1:design:SimulinkModuleOverride','A Simulink override names an unknown macro slot.');
    end
end
for stage = string(fieldnames(overrides)).'
    override = overrides.(stage);
    if ~isempty(override) && (~isstruct(override) || ~isscalar(override) ...
            || ~all(isfield(override,{'library_path','block_path'})))
        error('step1:design:SimulinkModuleOverride','An override needs library_path and block_path.');
    end
end
end

function localCopyOverride(override,destination)
libraryPath = string(override.library_path);
blockPath = string(override.block_path);
if ~isscalar(libraryPath) || ~isfile(libraryPath) || ~isscalar(blockPath) || strlength(blockPath)==0
    error('step1:design:SimulinkModuleOverride','Override library file and block path must exist.');
end
[~,libraryName] = fileparts(libraryPath);
if ~startsWith(blockPath,libraryName+"/")
    error('step1:design:SimulinkModuleOverride','block_path must be inside the specified library.');
end
wasLoaded = bdIsLoaded(libraryName);
if wasLoaded
    currentPath = string(get_param(libraryName,'FileName'));
    if strlength(currentPath)==0 || ...
            ~strcmpi(char(java.io.File(currentPath).getCanonicalPath()), ...
            char(java.io.File(libraryPath).getCanonicalPath()))
        error('step1:design:SimulinkModuleOverride', ...
            'A different user model with the replacement library name is already loaded.');
    end
end
if ~wasLoaded, load_system(char(libraryPath)); end
cleanup = onCleanup(@() localCloseNewLibrary(libraryName,wasLoaded)); %#ok<NASGU>
if string(get_param(libraryName,'Dirty')) == "on"
    error('step1:design:SimulinkModuleOverride', ...
        'The replacement library has unsaved changes; a saved library is required for reproducible hashing.');
end
if getSimulinkBlockHandle(char(blockPath)) == -1 || string(get_param(blockPath,'BlockType')) ~= "SubSystem"
    error('step1:design:SimulinkModuleOverride','The replacement must be a subsystem.');
end
expectedIn = ["valid_in","reference_margin_db","random_draw","loss_probability", ...
    "base_local_delay_ms","cumulative_delay_in_ms"];
expectedOut = ["valid_out","local_success","cumulative_delay_out_ms","margin_db","local_delay_ms"];
for kind = ["Inport","Outport"]
    ports = find_system(char(blockPath),'SearchDepth',1,'BlockType',char(kind));
    numbers = cellfun(@(p) str2double(get_param(p,'Port')),ports);
    [~,order] = sort(numbers);
    names = string(cellfun(@(p) get_param(p,'Name'),ports(order),'UniformOutput',false)).';
    expected = expectedIn;
    if kind=="Outport", expected=expectedOut; end
    if ~isequal(names,expected)
        error('step1:design:SimulinkModulePorts', ...
            'Replacement %s names and order must match the six-input/five-output macro contract.',kind);
    end
end
add_block(char(blockPath),char(destination),'CopyOption','nolink');
set_param(destination,'TreatAsAtomicUnit','on');
if string(get_param(destination,'LinkStatus')) ~= "none"
    set_param(destination,'LinkStatus','none');
end
end

function localCloseNewLibrary(name,wasLoaded)
if ~wasLoaded, localCloseModel(name); end
end

function localContext(model,workspace,contextName,stage,input,time,dt,position)
path = string(model)+"/"+contextName;
add_block('simulink/Ports & Subsystems/Subsystem',char(path));
Simulink.SubSystem.deleteContents(char(path));
suffixes = ["reference_margin_db","uniform_draw","loss_probability","base_local_delay_ms"];
for k = 1:4
    name = stage+"_"+suffixes(k);
    variable = "design_input_"+name;
    assignin(workspace,char(variable),[time,input.(name)]);
    source = path+"/"+suffixes(k);
    add_block('simulink/Sources/From Workspace',char(source), ...
        'VariableName',char(variable),'SampleTime',localNumber(dt),'Interpolate','off', ...
        'OutputAfterFinalValue','Holding final value','Position',[30 60*k 280 60*k+30]);
    portName = "out_"+suffixes(k);
    add_block('simulink/Ports & Subsystems/Out1',char(path+"/"+portName), ...
        'Port',num2str(k),'Position',[380 60*k 410 60*k+15]);
    add_line(char(path),char(suffixes(k)+"/1"),char(portName+"/1"));
end
set_param(path,'Position',position);
end

function localRecorder(model,stage,position)
name = stage+"_record";
path = string(model)+"/"+name;
add_block('simulink/Ports & Subsystems/Subsystem',char(path));
Simulink.SubSystem.deleteContents(char(path));
suffixes = ["valid","local_success","cumulative_delay_ms","margin_db","local_delay_ms"];
for k = 1:5
    add_block('simulink/Ports & Subsystems/In1',char(path+"/"+suffixes(k)), ...
        'Port',num2str(k),'Position',[30 65*k 60 65*k+15]);
    variable = "design_"+stage+"_"+suffixes(k);
    localSinkPort(char(path),suffixes(k)+"/1",variable,[160 65*k 450 65*k+30]);
    add_line(model,char(stage+"/"+k),char(name+"/"+k),'autorouting','on');
end
set_param(path,'Position',position);
end

function localSinkPort(model,source,variable,position)
name = [char(variable) '_output'];
add_block('simulink/Sinks/To Workspace',[model '/' name], ...
    'VariableName',char(variable),'SaveFormat','Array','Position',position);
add_line(model,char(source),[name '/1'],'autorouting','on');
end

function localAndPorts(model,name,sources,position)
add_block('simulink/Logic and Bit Operations/Logical Operator',[model '/' name], ...
    'Operator','AND','Inputs',num2str(numel(sources)),'Position',position);
for k=1:numel(sources)
    add_line(model,char(sources(k)),[name '/' num2str(k)],'autorouting','on');
end
localSinkPort(model,[name '/1'],['design_' name],[position(3)+70 position(2) position(3)+370 position(2)+30]);
end

function value = localNumber(number)
value = sprintf('%.17g', double(number));
end

function values = localOutput(simulationOutput, variableName, n, caseCount)
values = simulationOutput.get(char(variableName));
if (~isnumeric(values) && ~islogical(values)) || ~isreal(values) ...
        || ~isequal(size(values), [n caseCount]) || any(~isfinite(values), 'all')
    error('step1:design:SimulinkOutputInvalid', ...
        'Expected a finite %d-frame by %d-case numeric output for %s.', n, caseCount, variableName);
end
values = double(values);
end

function localCloseModel(modelName)
if bdIsLoaded(modelName), close_system(modelName, 0); end
end
