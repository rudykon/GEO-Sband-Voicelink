classdef TestStep1DesignScreening < matlab.unittest.TestCase
    % Physical and sampling contracts for the inexpensive design entry point.
    methods (TestClassSetup)
        function addProjectPaths(~)
            addpath(fileparts(fileparts(mfilename('fullpath'))));
        end
    end

    methods (Test)
        function coversFiveScenariosAndThreeRatesWithoutWaveformInputs(testCase)
            cfg = localConfig();
            waveformFields = intersect(fieldnames(cfg), {'phy'; 'synchronization'; 'runtime'; 'extensions'});
            if ~isempty(waveformFields), cfg = rmfield(cfg, waveformFields); end
            result = step1.designScreening(cfg);
            testCase.verifyEqual(height(result.summary), 15);
            testCase.verifyEqual(height(result.link_budget), 15);
            testCase.verifyEqual(height(result.sensitivity), 45);
            keys = result.summary.scenario_key + "|" + result.summary.voice_rate_bps;
            testCase.verifyEqual(numel(unique(keys)), 15);
            testCase.verifyEqual(result.summary.total_frames, repmat(400, 15, 1));
            testCase.verifyFalse(result.assumptions.waveform_calibrated);
            testCase.verifyTrue(all(isfinite(result.summary.end_to_end_rf_availability)));
            testCase.verifyFalse(result.assumptions.system_chain.reverse_rf_budget_calibrated);
            testCase.verifyEqual(height(result.end_to_end_summary), 15);
            testCase.verifyEqual(height(result.chain_stages), 120);
            testCase.verifyLessThanOrEqual(result.summary.end_to_end_availability, result.summary.availability);
            testCase.verifyFalse(ismember('downlink_mhz', result.link_budget.Properties.VariableNames));
        end

        function seededRunsPreserveGlobalRngAndRepeatExactly(testCase)
            cfg = localConfig();
            before = rng;
            first = step1.designScreening(cfg);
            testCase.verifyEqual(rng, before);
            second = step1.designScreening(cfg);
            testCase.verifyEqual(first.summary, second.summary);
            testCase.verifyEqual(first.trace, second.trace);
            testCase.verifyEqual(first.sensitivity, second.sensitivity);
            testCase.verifyEqual(first.end_to_end_summary, second.end_to_end_summary);
            testCase.verifyEqual(first.chain_stages, second.chain_stages);
        end

        function powerTradeIsPairedAndPhysicallyMonotone(testCase)
            cfg = localConfig();
            baseline = step1.designScreening(cfg);
            cfg.link.pt_dbm = cfg.link.pt_dbm + 3;
            stronger = step1.designScreening(cfg);
            testCase.verifyEqual(stronger.summary.p10_margin_db - baseline.summary.p10_margin_db, ...
                repmat(3, 15, 1), 'AbsTol', 1e-10);
            testCase.verifyGreaterThanOrEqual(stronger.summary.availability, baseline.summary.availability);
            zero = baseline.sensitivity(baseline.sensitivity.link_delta_db == 0, :);
            plus = baseline.sensitivity(baseline.sensitivity.link_delta_db == 3, :);
            testCase.verifyEqual(zero.availability, baseline.summary.availability);
            testCase.verifyEqual(plus.availability, stronger.summary.availability);
            testCase.verifyEqual(zero.end_to_end_availability, baseline.summary.end_to_end_availability);
            testCase.verifyEqual(plus.end_to_end_availability, stronger.summary.end_to_end_availability);
            testCase.verifyGreaterThanOrEqual(stronger.summary.end_to_end_availability, ...
                baseline.summary.end_to_end_availability);
            testCase.verifyEqual(baseline.summary.threshold_payload_rate_bps, ...
                baseline.summary.voice_rate_bps .* baseline.summary.availability);
        end

        function delayAndPayloadEbN0UseTheirPhysicalDefinitions(testCase)
            cfg = localConfig();
            result = step1.designScreening(cfg);
            rows = result.summary;
            oneHop = cfg.link.distance_km / 299792.458 * 1000;
            testCase.verifyEqual(rows.handset_to_satellite_propagation_ms, repmat(oneHop, 15, 1), 'AbsTol', 1e-10);
            testCase.verifyEqual(rows.assumed_two_hop_propagation_ms, 2 * rows.handset_to_satellite_propagation_ms);
            testCase.verifyEqual(rows.assumed_two_hop_rtt_ms, 4 * rows.handset_to_satellite_propagation_ms);
            budget = result.link_budget;
            testCase.verifyEqual(budget.ebn0_db, budget.snr_db + ...
                10 * log10(budget.bandwidth_hz ./ budget.voice_rate_bps), 'AbsTol', 1e-10);
            trace = result.trace;
            testCase.verifyEqual(trace.link_closed, trace.margin_db >= 0);
            testCase.verifyEqual(trace.margin_db, trace.ebn0_db - trace.threshold_ebn0_db);
            testCase.verifyEqual(trace.end_to_end_closed, trace.uplink_service_closed & trace.downlink_service_closed);
            testCase.verifyEqual(trace.downlink_margin_db, trace.margin_db + ...
                cfg.design.system_chain.downlink_margin_offset_db);
            e2e = result.end_to_end_summary;
            testCase.verifyEqual(e2e.successful_frames + e2e.lost_frames, e2e.total_frames);
            testCase.verifyEqual(e2e.end_to_end_availability, e2e.successful_frames ./ e2e.total_frames);
            expectedOneWay = oneHop + cfg.design.system_chain.gateway_slant_range_km / 299792.458 * 1000 ...
                + cfg.channel.frame_duration_ms + cfg.design.system_chain.satellite_processing_ms ...
                + cfg.design.system_chain.ground_network_ms;
            testCase.verifyEqual(e2e.assumed_call_one_way_ms, repmat(expectedOneWay, 15, 1), 'AbsTol', 1e-10);
            testCase.verifyEqual(e2e.assumed_call_rtt_ms, 2 * e2e.assumed_call_one_way_ms);
        end

        function outageBurstsStopAtIndependentReplicateBoundaries(testCase)
            cfg = localConfig();
            cfg.design.threshold_ebn0_db = [1000 1000 1000];
            failed = step1.designScreening(cfg);
            testCase.verifyEqual(failed.summary.availability, zeros(15, 1));
            testCase.verifyEqual(failed.summary.outage_burst_count, repmat(2, 15, 1));
            testCase.verifyEqual(failed.summary.max_outage_ms, ...
                repmat(cfg.design.frames_per_replicate * cfg.channel.frame_duration_ms, 15, 1));
            testCase.verifyGreaterThan(failed.summary.availability_ci_high, zeros(15, 1));
            testCase.verifyEqual(failed.end_to_end_summary.outage_burst_count, repmat(2, 15, 1));
            testCase.verifyEqual(failed.end_to_end_summary.max_outage_ms, ...
                repmat(cfg.design.frames_per_replicate * cfg.channel.frame_duration_ms, 15, 1));
            cfg.design.threshold_ebn0_db = [-1000 -1000 -1000];
            closed = step1.designScreening(cfg);
            testCase.verifyEqual(closed.summary.availability, ones(15, 1));
            testCase.verifyEqual(closed.summary.max_outage_ms, zeros(15, 1));
            testCase.verifyLessThan(closed.summary.availability_ci_low, ones(15, 1));
        end

        function rejectsMalformedOrOversizedDesignOptions(testCase)
            cfg = localConfig();
            cfg.design.frames_per_replicate = 200.5;
            testCase.verifyError(@() step1.designScreening(cfg), 'step1:DesignOptions');
            cfg = localConfig();
            cfg.design.replicates = 1;
            testCase.verifyError(@() step1.designScreening(cfg), 'step1:DesignOptions');
            cfg = localConfig();
            cfg.design.threshold_ebn0_db = [1 2];
            testCase.verifyError(@() step1.designScreening(cfg), 'step1:DesignOptions');
            cfg = localConfig();
            cfg.design.frames_per_replicate = 20000;
            cfg.design.replicates = 16;
            testCase.verifyError(@() step1.designScreening(cfg), 'step1:DesignOptions');
            cfg = localConfig();
            cfg.design.frames_per_replicate = 20000;
            cfg.design.trace_points = 20000;
            testCase.verifyError(@() step1.designScreening(cfg), 'step1:DesignOptions');
            cfg = localConfig();
            cfg.design.frames_per_replicate = 20000;
            cfg.design.replicates = 4;
            cfg.design.trace_points = 0;
            cfg.design.link_delta_db = -10:10;
            testCase.verifyError(@() step1.designScreening(cfg), 'step1:DesignOptions');
            cfg = localConfig();
            cfg.voice.rate_bps = 1000:1000:21000;
            cfg.design.threshold_ebn0_db = zeros(1, 21);
            testCase.verifyError(@() step1.designScreening(cfg), 'step1:DesignOptions');
        end

        function supportsNoTraceAndStationaryTerminal(testCase)
            cfg = localConfig();
            cfg.design.trace_points = 0;
            cfg.scenarios(1).shadow_rho = 1;
            result = step1.designScreening(cfg);
            testCase.verifyEmpty(result.trace);
            testCase.verifyGreaterThanOrEqual(result.summary.availability_ci_low, zeros(15, 1));
            testCase.verifyLessThanOrEqual(result.summary.availability_ci_high, ones(15, 1));
            cfg.design.trace_points = 200;
            traced = step1.designScreening(cfg);
            testCase.verifyEqual(traced.end_to_end_summary, result.end_to_end_summary);
            testCase.verifyEqual(traced.chain_stages, result.chain_stages);
        end

        function reverseLegFailureCanBlockAnOtherwiseClosedUplink(testCase)
            cfg = localConfig();
            cfg.design.threshold_ebn0_db = [-1000 -1000 -1000];
            cfg.design.system_chain.downlink_margin_offset_db = -10000;
            result = step1.designScreening(cfg);
            testCase.verifyEqual(result.summary.availability, ones(15, 1));
            testCase.verifyEqual(result.summary.end_to_end_availability, zeros(15, 1));
            testCase.verifyEqual(result.summary.end_to_end_rf_availability, zeros(15, 1));
            testCase.verifyEqual(result.end_to_end_summary.outage_burst_count, repmat(2, 15, 1));
            testCase.verifyEqual(result.end_to_end_summary.lost_frames, repmat(400, 15, 1));
        end
    end
end

function cfg = localConfig()
cfg = step1.loadConfig("", "design");
cfg.design.frames_per_replicate = 200;
cfg.design.replicates = 2;
cfg.design.trace_points = 10;
cfg.design.link_delta_db = [-3 0 3];
end
