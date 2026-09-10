function chain = designSystemChain(cfg, uplinkMarginDb, scenarioIndex, caseContext)
%DESIGNSYSTEMCHAIN Execute eight replaceable modules in two real pipelines.
% Each callback receives the preceding callback's entire output, including
% signals, payload, validity and cumulative delay. Independent replicates
% restart state and each direction starts with valid=true and zero delay.
% The default modules use frame-level RF and transfer models with explicit
% engineering assumptions; these assumptions are not measured device data.
if nargin < 3, scenarioIndex = 1; end
if nargin < 4, caseContext = struct(); end
if ~isnumeric(uplinkMarginDb) || ~isreal(uplinkMarginDb) ...
        || isempty(uplinkMarginDb) || ndims(uplinkMarginDb) > 2 ...
        || any(~isfinite(uplinkMarginDb), 'all') || numel(uplinkMarginDb) > 500000
    error("step1:DesignSystemChain", "Access margins must be a finite real matrix of at most 500000 frames.");
end
if ~isnumeric(scenarioIndex) || ~isscalar(scenarioIndex) ...
        || ~isfinite(scenarioIndex) || scenarioIndex < 1 || scenarioIndex ~= fix(scenarioIndex)
    error("step1:DesignSystemChain", "scenarioIndex must be a positive integer.");
end
options = step1.systemChainOptions(cfg);
[n, replicates] = size(uplinkMarginDb);
if ~isstruct(caseContext) || ~isscalar(caseContext)
    error('step1:DesignSystemChain', 'caseContext must be a scalar struct.');
end
if ~isfield(caseContext, 'voice_rate_bps'), caseContext.voice_rate_bps = double(cfg.voice.rate_bps(1)); end
if ~isnumeric(caseContext.voice_rate_bps) || ~isscalar(caseContext.voice_rate_bps) ...
        || ~isfinite(caseContext.voice_rate_bps) || caseContext.voice_rate_bps <= 0
    error('step1:DesignSystemChain', 'caseContext.voice_rate_bps must be a finite positive scalar.');
end
if ~isfield(caseContext, 'scenario_key')
    if scenarioIndex <= numel(cfg.scenarios), caseContext.scenario_key = string(cfg.scenarios(scenarioIndex).scenario_key);
    else, caseContext.scenario_key = "scenario_" + scenarioIndex;
    end
end
% Screening resolves and hashes modules once per run, then passes this
% immutable local registry to paired sensitivity calls. Direct callers get
% the same validation/resolution here.
if isfield(caseContext, 'resolved_modules') && isfield(caseContext, 'module_manifest')
    specs = caseContext.resolved_modules;
    manifest = caseContext.module_manifest;
else
    [specs, manifest] = step1.modules.resolve(cfg, options);
end
stageNames = string({specs.stage_id}).';
geometry = step1.resolveGeometry(cfg);
frameMs = double(cfg.channel.frame_duration_ms);
handsetMs = geometry.slant_range_km / 299792.458 * 1000;
gatewayMs = options.gateway_slant_range_km / 299792.458 * 1000;
baseDelay = [handsetMs + frameMs; options.satellite_processing_ms; gatewayMs; options.ground_network_ms; ...
    options.ground_network_ms + frameMs; gatewayMs; options.satellite_processing_ms; handsetMs];
defaultLoss = [0; options.satellite_frame_loss_probability; 0; options.ground_frame_loss_probability; ...
    options.ground_frame_loss_probability; 0; options.satellite_frame_loss_probability; 0];
frames = struct();
frames.reference_uplink_margin_db = uplinkMarginDb;
frames.reference_downlink_margin_db = uplinkMarginDb + options.downlink_margin_offset_db;
drawNames = ["satellite_forward_draw", "ground_forward_draw", ...
    "ground_return_draw", "satellite_return_draw"];
for name = drawNames, frames.(name) = zeros(n, replicates); end
networkSeeds = zeros(replicates, 1);
moduleSeeds = zeros(8, replicates);
finalStates = cell(8, replicates);
forwardSignals = cell(replicates, 1);
returnSignals = cell(replicates, 1);
numericSuffixes = ["reference_margin_db", "base_local_delay_ms", "margin_gain_db", "extra_delay_ms", ...
    "loss_probability", "uniform_draw", "input_cumulative_delay_ms", "margin_db", ...
    "local_delay_ms", "cumulative_delay_ms"];
logicalSuffixes = ["input_valid", "valid", "local_success", "closed"];
for stage = stageNames.'
    for suffix = numericSuffixes, frames.(stage + "_" + suffix) = zeros(n, replicates); end
    for suffix = logicalSuffixes, frames.(stage + "_" + suffix) = false(n, replicates); end
end
for name = ["forward_delay_ms", "return_delay_ms", "forward_payload_bits", "return_payload_bits"]
    frames.(name) = zeros(n, replicates);
end
for replicate = 1:replicates
    networkSeeds(replicate) = mod(double(cfg.seed) + options.network_seed_offset ...
        + 1009 * scenarioIndex + 104729 * replicate, 2^32);
    stream = RandStream("mt19937ar", "Seed", networkSeeds(replicate));
    draws = rand(stream, n, numel(drawNames));
    for index = 1:numel(drawNames)
        frames.(drawNames(index))(:, replicate) = draws(:, index);
    end
    for index = 1:8
        stage = stageNames(index);
        if index == 1 || index == 5
            packet = struct('frame_index', (1:n).', 'time_s', (0:n-1).' * frameMs / 1000, ...
                'valid', true(n, 1), 'delay_ms', zeros(n, 1), ...
                'payload_bits', repmat(caseContext.voice_rate_bps * frameMs / 1000, n, 1), ...
                'signals', struct());
        end
        if stage == "handset_uplink", referenceMargin = uplinkMarginDb(:, replicate);
        elseif stage == "handset_downlink", referenceMargin = frames.reference_downlink_margin_db(:, replicate);
        elseif stage == "feeder_uplink", referenceMargin = repmat(options.feeder_uplink_margin_db, n, 1);
        elseif stage == "feeder_downlink", referenceMargin = repmat(options.feeder_downlink_margin_db, n, 1);
        else, referenceMargin = zeros(n, 1);
        end
        moduleSeeds(index, replicate) = mod(double(cfg.seed) + options.network_seed_offset ...
            + 15485863 * index + 1009 * scenarioIndex + 104729 * replicate, 2^32);
        moduleStream = RandStream('mt19937ar', 'Seed', moduleSeeds(index, replicate));
        if isfield(frames, stage + "_draw")
            uniformDraw = frames.(stage + "_draw")(:, replicate);
        else
            % RF implementations may also use a reproducible uniform input;
            % its generation does not consume the callback's stream.
            drawStream = RandStream('mt19937ar', 'Seed', mod(moduleSeeds(index, replicate) + 257, 2^32));
            uniformDraw = rand(drawStream, n, 1);
        end
        context = struct('stage_id', stage, 'scenario_index', scenarioIndex, ...
            'scenario_key', string(caseContext.scenario_key), 'voice_rate_bps', caseContext.voice_rate_bps, ...
            'rate', caseContext.voice_rate_bps, 'replicate_index', replicate, 'frame_duration_ms', frameMs, ...
            'reference_margin_db', referenceMargin, 'uniform_draw', uniformDraw, ...
            'default_delay_ms', baseDelay(index), 'default_loss_probability', defaultLoss(index), ...
            'stream', moduleStream, 'random_seed', moduleSeeds(index, replicate), 'cfg', cfg);
        if scenarioIndex <= numel(cfg.scenarios), context.scenario = cfg.scenarios(scenarioIndex); end
        if isfield(caseContext, 'threshold_ebn0_db'), context.threshold_ebn0_db = caseContext.threshold_ebn0_db; end
        frames.(stage + "_input_valid")(:, replicate) = packet.valid;
        frames.(stage + "_input_cumulative_delay_ms")(:, replicate) = packet.delay_ms;
        inputDelay = packet.delay_ms;
        [packet, finalStates{index, replicate}] = step1.modules.execute(specs(index), packet, context, []);
        frames.(stage + "_reference_margin_db")(:, replicate) = referenceMargin;
        frames.(stage + "_base_local_delay_ms")(:, replicate) = baseDelay(index);
        frames.(stage + "_uniform_draw")(:, replicate) = uniformDraw;
        frames.(stage + "_loss_probability")(:, replicate) = localParameter(specs(index), 'loss_probability', defaultLoss(index));
        frames.(stage + "_margin_gain_db")(:, replicate) = localParameter(specs(index), 'margin_gain_db', 0);
        frames.(stage + "_extra_delay_ms")(:, replicate) = localParameter(specs(index), 'extra_delay_ms', 0);
        frames.(stage + "_margin_db")(:, replicate) = packet.margin_db;
        frames.(stage + "_local_success")(:, replicate) = packet.local_success;
        frames.(stage + "_closed")(:, replicate) = packet.local_success;
        frames.(stage + "_valid")(:, replicate) = packet.valid;
        frames.(stage + "_local_delay_ms")(:, replicate) = packet.delay_ms - inputDelay;
        frames.(stage + "_cumulative_delay_ms")(:, replicate) = packet.delay_ms;
        if index == 4
            frames.forward_delay_ms(:, replicate) = packet.delay_ms;
            frames.forward_payload_bits(:, replicate) = packet.payload_bits;
            forwardSignals{replicate} = packet.signals;
        elseif index == 8
            frames.return_delay_ms(:, replicate) = packet.delay_ms;
            frames.return_payload_bits(:, replicate) = packet.payload_bits;
            returnSignals{replicate} = packet.signals;
        end
    end
end
frames.downlink_margin_db = frames.handset_downlink_margin_db;
frames.uplink_service_closed = frames.ground_forward_valid;
frames.downlink_service_closed = frames.handset_downlink_valid;
frames.end_to_end_rf_closed = frames.handset_uplink_closed & frames.feeder_downlink_closed ...
    & frames.feeder_uplink_closed & frames.handset_downlink_closed;
frames.end_to_end_closed = frames.uplink_service_closed & frames.downlink_service_closed;

direction = [repmat("handset_to_ground", 4, 1); repmat("ground_to_handset", 4, 1)];
parameter = ["uplink_margin_db"; "satellite_frame_loss_probability"; ...
    "feeder_downlink_margin_db"; "ground_frame_loss_probability"; ...
    "ground_frame_loss_probability"; "feeder_uplink_margin_db"; ...
    "satellite_frame_loss_probability"; "downlink_margin_offset_db"];
source = ["configured_uplink_RF_budget_with_assumed_threshold"; "assumed_iid_frame_loss"; ...
    "assumed_constant_net_margin"; "assumed_iid_frame_loss"; "assumed_iid_frame_loss"; ...
    "assumed_constant_net_margin"; "assumed_iid_frame_loss"; "assumed_offset_shared_access_channel"];
stageAvailability = zeros(8, 1);
pathAvailability = zeros(8, 1);
for index = 1:8
    success = frames.(stageNames(index) + "_closed");
    stageAvailability(index) = mean(success, 'all');
    pathAvailability(index) = mean(frames.(stageNames(index) + "_valid"), 'all');
    if ~specs(index).is_default_implementation, source(index) = "custom_named_module_contract"; end
end
stages = table(stageNames, direction, [1; 2; 3; 4; 1; 2; 3; 4], ...
    stageAvailability, pathAvailability, repmat(n * replicates, 8, 1), parameter, source, ...
    'VariableNames', {'stage', 'direction', 'stage_order', 'stage_availability', ...
    'cumulative_direction_availability', 'total_frames', 'assumption_parameter', 'model_source'});
stages.implementation = manifest.implementation;
stages.implementation_sha256 = manifest.implementation_sha256;
stages.mean_local_delay_ms = zeros(8, 1);
stages.p95_local_delay_ms = zeros(8, 1);
for index = 1:8
    stageDelay = frames.(stageNames(index) + "_local_delay_ms");
    stages.mean_local_delay_ms(index) = mean(stageDelay, 'all');
    stages.p95_local_delay_ms(index) = step1.empiricalQuantile(stageDelay, 0.95);
end
delays = struct();
delays.handset_to_satellite_ms = handsetMs;
delays.satellite_to_gateway_ms = gatewayMs;
delays.frame_assembly_ms = frameMs;
delays.satellite_processing_ms = options.satellite_processing_ms;
delays.ground_network_ms = options.ground_network_ms;
delays.one_way_ms = mean(frames.forward_delay_ms, 'all');
delays.return_one_way_ms = mean(frames.return_delay_ms, 'all');
delays.p95_one_way_ms = step1.empiricalQuantile(frames.forward_delay_ms, 0.95);
delays.p95_return_one_way_ms = step1.empiricalQuantile(frames.return_delay_ms, 0.95);
delays.round_trip_ms = mean(frames.forward_delay_ms + frames.return_delay_ms, 'all');
delays.p95_round_trip_ms = step1.empiricalQuantile(frames.forward_delay_ms + frames.return_delay_ms, 0.95);
chain = struct('frames', frames, 'stages', stages, 'delays', delays, ...
    'options', options, 'network_seeds', networkSeeds, ...
    'module_seeds', moduleSeeds, 'module_manifest', manifest, ...
    'assumptions', struct('model', "bidirectional_configurable_module_service_chain_v2", ...
    'reverse_rf_budget_calibrated', false, 'parameters_are_engineering_assumptions', true, ...
    'access_correlation', "downlink_reference_uses_identical_uplink_access_sample_plus_fixed_margin_offset_before_modules", ...
    'feeder_model', "constant_reference_margins_passed_to_replaceable_feeder_modules", ...
    'network_model', "independent_iid_draws_passed_to_modules_default_transfer_uses_configured_loss_probability", ...
    'seed_policy', "network_stream_separate_from_channel_common_across_rates_and_sensitivity", ...
    'availability_definition', "fraction_of_paired_frames_successful_in_both_service_directions", ...
    'payload_rate_definition', "two_way_payload_rate_bps_is_per_direction_payload_bps_times_two_way_frame_success_fraction_not_sum_of_both_directions", ...
    'delay_model', "two_GEO_legs_plus_one_frame_assembly_satellite_processing_and_ground_network_per_direction", ...
    'delay_scope', "mean_and_p95_module_reported_delay_over_all_offered_frames_including_invalid_no_implicit_queue_or_retransmission", ...
    'module_contract', "step1-frame-module-v1_out_valid_equals_input_valid_AND_local_success_no_frame_reordering", ...
    'module_state', "one_time_ordered_vector_call_per_module_per_case_and_replicate_state_starts_empty", ...
    'module_rng', "stage_scenario_replicate_seed_excludes_rate_and_sensitivity_global_rng_restored_even_on_error", ...
    'scope', "system_design_estimate_not_measured_RF_availability_or_device_validation"));
chain.final_states = finalStates;
chain.forward_signals = forwardSignals;
chain.return_signals = returnSignals;
end

function value = localParameter(spec, name, fallback)
value = fallback;
if isfield(spec.parameters, name)
    candidate = spec.parameters.(name);
    if isnumeric(candidate) && isreal(candidate) && isscalar(candidate) && isfinite(candidate)
        value = double(candidate);
    end
end
end
