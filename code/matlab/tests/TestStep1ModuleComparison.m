classdef TestStep1ModuleComparison < matlab.unittest.TestCase
    methods(TestClassSetup)
        function paths(~)
            addpath(fileparts(fileparts(mfilename('fullpath'))));
        end
    end
    methods(Test)
        function identicalModulesHaveExactlyZeroPairedDifference(testCase)
            cfg = smallConfig();
            result = step1.designScreening(cfg);
            rows = step1.compareDesignResults(result,result);
            testCase.verifyEqual(height(rows),15);
            testCase.verifyEqual(rows.availability_delta_pp,zeros(15,1));
            testCase.verifyEqual(rows.improved_frames+rows.regressed_frames,zeros(15,1));
            testCase.verifyEqual(rows.unchanged_frames,rows.paired_frames);
            testCase.verifyEqual(rows.forward_delay_delta_ms,zeros(15,1));
        end
        function replacementGainImprovesFramesAndPropagatesDelay(testCase)
            cfg = smallConfig();
            base = step1.designScreening(cfg);
            cfg.design.modules.handset_uplink = struct( ...
                'implementation','step1.examples.rfDevice', ...
                'parameters',struct('margin_gain_db',3,'extra_delay_ms',5));
            cand = step1.designScreening(cfg);
            rows = step1.compareDesignResults(base,cand);
            testCase.verifyEqual(rows.regressed_frames,zeros(15,1));
            testCase.verifyGreaterThan(sum(rows.improved_frames),0);
            testCase.verifyEqual(rows.forward_delay_delta_ms,5*ones(15,1),'AbsTol',1e-10);
            testCase.verifyEqual(rows.return_delay_delta_ms,zeros(15,1),'AbsTol',1e-10);
            testCase.verifyEqual(rows.availability_delta_pp, ...
                100*(rows.improved_frames-rows.regressed_frames)./rows.paired_frames,'AbsTol',1e-10);
            testCase.verifyTrue(any(string(cand.module_manifest.implementation) == "step1.examples.rfDevice"));
        end
        function addedLossIsVisibleInPairedComparison(testCase)
            cfg = smallConfig();
            base = step1.designScreening(cfg);
            cfg.design.modules.ground_return = struct( ...
                'implementation','step1.modules.transfer', ...
                'parameters',struct('loss_probability',1));
            cand = step1.designScreening(cfg);
            rows = step1.compareDesignResults(base,cand);
            testCase.verifyEqual(rows.candidate_availability,zeros(15,1));
            testCase.verifyEqual(rows.improved_frames,zeros(15,1));
            testCase.verifyGreaterThan(sum(rows.regressed_frames),0);
        end
        function differentSeedsCannotBeAdvertisedAsPaired(testCase)
            cfg = smallConfig();
            base = step1.designScreening(cfg);
            cfg.seed = cfg.seed+1;
            cand = step1.designScreening(cfg);
            testCase.verifyError(@()step1.compareDesignResults(base,cand),'step1:ComparisonContext');
        end
        function probabilityCurveEndpointsAndReproducibility(testCase)
            cfg = smallConfig();
            cfg.design.modules.handset_downlink = struct( ...
                'implementation','step1.examples.deviceCurve', ...
                'parameters',struct('margin_db',[-100 100],'success_probability',[0 0]));
            a = step1.designScreening(cfg);
            b = step1.designScreening(cfg);
            testCase.verifyEqual(a.end_to_end_summary.end_to_end_availability,zeros(15,1));
            rows = step1.compareDesignResults(a,b);
            testCase.verifyEqual(sum(rows.regressed_frames+rows.improved_frames),0);
            cfg.design.modules.handset_downlink.parameters.success_probability = [1 1];
            c = step1.designScreening(cfg);
            testCase.verifyEqual(c.end_to_end_summary.downlink_access_availability,ones(15,1));
        end
        function comparisonDoesNotUseTruncatedTrace(testCase)
            cfg = smallConfig();
            cfg.design.trace_points = 0;
            a = step1.designScreening(cfg);
            rows = step1.compareDesignResults(a,a);
            testCase.verifyEmpty(a.trace);
            testCase.verifyEqual(rows.paired_frames, ...
                cfg.design.frames_per_replicate*cfg.design.replicates*ones(15,1));
        end
    end
end
function cfg = smallConfig()
cfg = step1.loadConfig('', 'design');
cfg.design.frames_per_replicate = 300;
cfg.design.replicates = 2;
cfg.design.trace_points = 100;
cfg.design.link_delta_db = 0;
end
