classdef TestStep1DesignSystemChain < matlab.unittest.TestCase
    % End-to-end stage fault injection and deterministic macro-model contracts.
    methods (TestClassSetup)
        function addProjectPaths(~)
            addpath(fileparts(fileparts(mfilename('fullpath'))));
        end
    end
    methods (Test)
        function moduleResolutionAndChainShareEngineeringDefaults(testCase)
            cfg = localConfig();
            cfg.design = rmfield(cfg.design, 'system_chain');
            options = step1.systemChainOptions(cfg);
            [specs, ~] = step1.modules.resolve(cfg);
            testCase.verifyEqual(specs(2).parameters.loss_probability, options.satellite_frame_loss_probability);
            testCase.verifyEqual(specs(4).parameters.loss_probability, options.ground_frame_loss_probability);
            implicit = step1.designSystemChain(cfg, ones(20, 2), 1);
            cfg.design.system_chain = options;
            explicit = step1.designSystemChain(cfg, ones(20, 2), 1);
            testCase.verifyEqual(implicit.frames, explicit.frames);
            testCase.verifyEqual(implicit.delays, explicit.delays);
            cfg.design.system_chain = struct('satellite_frame_loss_probability',0.25, ...
                'ground_frame_loss_probability',0.4);
            [specs, ~] = step1.modules.resolve(cfg);
            overridden = step1.designSystemChain(cfg, ones(20, 2), 1);
            testCase.verifyEqual(specs(2).parameters.loss_probability, 0.25);
            testCase.verifyEqual(specs(4).parameters.loss_probability, 0.4);
            testCase.verifyEqual(overridden.frames.satellite_forward_closed, ...
                overridden.frames.satellite_forward_draw >= specs(2).parameters.loss_probability);
            testCase.verifyEqual(overridden.frames.ground_return_closed, ...
                overridden.frames.ground_return_draw >= specs(5).parameters.loss_probability);
            testCase.verifyEqual(overridden.options.gateway_slant_range_km, options.gateway_slant_range_km);
        end

        function malformedEngineeringAssumptionsFailAtEveryEntry(testCase)
            cfg = localConfig();
            cfg.design.system_chain.ground_frame_loss_probability = 1.01;
            testCase.verifyError(@() step1.systemChainOptions(cfg), 'step1:DesignSystemChain');
            testCase.verifyError(@() step1.modules.resolve(cfg), 'step1:DesignSystemChain');
            testCase.verifyError(@() step1.validateConfig(cfg), 'step1:DesignSystemChain');
            testCase.verifyError(@() step1.designSystemChain(cfg, ones(4, 2), 1), 'step1:DesignSystemChain');
        end

        function transparentStagesPreserveAccessAndReplicateDimensions(testCase)
            cfg = localConfig();
            margins = [-1 1; 0 1; 1 -1; 2 -1];
            chain = step1.designSystemChain(cfg, margins, 1);
            testCase.verifySize(chain.frames.end_to_end_closed, [4 2]);
            testCase.verifyEqual(chain.frames.end_to_end_closed, margins >= 0);
            testCase.verifyEqual(mean(chain.frames.end_to_end_closed, 'all'), 5/8);
            testCase.verifyEqual(chain.frames.downlink_margin_db, margins + 3);
            testCase.verifyEqual(chain.stages.total_frames, repmat(8, 8, 1));
            testCase.verifyEqual(chain.stages.cumulative_direction_availability(4), ...
                mean(chain.frames.uplink_service_closed, 'all'));
            testCase.verifyEqual(chain.stages.cumulative_direction_availability(8), ...
                mean(chain.frames.downlink_service_closed, 'all'));
        end

        function everyRfLegCanIndependentlyPreventTwoWayService(testCase)
            cfg = localConfig();
            baseline = step1.designSystemChain(cfg, ones(20, 2), 1);
            testCase.verifyTrue(all(baseline.frames.end_to_end_closed, 'all'));
            noUplink = step1.designSystemChain(cfg, -ones(20, 2), 1);
            testCase.verifyFalse(any(noUplink.frames.end_to_end_closed, 'all'));
            testCase.verifyTrue(all(noUplink.frames.downlink_service_closed, 'all'));
            for field = ["feeder_uplink_margin_db", "feeder_downlink_margin_db", "downlink_margin_offset_db"]
                blockedCfg = cfg;
                blockedCfg.design.system_chain.(field) = -10;
                blocked = step1.designSystemChain(blockedCfg, ones(20, 2), 1);
                testCase.verifyFalse(any(blocked.frames.end_to_end_closed, 'all'));
                testCase.verifyTrue(all(blocked.frames.handset_uplink_closed, 'all'));
                testCase.verifyFalse(any(blocked.frames.end_to_end_rf_closed, 'all'));
            end
        end

        function relayAndGroundOutagesBlockServiceWithoutChangingRf(testCase)
            cfg = localConfig();
            for field = ["satellite_frame_loss_probability", "ground_frame_loss_probability"]
                blockedCfg = cfg;
                blockedCfg.design.system_chain.(field) = 1;
                chain = step1.designSystemChain(blockedCfg, ones(20, 2), 1);
                testCase.verifyTrue(all(chain.frames.end_to_end_rf_closed, 'all'));
                testCase.verifyFalse(any(chain.frames.end_to_end_closed, 'all'));
                testCase.verifyFalse(any(chain.frames.uplink_service_closed, 'all'));
                testCase.verifyFalse(any(chain.frames.downlink_service_closed, 'all'));
            end
        end

        function networkSamplingMatchesTwoDirectionLossLaw(testCase)
            cfg = localConfig();
            cfg.design.system_chain.satellite_frame_loss_probability = 0.2;
            cfg.design.system_chain.ground_frame_loss_probability = 0.1;
            chain = step1.designSystemChain(cfg, ones(10000, 4), 3);
            testCase.verifyEqual(mean(chain.frames.end_to_end_closed, 'all'), ...
                0.8^2 * 0.9^2, 'AbsTol', 0.012);
            testCase.verifyEqual(chain.frames.satellite_forward_closed, ...
                chain.frames.satellite_forward_draw >= 0.2);
            testCase.verifyEqual(chain.frames.ground_return_closed, ...
                chain.frames.ground_return_draw >= 0.1);
            testCase.verifyNotEqual(chain.frames.ground_forward_draw, chain.frames.ground_return_draw);
            testCase.verifyNotEqual(chain.frames.ground_forward_draw(:, 1), chain.frames.ground_forward_draw(:, 2));
        end

        function networkSeedIsStableAndIsolatedFromGlobalRng(testCase)
            cfg = localConfig();
            before = rng;
            first = step1.designSystemChain(cfg, ones(100, 2), 2);
            second = step1.designSystemChain(cfg, 4 * ones(100, 2), 2);
            testCase.verifyEqual(rng, before);
            testCase.verifyEqual(first.frames.ground_forward_draw, second.frames.ground_forward_draw);
            testCase.verifyEqual(first.frames.satellite_return_draw, second.frames.satellite_return_draw);
            other = step1.designSystemChain(cfg, ones(100, 2), 3);
            testCase.verifyNotEqual(first.frames.ground_forward_draw, other.frames.ground_forward_draw);
        end

        function successfulFrameLatencyIncludesEachConfiguredStageOnce(testCase)
            cfg = localConfig();
            chain = step1.designSystemChain(cfg, ones(4, 2), 1);
            expected = (cfg.link.distance_km + cfg.design.system_chain.gateway_slant_range_km) ...
                / 299792.458 * 1000 + cfg.channel.frame_duration_ms ...
                + cfg.design.system_chain.satellite_processing_ms + cfg.design.system_chain.ground_network_ms;
            testCase.verifyEqual(chain.delays.one_way_ms, expected, 'AbsTol', 1e-10);
            testCase.verifyEqual(chain.delays.round_trip_ms, 2 * expected, 'AbsTol', 1e-10);
            testCase.verifyFalse(chain.assumptions.reverse_rf_budget_calibrated);
            testCase.verifyTrue(chain.assumptions.parameters_are_engineering_assumptions);
        end

        function rejectsInvalidProbabilitiesDelaysAndAccessInput(testCase)
            cfg = localConfig();
            for value = [-0.1 1.1 NaN Inf]
                invalid = cfg;
                invalid.design.system_chain.ground_frame_loss_probability = value;
                testCase.verifyError(@() step1.designSystemChain(invalid, ones(4, 2), 1), 'step1:DesignSystemChain');
            end
            cfg.design.system_chain.satellite_processing_ms = -1;
            testCase.verifyError(@() step1.designSystemChain(cfg, ones(4, 2), 1), 'step1:DesignSystemChain');
            cfg = localConfig();
            testCase.verifyError(@() step1.designSystemChain(cfg, [1 NaN], 1), 'step1:DesignSystemChain');
            testCase.verifyError(@() step1.designSystemChain(cfg, ones(4, 2), 0), 'step1:DesignSystemChain');
        end
    end
end

function cfg = localConfig()
cfg = step1.loadConfig("", "design");
cfg.design.system_chain.satellite_frame_loss_probability = 0;
cfg.design.system_chain.ground_frame_loss_probability = 0;
end
