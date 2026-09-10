function [specs, manifest] = resolve(cfg, systemOptions)
%RESOLVE Resolve the eight named .m implementations and freeze provenance.
% CFG.design.modules.<stage> has implementation, parameters, optional label.
% A custom named .m function receives (in,params,context,state). Configuration
% cannot contain anonymous functions, expressions, or implicit fallbacks.
if nargin < 2
    systemOptions = step1.systemChainOptions(cfg);
end
stageNames = ["handset_uplink"; "satellite_forward"; "feeder_downlink"; "ground_forward"; ...
    "ground_return"; "feeder_uplink"; "satellite_return"; "handset_downlink"];
rfStage = [true; false; true; false; false; true; false; true];
modules = struct();
if isfield(cfg, 'design') && isfield(cfg.design, 'modules'), modules = cfg.design.modules; end
if ~isstruct(modules) || ~isscalar(modules)
    error('step1:ModuleConfiguration', 'design.modules must be a scalar struct.');
end
unknown = setdiff(string(fieldnames(modules)), stageNames);
if ~isempty(unknown)
    error('step1:ModuleConfiguration', 'Unknown module slot: %s.', unknown(1));
end
specs = repmat(struct('stage_id', "", 'implementation', "", 'parameters', struct(), ...
    'callable', [], 'is_default_implementation', false), 8, 1);
rows = cell(8, 1);
for index = 1:8
    stage = stageNames(index);
    if rfStage(index), expected = "step1.modules.rfLink"; else, expected = "step1.modules.transfer"; end
    entry = struct('implementation', expected, 'parameters', struct(), 'label', stage);
    if isfield(modules, stage)
        supplied = modules.(stage);
        if ~isstruct(supplied) || ~isscalar(supplied) ...
                || ~all(isfield(supplied, {'implementation', 'parameters'})) ...
                || ~isempty(setdiff(fieldnames(supplied), {'implementation'; 'parameters'; 'label'}))
            error('step1:ModuleConfiguration', 'Module %s requires implementation and parameters, with optional label.', stage);
        end
        for field = string(fieldnames(supplied)).', entry.(field) = supplied.(field); end
    end
    if ~(isstring(entry.implementation) || ischar(entry.implementation)) ...
            || ~isscalar(string(entry.implementation)) ...
            || isempty(regexp(char(entry.implementation), '^[A-Za-z]\w*(\.[A-Za-z]\w*)*$', 'once'))
        error('step1:ModuleConfiguration', 'Module %s implementation must be a named MATLAB function.', stage);
    end
    if ~isstruct(entry.parameters) || ~isscalar(entry.parameters) ...
            || ~(ischar(entry.label) || (isstring(entry.label) && isscalar(entry.label)))
        error('step1:ModuleConfiguration', 'Module %s requires scalar parameters and a text label.', stage);
    end
    implementation = string(entry.implementation);
    implementationPath = which(char(implementation));
    [~, ~, extension] = fileparts(implementationPath);
    if isempty(implementationPath) || ~strcmpi(extension, '.m') || ~isfile(implementationPath)
        error('step1:ModuleConfiguration', 'Module %s must resolve to an existing named .m file: %s.', stage, implementation);
    end
    implementationPath = char(java.io.File(implementationPath).getCanonicalPath());
    configuredParams = entry.parameters;
    params = configuredParams;
    if implementation == "step1.modules.rfLink"
        params = step1.modules.defaultParameters(params, struct('margin_gain_db', 0, 'extra_delay_ms', 0));
        if params.extra_delay_ms < 0
            error('step1:ModuleParameters', 'Module %s extra_delay_ms must be nonnegative.', stage);
        end
    elseif implementation == "step1.modules.transfer"
        if startsWith(stage, "satellite"), loss = systemOptions.satellite_frame_loss_probability;
        elseif startsWith(stage, "ground"), loss = systemOptions.ground_frame_loss_probability;
        else, loss = 0;
        end
        params = step1.modules.defaultParameters(params, struct('loss_probability', loss, 'extra_delay_ms', 0));
        if params.loss_probability < 0 || params.loss_probability > 1 || params.extra_delay_ms < 0
            error('step1:ModuleParameters', 'Module %s requires loss_probability in [0,1] and nonnegative extra_delay_ms.', stage);
        end
    end
    try
        configuredJson = string(jsonencode(configuredParams));
        effectiveJson = string(jsonencode(params));
    catch failure
        error('step1:ModuleConfiguration', 'Parameters for %s are not JSON serializable: %s', stage, failure.message);
    end
    specs(index) = struct('stage_id', stage, 'implementation', implementation, ...
        'parameters', params, 'callable', str2func(char(implementation)), ...
        'is_default_implementation', implementation == expected);
    rows{index} = table(stage, implementation, string(entry.label), string(implementationPath), ...
        string(step1.sha256File(implementationPath)), configuredJson, effectiveJson, ...
        implementation == expected, "step1-frame-module-v1", ...
        'VariableNames', {'stage_id', 'implementation', 'label', 'implementation_path', ...
        'implementation_sha256', 'configured_parameters_json', 'effective_parameters_json', ...
        'is_default_implementation', 'interface_version'});
end
manifest = vertcat(rows{:});
end
