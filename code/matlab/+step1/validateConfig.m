function cfg = validateConfig(cfg, sourcePath)
%VALIDATECONFIG Validate the active engineering macro-chain configuration.
% Scenarios and voice rates are extensible within the numerical-work budget.
% No waveform, Communications Toolbox, or publication contract is required.
if nargin < 2, sourcePath = '<memory>'; end
localObject(cfg, 'configuration');
localFields(cfg, ["schema_version", "seed", "link", "geometry", ...
    "voice", "channel", "scenarios"], 'configuration');
if string(cfg.schema_version) ~= "step1-macro-chain-v1"
    error('step1:ConfigSchema', ...
        'Expected schema_version step1-macro-chain-v1 in %s.', string(sourcePath));
end
localNumber(cfg.seed, 0, double(intmax('int32')), 'seed');
if cfg.seed ~= fix(cfg.seed)
    error('step1:InvalidConfig', 'seed must be an integer.');
end
if ~isfield(cfg, 'default_profile'), cfg.default_profile = 'design'; end
% Validate the requested profile before any numerical work.
cfg = step1.profileConfig(cfg, cfg.default_profile);
if ~isfield(cfg, 'design'), cfg.design = struct(); end
localObject(cfg.design, 'design');
if isfield(cfg.design, 'modules'), localObject(cfg.design.modules, 'design.modules'); end
if isfield(cfg.design, 'system_chain'), localObject(cfg.design.system_chain, 'design.system_chain'); end
if ~isfield(cfg, 'output'), cfg.output = struct(); end
localObject(cfg.output, 'output');
if ~isfield(cfg.output, 'runs_relative_dir')
    cfg.output.runs_relative_dir = 'artifacts/results/step1_design/runs';
end
localText(cfg.output.runs_relative_dir, 'output.runs_relative_dir');

linkFields = ["uplink_mhz", "downlink_mhz", "distance_km", "bandwidth_hz", ...
    "pt_dbm", "sat_gr_dbi", "pol_loss_db", "extra_loss_db", "nf_db", ...
    "temperature_k", "g_peak_dbi", "g_min_dbi", "posture_exponent"];
localFields(cfg.link, linkFields, 'link');
for key = linkFields
    localNumber(cfg.link.(key), -Inf, Inf, "link." + key);
end
for key = ["uplink_mhz", "downlink_mhz", "distance_km", "bandwidth_hz", ...
        "temperature_k", "posture_exponent"]
    localPositive(cfg.link.(key), "link." + key);
end
for key = ["pol_loss_db", "extra_loss_db", "nf_db"]
    localNumber(cfg.link.(key), 0, Inf, "link." + key);
end
if cfg.link.g_min_dbi > cfg.link.g_peak_dbi
    error('step1:InvalidConfig', 'link.g_min_dbi cannot exceed link.g_peak_dbi.');
end

localFields(cfg.geometry, ["mode", "fixed_elevation_deg", "fixed_slant_range_km", ...
    "terminal_lat_deg", "terminal_lon_deg", "geo_longitude_deg", ...
    "earth_radius_km", "geo_orbit_radius_km"], 'geometry');
if ~any(lower(string(cfg.geometry.mode)) == ["fixed", "coordinates"])
    error('step1:InvalidConfig', 'geometry.mode must be fixed or coordinates.');
end
localNumber(cfg.geometry.fixed_elevation_deg, 0, 90, 'geometry.fixed_elevation_deg');
localPositive(cfg.geometry.fixed_slant_range_km, 'geometry.fixed_slant_range_km');
localNumber(cfg.geometry.terminal_lat_deg, -90, 90, 'geometry.terminal_lat_deg');
localNumber(cfg.geometry.terminal_lon_deg, -180, 180, 'geometry.terminal_lon_deg');
localNumber(cfg.geometry.geo_longitude_deg, -180, 180, 'geometry.geo_longitude_deg');
localPositive(cfg.geometry.earth_radius_km, 'geometry.earth_radius_km');
localPositive(cfg.geometry.geo_orbit_radius_km, 'geometry.geo_orbit_radius_km');
if cfg.geometry.geo_orbit_radius_km <= cfg.geometry.earth_radius_km
    error('step1:InvalidConfig', 'GEO orbit radius must exceed the Earth radius.');
end
resolved = step1.resolveGeometry(cfg);
cfg.geometry.resolved_elevation_deg = resolved.elevation_deg;
cfg.geometry.resolved_slant_range_km = resolved.slant_range_km;
cfg.link.distance_km = resolved.slant_range_km;

localFields(cfg.voice, "rate_bps", 'voice');
rates = cfg.voice.rate_bps;
localVector(rates, 'voice.rate_bps');
rates = double(rates(:)).';
if any(rates <= 0) || numel(unique(rates)) ~= numel(rates)
    error('step1:InvalidConfig', 'voice.rate_bps must contain distinct positive rates.');
end
if isfield(cfg.design, 'threshold_ebn0_db')
    thresholds = cfg.design.threshold_ebn0_db;
elseif isfield(cfg.voice, 'legacy_threshold_ebn0_db')
    thresholds = cfg.voice.legacy_threshold_ebn0_db;
else
    error('step1:InvalidConfig', 'Provide design.threshold_ebn0_db for each voice rate.');
end
localVector(thresholds, 'design.threshold_ebn0_db');
if numel(thresholds) ~= numel(rates)
    error('step1:InvalidConfig', 'Design thresholds must match the number of voice rates.');
end
cfg.voice.rate_bps = rates;
cfg.voice.legacy_threshold_ebn0_db = double(thresholds(:)).';
cfg.design.threshold_ebn0_db = double(thresholds(:)).';
if ~isfield(cfg.voice, 'main_rate_bps'), cfg.voice.main_rate_bps = rates(1); end
localPositive(cfg.voice.main_rate_bps, 'voice.main_rate_bps');
if ~any(rates == cfg.voice.main_rate_bps)
    error('step1:InvalidConfig', 'voice.main_rate_bps must be one of the configured rates.');
end
cfg.voice.threshold_source = 'engineering_assumption_no_waveform_calibration';

localFields(cfg.channel, ["frame_duration_ms", "default_cfo_hz", ...
    "default_rain_loss_db", "cfo_coherent_window_ms", "min_power_gain"], 'channel');
localPositive(cfg.channel.frame_duration_ms, 'channel.frame_duration_ms');
localNumber(cfg.channel.default_cfo_hz, -Inf, Inf, 'channel.default_cfo_hz');
localNumber(cfg.channel.default_rain_loss_db, 0, Inf, 'channel.default_rain_loss_db');
localPositive(cfg.channel.cfo_coherent_window_ms, 'channel.cfo_coherent_window_ms');
localPositive(cfg.channel.min_power_gain, 'channel.min_power_gain');
if cfg.channel.min_power_gain > 1
    error('step1:InvalidConfig', 'channel.min_power_gain must not exceed one.');
end
if ~isstruct(cfg.scenarios) || isempty(cfg.scenarios) || ~isvector(cfg.scenarios)
    error('step1:InvalidConfig', 'scenarios must be a non-empty array of objects.');
end
scenarioFields = ["scenario_key", "label", "p_los", "sigma_db", ...
    "theta_mean_deg", "theta_std_deg", "nlos_loss_db", "speed_mps", ...
    "shadow_decorrelation_m", "mean_los_dwell_frames", "rician_k_db"];
for index = 1:numel(cfg.scenarios)
    sc = cfg.scenarios(index);
    localFields(sc, scenarioFields, "scenarios(" + index + ")");
    localText(sc.scenario_key, 'scenario.scenario_key');
    localText(sc.label, 'scenario.label');
    if ~isfield(sc, 'step1_key') || isempty(sc.step1_key) || strlength(string(sc.step1_key)) == 0
        cfg.scenarios(index).step1_key = sc.scenario_key;
    else
        localText(sc.step1_key, 'scenario.step1_key');
    end
    localNumber(sc.p_los, 0, 1, 'scenario.p_los');
    for key = ["sigma_db", "theta_std_deg", "nlos_loss_db", "speed_mps"]
        localNumber(sc.(key), 0, Inf, "scenario." + key);
    end
    localNumber(sc.theta_mean_deg, 0, 90, 'scenario.theta_mean_deg');
    localNumber(sc.rician_k_db, -Inf, Inf, 'scenario.rician_k_db');
    localPositive(sc.shadow_decorrelation_m, 'scenario.shadow_decorrelation_m');
    localNumber(sc.mean_los_dwell_frames, 1, Inf, 'scenario.mean_los_dwell_frames');
    pLL = 1 - 1 / double(sc.mean_los_dwell_frames);
    if sc.p_los == 1
        pLL = 1; pNN = 0;
    else
        pNN = 1 - double(sc.p_los) * (1 - pLL) / (1 - double(sc.p_los));
    end
    if pNN < -1e-12 || pNN > 1
        error('step1:InvalidConfig', ...
            'Scenario %s dwell time is incompatible with stationary p_los.', string(sc.scenario_key));
    end
    cfg.scenarios(index).elevation_deg = resolved.elevation_deg;
    cfg.scenarios(index).p_ll = pLL;
    cfg.scenarios(index).p_nn = max(0, pNN);
    cfg.scenarios(index).shadow_rho = exp(-double(sc.speed_mps) ...
        * double(cfg.channel.frame_duration_ms) / 1000 / double(sc.shadow_decorrelation_m));
end
keys = string({cfg.scenarios.scenario_key});
if numel(unique(keys)) ~= numel(keys)
    error('step1:InvalidConfig', 'Scenario keys must be unique.');
end
% Resource preflight also validates the shared sampling options and limits.
step1.designBudget(cfg);
step1.systemChainOptions(cfg);
end

function localObject(value, name)
if ~isstruct(value) || ~isscalar(value)
    error('step1:InvalidConfig', '%s must be one object.', name);
end
end
function localFields(value, fields, name)
localObject(value, name);
missing = fields(~isfield(value, cellstr(fields)));
if ~isempty(missing)
    error('step1:InvalidConfig', '%s is missing %s.', name, strjoin(missing, ', '));
end
end
function localText(value, name)
if ~(ischar(value) && isrow(value) || isstring(value) && isscalar(value)) ...
        || strlength(strtrim(string(value))) == 0
    error('step1:InvalidConfig', '%s must be non-empty text.', name);
end
end
function localNumber(value, low, high, name)
if ~isnumeric(value) || ~isreal(value) || ~isscalar(value) || ~isfinite(value) ...
        || value < low || value > high
    error('step1:InvalidConfig', '%s must be finite and in [%g,%g].', name, low, high);
end
end
function localPositive(value, name)
localNumber(value, 0, Inf, name);
if value <= 0, error('step1:InvalidConfig', '%s must be positive.', name); end
end
function localVector(value, name)
if ~isnumeric(value) || ~isreal(value) || isempty(value) || ~isvector(value) ...
        || any(~isfinite(value(:)))
    error('step1:InvalidConfig', '%s must be a non-empty finite vector.', name);
end
end
