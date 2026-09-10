function [options, work] = designOptions(cfg, errorId)
%DESIGNOPTIONS Shared sampling defaults, validation and numerical-work limits.
% Direct screening and resource preflight share this policy. A caller may
% retain its public error identifier without duplicating the validation.
if nargin < 2, errorId = 'step1:DesignOptions'; end
options = struct('frames_per_replicate', 1500, 'replicates', 4, ...
    'trace_points', 300, 'threshold_ebn0_db', [], ...
    'link_delta_db', [-3 0 3], 'confidence_level', 0.95, 'target_availability', 0.99);
if isfield(cfg.voice, 'legacy_threshold_ebn0_db')
    options.threshold_ebn0_db = cfg.voice.legacy_threshold_ebn0_db;
end
if isfield(cfg, 'design')
    if ~isstruct(cfg.design) || ~isscalar(cfg.design)
        error(errorId, 'cfg.design must be a scalar struct.');
    end
    for name = string(fieldnames(options)).'
        if isfield(cfg.design, name), options.(name) = cfg.design.(name); end
    end
end
localInteger(options.frames_per_replicate, 100, 20000, 'frames_per_replicate', errorId);
localInteger(options.replicates, 2, 16, 'replicates', errorId);
localInteger(options.trace_points, 0, 20000, 'trace_points', errorId);
for name = ["confidence_level", "target_availability"]
    value = options.(name);
    if ~isnumeric(value) || ~isreal(value) || ~isscalar(value) || ~isfinite(value) || value <= 0 || value >= 1
        error(errorId, 'design.%s must lie strictly between zero and one.', name);
    end
end
for name = ["threshold_ebn0_db", "link_delta_db"]
    value = options.(name);
    if ~isnumeric(value) || ~isreal(value) || ~isvector(value) || isempty(value) || any(~isfinite(value))
        error(errorId, 'design.%s must be a nonempty finite numeric vector.', name);
    end
    options.(name) = double(value(:)).';
end
if numel(options.threshold_ebn0_db) ~= numel(cfg.voice.rate_bps)
    error(errorId, 'One design threshold is required for each configured payload rate.');
end
if numel(options.link_delta_db) > 21
    error(errorId, 'At most 21 design.link_delta_db cases are allowed.');
end
work = struct();
work.channel_frames = options.frames_per_replicate * options.replicates * numel(cfg.scenarios);
work.case_count = numel(cfg.scenarios) * numel(cfg.voice.rate_bps);
work.export_trace_rows = work.case_count * min(options.trace_points, options.frames_per_replicate);
% Keep the existing conservative count, including the reused zero case.
work.case_sensitivity_frames = work.case_count * options.frames_per_replicate ...
    * options.replicates * (1 + numel(options.link_delta_db));
if work.channel_frames > 500000
    error(errorId, 'Design screening is limited to 500000 channel frames across scenarios and replicates.');
end
if work.case_count > 100 || work.export_trace_rows > 200000 || work.case_sensitivity_frames > 25000000
    error(errorId, ...
        'Design screening is limited to 100 scenario-rate cases, 200000 trace rows, and 25000000 case-sensitivity frames.');
end
end

function localInteger(value, minimum, maximum, name, errorId)
if ~isnumeric(value) || ~isreal(value) || ~isscalar(value) || ~isfinite(value) ...
        || value ~= fix(value) || value < minimum || value > maximum
    error(errorId, 'design.%s must be an integer in [%d,%d].', name, minimum, maximum);
end
end
