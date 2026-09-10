function results = designScreening(cfg)
%DESIGNSCREENING Fast, frame-level bidirectional system design screening.
%   RESULTS = step1.designScreening(CFG) uses a config from step1.loadConfig.
%   No waveform calibration, Communications Toolbox, or Simulink is required.
%   A closed link means payload Eb/N0 >= an ASSUMED design threshold. It is
%   not measured decoder success. The two-way service estimate additionally
%   executes a reverse access leg, both feeder legs, relay, and ground stages
%   under explicitly documented engineering assumptions.
%
%   Optional CFG.design fields (defaults):
%     frames_per_replicate (1500), replicates (4), trace_points (300),
%     threshold_ebn0_db (configured payload-rate thresholds),
%     link_delta_db ([-3 0 3]), confidence_level (0.95),
%     target_availability (0.99).
%   Each replicate starts independently in the stationary channel law.
%   Rates and sensitivity cases share samples for stable paired comparisons.

if nargin < 1 || isempty(cfg), cfg = step1.loadConfig("", "design"); end
options = step1.designOptions(cfg);
[resolvedModules, moduleManifest] = step1.modules.resolve(cfg);
rates = double(cfg.voice.rate_bps(:));
frameMs = double(cfg.channel.frame_duration_ms);
geometry = step1.resolveGeometry(cfg);
cfg.link.distance_km = geometry.slant_range_km;
oneHopMs = cfg.link.distance_km / 299792.458 * 1000.0;
n = options.frames_per_replicate;
replicates = options.replicates;
thresholdSource = "design_assumption_no_waveform_calibration";
rainDb = double(cfg.channel.default_rain_loss_db);
% Evaluate the sinc coherent-integration proxy directly, without optional
% signal toolboxes.
x = double(cfg.channel.default_cfo_hz) * ...
    double(cfg.channel.cfo_coherent_window_ms) / 1000.0;
if x == 0, coherentGain = 1.0; else, coherentGain = abs(sin(pi * x) / (pi * x)); end
cfoLossDb = -20.0 * log10(max(coherentGain, 1e-12));

summaryRows = cell(numel(cfg.scenarios) * numel(rates), 1);
budgetRows = summaryRows;
traceRows = summaryRows;
endToEndRows = summaryRows;
chainStageRows = summaryRows;
comparisonRows = summaryRows;
sensitivityRows = cell(numel(summaryRows) * numel(options.link_delta_db), 1);
summaryIndex = 0;
sensitivityIndex = 0;
for scenarioIndex = 1:numel(cfg.scenarios)
    sc = cfg.scenarios(scenarioIndex);
    [snrDb, channelTrace, seeds] = localChannel(cfg, sc, scenarioIndex, options);
    budget = step1.linkBudget(cfg, sc.theta_mean_deg, ...
        cfg.link.bandwidth_hz, rates);
    % A downlink frequency is metadata in the uplink budget function, not
    % evidence of a calculated downlink. Do not export it as such here.
    budget.downlink_mhz = [];
    for rateIndex = 1:numel(rates)
        summaryIndex = summaryIndex + 1;
        rate = rates(rateIndex);
        threshold = options.threshold_ebn0_db(rateIndex);
        referenceEbN0 = snrDb + 10.0 * log10(cfg.link.bandwidth_hz / rate) ...
            - rainDb - cfoLossDb;
        referenceMargin = referenceEbN0 - threshold;
        caseContext = struct('scenario_key', string(sc.scenario_key), 'voice_rate_bps', rate, ...
            'threshold_ebn0_db', threshold, 'resolved_modules', resolvedModules, 'module_manifest', moduleManifest);
        chain = step1.designSystemChain(cfg, referenceMargin, scenarioIndex, caseContext);
        margin = chain.frames.handset_uplink_margin_db;
        % Preserve the default numerical baseline exactly while letting a
        % replacement's actual margin/local-success drive diagnostics/stats.
        ebn0 = referenceEbN0 + (margin - referenceMargin);
        closed = chain.frames.handset_uplink_closed;
        stats = localStats(closed, sc, options.confidence_level);
        endToEndStats = localStats(chain.frames.end_to_end_closed, sc, options.confidence_level);
        nominalEbN0 = budget.ebn0_db(rateIndex) - rainDb - cfoLossDb;
        row = struct();
        row.scenario_key = string(sc.scenario_key);
        row.step1_key = string(sc.step1_key);
        row.label = string(sc.label);
        row.voice_rate_bps = rate;
        row.threshold_ebn0_db = threshold;
        row.threshold_source = thresholdSource;
        row.nominal_ebn0_db = nominalEbN0;
        row.nominal_margin_db = nominalEbN0 - threshold;
        row.nominal_budget_basis = "reference_uplink_budget_before_configured_module";
        row.p10_ebn0_db = step1.empiricalQuantile(ebn0, 0.1);
        row.median_ebn0_db = step1.empiricalQuantile(ebn0, 0.5);
        row.p10_margin_db = row.p10_ebn0_db - threshold;
        row.median_margin_db = row.median_ebn0_db - threshold;
        row.availability = stats.availability;
        row.availability_ci_low = stats.ci_low;
        row.availability_ci_high = stats.ci_high;
        row.availability_standard_error = stats.standard_error;
        row.availability_ci_method = stats.method;
        row.target_availability = options.target_availability;
        row.point_estimate_meets_target = stats.availability >= options.target_availability;
        row.threshold_payload_rate_bps = rate * stats.availability;
        row.outage_fraction = 1.0 - stats.availability;
        row.outage_burst_count = stats.burst_count;
        row.mean_outage_ms = stats.mean_burst_frames * frameMs;
        row.p95_outage_ms = stats.p95_burst_frames * frameMs;
        row.max_outage_ms = stats.max_burst_frames * frameMs;
        row.empirical_p_los = mean(channelTrace.los, "all");
        row.frame_duration_ms = frameMs;
        row.frames_per_replicate = n;
        row.replicates = replicates;
        row.total_frames = n * replicates;
        row.duration_per_replicate_s = n * frameMs / 1000.0;
        row.total_simulated_time_s = n * replicates * frameMs / 1000.0;
        row.random_seed_first = seeds(1);
        row.random_seed_last = seeds(end);
        row.rain_loss_db = rainDb;
        row.cfo_loss_db = cfoLossDb;
        row.handset_to_satellite_propagation_ms = oneHopMs;
        row.assumed_two_hop_propagation_ms = 2.0 * oneHopMs;
        row.assumed_two_hop_rtt_ms = 4.0 * oneHopMs;
        row.assumed_two_hop_plus_one_frame_ms = 2.0 * oneHopMs + frameMs;
        row.end_to_end_rf_availability = mean(chain.frames.end_to_end_rf_closed, 'all');
        row.end_to_end_availability = endToEndStats.availability;
        row.end_to_end_outage_fraction = 1 - endToEndStats.availability;
        row.end_to_end_model_source = "engineering_assumptions_not_measured_or_calibrated";
        row.assumed_call_one_way_ms = chain.delays.one_way_ms;
        row.assumed_call_rtt_ms = chain.delays.round_trip_ms;
        row.call_forward_delay_mean_ms = chain.delays.one_way_ms;
        row.call_return_delay_mean_ms = chain.delays.return_one_way_ms;
        row.call_forward_delay_p95_ms = chain.delays.p95_one_way_ms;
        row.call_return_delay_p95_ms = chain.delays.p95_return_one_way_ms;
        row.call_rtt_p95_ms = chain.delays.p95_round_trip_ms;
        summaryRows{summaryIndex} = struct2table(row);

        e2e = struct('scenario_key', string(sc.scenario_key), 'step1_key', string(sc.step1_key), ...
            'label', string(sc.label), 'voice_rate_bps', rate, ...
            'uplink_access_availability', stats.availability, ...
            'downlink_access_availability', mean(chain.frames.handset_downlink_closed, 'all'), ...
            'uplink_service_availability', mean(chain.frames.uplink_service_closed, 'all'), ...
            'downlink_service_availability', mean(chain.frames.downlink_service_closed, 'all'), ...
            'end_to_end_rf_availability', row.end_to_end_rf_availability, ...
            'end_to_end_availability', endToEndStats.availability, ...
            'end_to_end_availability_ci_low', endToEndStats.ci_low, ...
            'end_to_end_availability_ci_high', endToEndStats.ci_high, ...
            'end_to_end_availability_standard_error', endToEndStats.standard_error, ...
            'successful_frames', endToEndStats.successful_frames, 'lost_frames', endToEndStats.frame_errors, ...
            'total_frames', n * replicates, 'outage_fraction', 1 - endToEndStats.availability, ...
            'outage_burst_count', endToEndStats.burst_count, ...
            'mean_outage_ms', endToEndStats.mean_burst_frames * frameMs, ...
            'p95_outage_ms', endToEndStats.p95_burst_frames * frameMs, ...
            'max_outage_ms', endToEndStats.max_burst_frames * frameMs, ...
            'two_way_payload_rate_bps', rate * endToEndStats.availability, ...
            'assumed_call_one_way_ms', chain.delays.one_way_ms, ...
            'assumed_call_rtt_ms', chain.delays.round_trip_ms, ...
            'frames_per_replicate', n, 'replicates', replicates, ...
            'model_source', row.end_to_end_model_source);
        e2e.call_forward_delay_mean_ms = chain.delays.one_way_ms;
        e2e.call_return_delay_mean_ms = chain.delays.return_one_way_ms;
        e2e.call_forward_delay_p95_ms = chain.delays.p95_one_way_ms;
        e2e.call_return_delay_p95_ms = chain.delays.p95_return_one_way_ms;
        e2e.call_rtt_p95_ms = chain.delays.p95_round_trip_ms;
        e2e.delivered_forward_payload_rate_bps = mean(chain.frames.forward_payload_bits ...
            .* double(chain.frames.uplink_service_closed), 'all') * 1000 / frameMs;
        e2e.delivered_return_payload_rate_bps = mean(chain.frames.return_payload_bits ...
            .* double(chain.frames.downlink_service_closed), 'all') * 1000 / frameMs;
        endToEndRows{summaryIndex} = struct2table(e2e);
        stageRows = chain.stages;
        stageRows.scenario_key = repmat(string(sc.scenario_key), height(stageRows), 1);
        stageRows.voice_rate_bps = repmat(rate, height(stageRows), 1);
        chainStageRows{summaryIndex} = stageRows;
        comparisonRows{summaryIndex} = struct('scenario_key', string(sc.scenario_key), ...
            'voice_rate_bps', rate, 'frame_duration_ms', frameMs, ...
            'uplink_closed', closed, 'downlink_closed', chain.frames.handset_downlink_closed, ...
            'end_to_end_closed', chain.frames.end_to_end_closed, ...
            'forward_delay_ms', chain.frames.forward_delay_ms, 'return_delay_ms', chain.frames.return_delay_ms, ...
            'random_seed', double(cfg.seed), 'channel_random_seeds', seeds, ...
            'network_random_seeds', chain.network_seeds, 'module_random_seeds', chain.module_seeds);

        budgetRow = budget(rateIndex, :);
        budgetRow.scenario_key = string(sc.scenario_key);
        budgetRow.threshold_ebn0_db = threshold;
        budgetRow.threshold_source = thresholdSource;
        budgetRow.rain_loss_db = rainDb;
        budgetRow.cfo_loss_db = cfoLossDb;
        budgetRow.effective_ebn0_db = nominalEbN0;
        budgetRow.margin_db = nominalEbN0 - threshold;
        budgetRow.link_direction = "handset_to_satellite";
        budgetRows{summaryIndex} = budgetRow;

        if options.trace_points > 0
            % Keep a contiguous prefix so optional Simulink replay retains
            % the true frame clock; statistics always use all replicates.
            indices = (1:min(n, options.trace_points)).';
            count = numel(indices);
            traceRows{summaryIndex} = table( ...
                repmat(string(sc.scenario_key), count, 1), repmat(rate, count, 1), ...
                ones(count, 1), indices, (indices - 1) * frameMs / 1000.0, ...
                ebn0(indices, 1), repmat(threshold, count, 1), ...
                margin(indices, 1), closed(indices, 1), channelTrace.los(indices, 1), ...
                channelTrace.shadow_db(indices, 1), ...
                'VariableNames', {'scenario_key', 'voice_rate_bps', 'replicate_index', ...
                'frame_index', 'time_s', 'ebn0_db', 'threshold_ebn0_db', ...
                'margin_db', 'link_closed', 'los_state', 'shadow_db'});
            traceRows{summaryIndex}.reference_ebn0_db = referenceEbN0(indices, 1);
            frameNames = fieldnames(chain.frames);
            for frameNameIndex = 1:numel(frameNames)
                name = frameNames{frameNameIndex};
                traceRows{summaryIndex}.(name) = chain.frames.(name)(indices, 1);
            end
            traceRows{summaryIndex}.satellite_frame_loss_probability = ...
                repmat(chain.options.satellite_frame_loss_probability, count, 1);
            traceRows{summaryIndex}.ground_frame_loss_probability = ...
                repmat(chain.options.ground_frame_loss_probability, count, 1);
        end
        % Arbitrary modules need a real paired re-execution for each changed
        % reference budget. A threshold shortcut could silently bypass their
        % state, downstream signals, losses, or nonlinear device algorithms.
        for delta = options.link_delta_db
            sensitivityIndex = sensitivityIndex + 1;
            if delta == 0, adjustedChain = chain;
            else, adjustedChain = step1.designSystemChain(cfg, referenceMargin + delta, scenarioIndex, caseContext);
            end
            adjustedStats = localStats(adjustedChain.frames.handset_uplink_closed, sc, options.confidence_level);
            adjustedEndToEnd = localStats(adjustedChain.frames.end_to_end_closed, sc, options.confidence_level);
            adjustedEbN0 = referenceEbN0 + delta ...
                + (adjustedChain.frames.handset_uplink_margin_db - (referenceMargin + delta));
            sensitivityRows{sensitivityIndex} = table(string(sc.scenario_key), rate, ...
                delta, adjustedStats.availability, adjustedStats.ci_low, adjustedStats.ci_high, ...
                step1.empiricalQuantile(adjustedEbN0, 0.1) - threshold, ...
                step1.empiricalQuantile(adjustedEbN0, 0.5) - threshold, ...
                adjustedStats.max_burst_frames * frameMs, ...
                'VariableNames', {'scenario_key', 'voice_rate_bps', 'link_delta_db', ...
                'availability', 'availability_ci_low', 'availability_ci_high', ...
                'p10_margin_db', 'median_margin_db', 'max_outage_ms'});
            sensitivityRows{sensitivityIndex}.end_to_end_availability = adjustedEndToEnd.availability;
            sensitivityRows{sensitivityIndex}.end_to_end_max_outage_ms = adjustedEndToEnd.max_burst_frames * frameMs;
            clear adjustedChain;
        end
    end
end

results = struct();
results.summary = vertcat(summaryRows{:});
results.link_budget = vertcat(budgetRows{:});
results.end_to_end_summary = vertcat(endToEndRows{:});
results.chain_stages = vertcat(chainStageRows{:});
results.module_manifest = moduleManifest;
results.comparison_samples = vertcat(comparisonRows{:});
results.comparison_context = localComparisonContext(cfg, options);
if options.trace_points == 0
    results.trace = table();
else
    results.trace = vertcat(traceRows{:});
end
results.sensitivity = vertcat(sensitivityRows{:});
results.assumptions = struct( ...
    'model', "frame_level_geo_lms_configurable_module_screening_v3", ...
    'purpose', "system_design_trade_studies", ...
    'availability_definition', "configured_handset_uplink_module_local_success_fraction_default_is_EbN0_threshold", ...
    'threshold_source', thresholdSource, ...
    'threshold_ebn0_db', options.threshold_ebn0_db, ...
    'threshold_rate_order_bps', rates.', ...
    'waveform_calibrated', false, ...
    'decoded_frame_errors_simulated', false, ...
    'reverse_link_budget_available', false, ...
    'end_to_end_rf_availability', "design_estimate_four_RF_legs_using_assumed_reverse_offset_and_feeder_margins", ...
    'payload_rate_definition', "configured_payload_bps_times_threshold_closure_fraction_no_protocol_overhead", ...
    'channel', "stationary_LOS_NLOS_Markov_plus_AR1_shadow_and_frame_iid_Rician_Rayleigh_power", ...
    'channel_time_step_ms', frameMs, ...
    'cfo_model', "assumed_coherent_integration_loss_no_synchronizer_simulation", ...
    'uncertainty', "approximate_independent_replicate_t_interval_with_batch_means_SE_and_boundary_guard", ...
    'confidence_level', options.confidence_level, ...
    'uncertainty_scope', "Monte_Carlo_sampling_only_excludes_parameter_and_model_error_not_rare_outage_certification", ...
    'outage_definition', "contiguous_below_threshold_frames_within_each_replicate", ...
    'outage_boundary_policy', "replicates_not_joined_boundary_bursts_are_censored_observations", ...
    'trace', "contiguous_prefix_of_first_replicate_all_frames_and_replicates_used_for_statistics", ...
    'rate_and_sensitivity_comparison', "common_channel_and_network_samples_delta_applies_to_both_access_margins", ...
    'delay_model', "one_hop_d_over_c_two_hop_assumes_equal_ground_to_satellite_ranges_RTT_four_d_over_c", ...
    'delay_scope', "propagation_only_plus_separately_named_single_frame_assembly_excludes_network_and_processing", ...
    'options', options);
results.assumptions.system_chain = chain.assumptions;
results.assumptions.system_chain.options = chain.options;
results.assumptions.modules = table2struct(moduleManifest);
results.assumptions.module_interface = struct('version', "step1-frame-module-v1", ...
    'signature', "[out,state]=implementation(in,parameters,context,state)", ...
    'dispatch', "one_sequential_vector_call_per_stage_per_scenario_rate_and_replicate", ...
    'data_flow', "out_is_next_stage_in_including_signals_payload_valid_and_cumulative_delay", ...
    'availability', "actual_uplink_module_local_success_drives_availability_field", ...
    'margin_diagnostic', "actual_module_margin_plus_configured_threshold_is_EbN0_diagnostic_reference_EbN0_exported_separately", ...
    'sensitivity', "all_modules_reexecuted_with_paired_inputs_and_reset_streams_for_each_changed_reference_budget", ...
    'callback_failure', "propagates_without_fallback", 'provenance', "named_m_file_path_sha256_and_complete_effective_parameters");
results.assumptions.system_chain.delay_components_ms = struct( ...
    'handset_to_satellite_ms', chain.delays.handset_to_satellite_ms, ...
    'satellite_to_gateway_ms', chain.delays.satellite_to_gateway_ms, ...
    'frame_assembly_ms', chain.delays.frame_assembly_ms, ...
    'satellite_processing_ms', chain.delays.satellite_processing_ms, ...
    'ground_network_ms', chain.delays.ground_network_ms);
results.assumptions.system_chain.delay_components_scope = ...
    "default_reference_components_actual_module_delay_statistics_are_per_case_in_end_to_end_summary";
results.assumptions.system_chain.uncertainty = ...
    "same_replicate_t_batch_means_approximation_as_access_sampling_only_excludes_engineering_parameter_error";
end

function context = localComparisonContext(cfg, options)
physical = cfg;
ignored = intersect(fieldnames(physical), ...
    {'configPath'; 'configSha256'; 'baseConfigPath'; 'baseConfigSha256'; 'paths'; 'runtime'});
if ~isempty(ignored), physical = rmfield(physical, ignored); end
if isfield(physical, 'design')
    ignored = intersect(fieldnames(physical.design), {'modules'; 'simulink_overrides'});
    if ~isempty(ignored), physical.design = rmfield(physical.design, ignored); end
end
physical = localCanonicalFields(physical);
context = struct('schema_version', "step1-paired-design-context-v1", ...
    'physical_config_sha256', step1.io.sha256Text(string(jsonencode(physical))), ...
    'random_seed', double(cfg.seed), 'effective_sampling_options', options, ...
    'policy', "same_physical_config_and_samples_module_implementations_and_file_provenance_excluded");
end

function value = localCanonicalFields(value)
if isstruct(value)
    value = orderfields(value);
    names = fieldnames(value);
    for index = 1:numel(value)
        for fieldIndex = 1:numel(names)
            name = names{fieldIndex};
            value(index).(name) = localCanonicalFields(value(index).(name));
        end
    end
elseif iscell(value)
    for index = 1:numel(value), value{index} = localCanonicalFields(value{index}); end
end
end

function [snrDb, trace, seeds] = localChannel(cfg, sc, scenarioIndex, options)
n = options.frames_per_replicate;
r = options.replicates;
snrDb = zeros(n, r);
trace.los = false(n, r);
trace.shadow_db = zeros(n, r);
seeds = zeros(r, 1);
pathLoss = step1.fsplDb(cfg.link.distance_km, cfg.link.uplink_mhz);
noise = step1.noiseDbm(cfg.link.bandwidth_hz, cfg.link.nf_db, cfg.link.temperature_k);
for replicate = 1:r
    seeds(replicate) = mod(double(cfg.seed) + 1009 * scenarioIndex + ...
        104729 * replicate, 2^32);
    stream = RandStream("mt19937ar", "Seed", seeds(replicate));
    theta = min(max(sc.theta_mean_deg + sc.theta_std_deg * randn(stream, n, 1), 0), 80);
    los = false(n, 1);
    los(1) = rand(stream) < sc.p_los;
    transitionDraws = rand(stream, n - 1, 1);
    innovations = randn(stream, n, 1);
    shadow = zeros(n, 1);
    shadow(1) = sc.sigma_db * innovations(1);
    innovationScale = sc.sigma_db * sqrt(max(1 - sc.shadow_rho^2, 0));
    for frame = 2:n
        if los(frame - 1)
            los(frame) = transitionDraws(frame - 1) < sc.p_ll;
        else
            los(frame) = transitionDraws(frame - 1) >= sc.p_nn;
        end
        shadow(frame) = sc.shadow_rho * shadow(frame - 1) + innovationScale * innovations(frame);
    end
    k = 10^(sc.rician_k_db / 10);
    amplitude = (randn(stream, n, 1) + 1j * randn(stream, n, 1)) / sqrt(2);
    amplitude(los) = sqrt(k / (k + 1)) + amplitude(los) / sqrt(k + 1);
    fadingDb = 10 * log10(max(abs(amplitude).^2, cfg.channel.min_power_gain));
    snrDb(:, replicate) = cfg.link.pt_dbm + step1.orientationGainDb(theta, cfg) ...
        + cfg.link.sat_gr_dbi - pathLoss - cfg.link.pol_loss_db ...
        - cfg.link.extra_loss_db - noise - shadow - double(~los) * sc.nlos_loss_db + fadingDb;
    trace.los(:, replicate) = los;
    trace.shadow_db(:, replicate) = shadow;
end
end

function stats = localStats(closed, sc, confidence)
% A stationary terminal can have rho=1: its shadow draw is constant within
% each replicate. The tiny clip only regularizes the existing block-length
% arithmetic; independent replicates still supply the variance estimate.
statsScenario = sc;
statsScenario.shadow_rho = min(sc.shadow_rho, 1 - eps);
stats = step1.correlatedAvailabilityStats(closed, statsScenario, confidence);
degrees = size(closed, 2) - 1;
betaValue = betaincinv(1 - confidence, degrees / 2, 0.5);
critical = sqrt(degrees * (1 / betaValue - 1));
stats.ci_low = max(0, stats.availability - critical * stats.standard_error);
stats.ci_high = min(1, stats.availability + critical * stats.standard_error);
% An all-open/all-closed short sample must not imply certain reliability.
% At this boundary use a conservative channel-correlation effective count
% for a Wilson guard, in addition to the replicate interval. This remains
% a model-conditioned approximation, not a guarantee of nominal coverage.
if stats.availability == 0 || stats.availability == 1
    effectiveCount = floor(size(closed, 2) * max(1, size(closed, 1) / stats.correlation_inflation));
    [low, high] = step1.binomialWilson(stats.availability * effectiveCount, effectiveCount, confidence);
    stats.ci_low = min(stats.ci_low, low);
    stats.ci_high = max(stats.ci_high, high);
end
stats.method = "independent_replicate_t_batch_means_boundary_guard_approximate";
end
