classdef TestStep1DesignBudget < matlab.unittest.TestCase
    methods(TestClassSetup)
        function paths(~)
            addpath(fileparts(fileparts(mfilename('fullpath'))));
        end
    end
    methods(Test)
        function omittedSamplingFieldsMatchTheirExplicitDefaults(testCase)
            cfg = step1.loadConfig('', 'design');
            names = {'frames_per_replicate','replicates','trace_points', ...
                'threshold_ebn0_db','link_delta_db','confidence_level','target_availability'};
            cfg.design = rmfield(cfg.design, intersect(fieldnames(cfg.design), names));
            [sampling, work] = step1.designOptions(cfg);
            testCase.verifyEqual([sampling.frames_per_replicate,sampling.replicates,sampling.trace_points], [1500,4,300]);
            testCase.verifyEqual(sampling.threshold_ebn0_db, cfg.voice.legacy_threshold_ebn0_db);
            implicit = step1.designBudget(cfg);
            for name = string(fieldnames(sampling)).', cfg.design.(name) = sampling.(name); end
            testCase.verifyEqual(step1.designBudget(cfg), implicit);
            testCase.verifyEqual(implicit.channel_frames, work.channel_frames);
            testCase.verifyEqual(implicit.export_trace_rows, work.export_trace_rows);
            testCase.verifyEqual(implicit.case_sensitivity_frames, work.case_sensitivity_frames);
            % The design threshold is sufficient when no voice threshold is supplied.
            cfg.voice = rmfield(cfg.voice, 'legacy_threshold_ebn0_db');
            testCase.verifyEqual(step1.designBudget(cfg), implicit);
        end
        function entryPointsShareSamplingAndWorkLimits(testCase)
            baseline = step1.loadConfig('', 'design');
            variants = {struct('frames_per_replicate',200.5), ...
                struct('link_delta_db',0:21), ...
                struct('frames_per_replicate',20000,'replicates',16), ...
                struct('frames_per_replicate',20000,'replicates',2,'trace_points',20000)};
            for index = 1:numel(variants)
                cfg = baseline;
                supplied = variants{index};
                for name = string(fieldnames(supplied)).', cfg.design.(name) = supplied.(name); end
                testCase.verifyError(@() step1.designScreening(cfg), 'step1:DesignOptions');
                testCase.verifyError(@() step1.designBudget(cfg), 'step1:DesignBudget');
                testCase.verifyError(@() step1.validateConfig(cfg), 'step1:DesignBudget');
            end
        end
        function defaultsReserveMemoryForMatlabAndOs(testCase)
            cfg = step1.loadConfig('', 'design');
            b = step1.designBudget(cfg);
            testCase.verifyEqual(b.launch_to_exit_limit_seconds, 600);
            testCase.verifyEqual(b.process_tree_limit_bytes, 8*1024^3);
            testCase.verifyLessThan(b.estimated_array_bytes, 256*1024^2);
            testCase.verifyFalse(b.gpu_required);
            testCase.verifyFalse(b.parallel_pool_required);
        end
        function maximumPermittedFramesHaveBoundedEstimate(testCase)
            cfg = step1.loadConfig('', 'design');
            cfg.design.frames_per_replicate = 20000;
            cfg.design.replicates = 5;
            cfg.design.trace_points = 1500;
            b = step1.designBudget(cfg);
            testCase.verifyEqual(b.channel_frames, 500000);
            testCase.verifyLessThan(b.estimated_array_bytes, 1024^3);
        end
        function rejectsBudgetExpansionAndMalformedValues(testCase)
            cfg = step1.loadConfig('', 'design');
            cfg.design.resource_budget.matlab_seconds = 601;
            testCase.verifyError(@() step1.designBudget(cfg), 'step1:DesignBudget');
            cfg.design.resource_budget.matlab_seconds = NaN;
            testCase.verifyError(@() step1.designBudget(cfg), 'step1:DesignBudget');
            cfg.design.resource_budget.matlab_seconds = 540;
            cfg.design.resource_budget.estimated_array_limit_mib = 2048;
            testCase.verifyError(@() step1.designBudget(cfg), 'step1:DesignBudget');
        end
        function rejectsWorkBeforeLargeAllocation(testCase)
            cfg = step1.loadConfig('', 'design');
            cfg.design.frames_per_replicate = 20000;
            cfg.design.replicates = 16;
            testCase.verifyError(@() step1.designBudget(cfg), 'step1:DesignBudget');
            cfg.design.frames_per_replicate = 1500;
            cfg.design.replicates = 4;
            cfg.design.resource_budget.estimated_array_limit_mib = 1;
            testCase.verifyError(@() step1.designBudget(cfg), 'step1:DesignBudget');
        end
        function deadlineCannotBecomeSuccessfulCompletion(testCase)
            cfg = step1.loadConfig('', 'design');
            b = step1.designBudget(cfg);
            clock = tic;
            b.matlab_seconds = -1; % Already-expired budget without sleeping.
            testCase.verifyError(@() step1.checkDesignBudget(b,clock,'export'), 'step1:DesignTimeout');
        end
    end
end
