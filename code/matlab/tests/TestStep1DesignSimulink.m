classdef TestStep1DesignSimulink < matlab.unittest.TestCase
    % Execute native Simulink blocks, including reruns without caller state.
    properties
        Config
        Results
        Folder
        Validation
        CacheCleanup
    end
    methods (TestClassSetup)
        function simulateDefaultChain(testCase)
            addpath(fileparts(fileparts(mfilename('fullpath'))));
            testCase.assumeTrue(~isempty(which('new_system')) && license('test', 'Simulink'), ...
                'Simulink must be installed and licensed for the requested native model tests.');
            fixture = testCase.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            testCase.Folder = string(fixture.Folder);
            testCase.CacheCleanup = step1.useSimulinkCache(fullfile(testCase.Folder,'simulink-cache'));
            testCase.addTeardown(@() localReleaseCache(testCase));
            cfg = step1.loadConfig("", "design");
            cfg.design.frames_per_replicate = 1500;
            cfg.design.trace_points = 1500;
            testCase.Config = cfg;
            testCase.Results = step1.designScreening(cfg);
            testCase.Validation = step1.runDesignSimulink(cfg, testCase.Results, testCase.Folder);
        end
    end
    methods (Test)
        function coversAllFifteenCasesAndEveryFirstReplicateFrame(testCase)
            validation = testCase.Validation;
            testCase.verifyEqual(validation.status, 'completed');
            testCase.verifyEqual(validation.coverage_count, 15);
            testCase.verifyEqual(validation.samples_per_case, 1500);
            testCase.verifyEqual(validation.simulation_steps, 1500);
            testCase.verifyEqual(validation.samples, 22500);
            testCase.verifyEqual(validation.stage_count, 8);
            testCase.verifyEqual(validation.aggregate_decision_count, 4);
            testCase.verifyEqual(validation.native_module_count, 8);
            testCase.verifyEqual(validation.adapter_replay_count, 0);
            testCase.verifyTrue(validation.full_first_replicate_covered);
            testCase.verifyTrue(validation.all_configured_cases_covered);
            testCase.verifyEqual(validation.decision_mismatches, 0);
            testCase.verifyLessThanOrEqual(validation.max_abs_margin_difference, 1e-10);
            coverage = struct2table(validation.coverage);
            testCase.verifyEqual(numel(unique(coverage.scenario_key + "|" + coverage.voice_rate_bps)), 15);
            testCase.verifyEqual(coverage.frames_checked, repmat(1500, 15, 1));
            testCase.verifyTrue(isfile(validation.model_path));
        end

        function savedModelRerunsFromItsOwnWorkspace(testCase)
            [~, model] = fileparts(testCase.Validation.model_path);
            testCase.verifyFalse(bdIsLoaded(model));
            load_system(testCase.Validation.model_path);
            cleanup = onCleanup(@() localClose(model)); %#ok<NASGU>
            workspace = get_param(model, 'ModelWorkspace');
            testCase.verifyEqual(string(workspace.DataSource), "Model File");
            testCase.verifyEqual(string(get_param(model, 'Solver')), "FixedStepDiscrete");
            testCase.verifyEqual(str2double(get_param(model, 'FixedStep')), ...
                testCase.Config.channel.frame_duration_ms / 1000);
            testCase.verifyEmpty(find_system(model, 'BlockType', 'ModelReference'));
            testCase.verifyEmpty(find_system(model, 'BlockType', 'S-Function'));
            for stage = localStages()
                block = model+"/"+stage;
                testCase.verifyEqual(string(get_param(block,'BlockType')), "SubSystem");
                testCase.verifyEqual(string(get_param(block,'TreatAsAtomicUnit')), "on");
                testCase.verifyEqual(numel(find_system(block,'SearchDepth',1,'BlockType','Inport')), 6);
                testCase.verifyEqual(numel(find_system(block,'SearchDepth',1,'BlockType','Outport')), 5);
            end
            % No assignment to base workspace or SimulationInput is performed.
            rerun = sim(model);
            trace = testCase.Results.trace;
            expected = reshape(trace.end_to_end_closed, 1500, 15);
            testCase.verifyEqual(logical(rerun.get('design_end_to_end_closed')), expected);
            testCase.verifyEqual(size(rerun.get('design_margin_db')), [1500 15]);
        end

        function rejectsTamperedEveryIntermediateAndFinalDecision(testCase)
            [cfg, result] = localShortTrace(testCase, 4);
            names = ["link_closed", "handset_uplink_closed", "satellite_forward_closed", ...
                "feeder_downlink_closed", "ground_forward_closed", "ground_return_closed", ...
                "feeder_uplink_closed", "satellite_return_closed", "handset_downlink_closed", ...
                "uplink_service_closed", "downlink_service_closed", "end_to_end_rf_closed", "end_to_end_closed"];
            for name = names
                changed = result;
                changed.trace.(name)(1) = ~logical(changed.trace.(name)(1));
                testCase.verifyError(@() step1.runDesignSimulink(cfg, changed, testCase.Folder), ...
                    'step1:design:SimulinkDecisionMismatch', char(name));
            end
            changed = result;
            changed.trace.margin_db(1) = changed.trace.margin_db(1) + 1;
            testCase.verifyError(@() step1.runDesignSimulink(cfg, changed, testCase.Folder), ...
                'step1:design:SimulinkDecisionMismatch');
        end

        function detectsMissingCasesGapsAndInvalidRawDraws(testCase)
            [cfg, result] = localShortTrace(testCase, 4);
            missing = result;
            missing.trace(1:4, :) = [];
            testCase.verifyError(@() step1.runDesignSimulink(cfg, missing, testCase.Folder), ...
                'step1:design:SimulinkScenarioMissing');
            changed = result;
            changed.trace.frame_index(2) = changed.trace.frame_index(2) + 1;
            testCase.verifyError(@() step1.runDesignSimulink(cfg, changed, testCase.Folder), ...
                'step1:design:SimulinkTraceDiscontinuous');
            changed = result;
            changed.trace.satellite_forward_uniform_draw(1) = NaN;
            testCase.verifyError(@() step1.runDesignSimulink(cfg, changed, testCase.Folder), ...
                'step1:design:SimulinkTraceInvalid');
            changed = result;
            changed.trace.ground_return_uniform_draw(1) = 1;
            testCase.verifyError(@() step1.runDesignSimulink(cfg, changed, testCase.Folder), ...
                'step1:design:SimulinkTraceInvalid');
        end

        function treatsZeroRfMarginAndLossBoundaryAsClosed(testCase)
            [cfg, result] = localShortTrace(testCase, 4);
            rfMargin = repmat([-1; 0; 1; 1], 15, 1);
            draws = repmat([0; 0.5; 0.9; 0.1], 15, 1);
            rfClosed = repmat([false; true; true; true], 15, 1);
            eventClosed = repmat([false; true; true; false], 15, 1);
            result.trace.ebn0_db = rfMargin;
            result.trace.reference_ebn0_db = rfMargin;
            result.trace.reference_uplink_margin_db = rfMargin;
            result.trace.margin_db = rfMargin;
            result.trace.threshold_ebn0_db(:) = 0;
            stages = localStages();
            for k = 1:8
                stage = stages(k);
                if k==1 || k==5, valid = true(60,1); end
                result.trace.(stage+"_input_valid") = valid;
                result.trace.(stage+"_margin_gain_db")(:) = 0;
                if ismember(k,[1 3 6 8])
                    result.trace.(stage+"_reference_margin_db") = rfMargin;
                    result.trace.(stage+"_margin_db") = rfMargin;
                    success = rfClosed;
                else
                    result.trace.(stage+"_uniform_draw") = draws;
                    result.trace.(stage+"_loss_probability")(:) = 0.5;
                    result.trace.(stage+"_margin_db") = result.trace.(stage+"_reference_margin_db");
                    success = eventClosed;
                end
                valid = valid & success;
                result.trace.(stage+"_local_success") = success;
                result.trace.(stage+"_closed") = success;
                result.trace.(stage+"_valid") = valid;
            end
            result.trace.link_closed = rfClosed;
            result.trace.end_to_end_rf_closed = rfClosed;
            for name = ["uplink_service_closed","downlink_service_closed","end_to_end_closed"]
                result.trace.(name) = eventClosed;
            end
            validation = step1.runDesignSimulink(cfg,result,testCase.Folder);
            testCase.verifyEqual(validation.decision_mismatches,0);
            testCase.verifyEqual(validation.max_abs_margin_difference,0);
        end

        function nativeRfReplacementMatchesMatlabAndChangesTheChain(testCase)
            cfg = testCase.Config;
            cfg.design.trace_points = 100;
            cfg.design.frames_per_replicate = 100;
            baseline = step1.designScreening(cfg);
            identity = step1.buildMacroModuleTemplate(testCase.Folder,GainDb=0,ExtraDelayMs=0);
            cfg.design.simulink_overrides.handset_uplink = identity;
            identityCheck = step1.runDesignSimulink(cfg,baseline,testCase.Folder);
            testCase.verifyEqual(identityCheck.native_override_count,1);
            testCase.verifyEqual(identityCheck.decision_mismatches,0);
            improvement = step1.buildMacroModuleTemplate(testCase.Folder,GainDb=3,ExtraDelayMs=5);
            cfg.design.simulink_overrides.handset_uplink = improvement;
            % A replacement without a matching MATLAB module must fail.
            testCase.verifyError(@() step1.runDesignSimulink(cfg,baseline,testCase.Folder), ...
                'step1:design:SimulinkDecisionMismatch');
            cfg.design.modules.handset_uplink = struct('implementation',"step1.modules.rfLink", ...
                'parameters',struct('margin_gain_db',3,'extra_delay_ms',5));
            improved = step1.designScreening(cfg);
            validation = step1.runDesignSimulink(cfg,improved,testCase.Folder);
            testCase.verifyEqual(validation.native_override_count,1);
            testCase.verifyEqual(validation.adapter_replay_count,0);
            testCase.verifyEqual(validation.decision_mismatches,0);
            testCase.verifyEqual(improved.trace.handset_uplink_margin_db-baseline.trace.handset_uplink_margin_db, ...
                repmat(3,height(baseline.trace),1),'AbsTol',1e-12);
            testCase.verifyEqual(improved.trace.ground_forward_cumulative_delay_ms-baseline.trace.ground_forward_cumulative_delay_ms, ...
                repmat(5,height(baseline.trace),1),'AbsTol',1e-10);
            testCase.verifyGreaterThan(nnz(improved.trace.handset_uplink_closed ~= baseline.trace.handset_uplink_closed),0);
            testCase.verifyGreaterThan(nnz(improved.trace.end_to_end_closed ~= baseline.trace.end_to_end_closed),0);
            % The copied slot remains runnable after its source library closes.
            [~,model] = fileparts(validation.model_path);
            load_system(validation.model_path);
            cleanup = onCleanup(@() localClose(model)); %#ok<NASGU>
            testCase.verifyEqual(string(get_param(model+"/handset_uplink",'LinkStatus')),"none");
            rerun = sim(model);
            testCase.verifyEqual(logical(rerun.get('design_end_to_end_closed')), ...
                reshape(improved.trace.end_to_end_closed,100,15));
        end

        function rejectsTamperedCumulativeValidityAndDelay(testCase)
            [cfg,result] = localShortTrace(testCase,4);
            for stage = localStages()
                changed = result;
                changed.trace.(stage+"_valid")(1) = ~changed.trace.(stage+"_valid")(1);
                testCase.verifyError(@() step1.runDesignSimulink(cfg,changed,testCase.Folder), ...
                    'step1:design:SimulinkDecisionMismatch');
            end
            changed = result;
            changed.trace.satellite_forward_cumulative_delay_ms(1) = ...
                changed.trace.satellite_forward_cumulative_delay_ms(1)+1;
            testCase.verifyError(@() step1.runDesignSimulink(cfg,changed,testCase.Folder), ...
                'step1:design:SimulinkDecisionMismatch');
        end

        function customMatlabDeviceUsesLabelledReplayAndNativeChainWiring(testCase)
            cfg = testCase.Config;
            cfg.design.frames_per_replicate = 100;
            cfg.design.trace_points = 100;
            cfg.design.modules.handset_uplink = struct('implementation',"step1.examples.rfDevice", ...
                'parameters',struct('margin_gain_db',2,'extra_delay_ms',7));
            result = step1.designScreening(cfg);
            validation = step1.runDesignSimulink(cfg,result,testCase.Folder);
            testCase.verifyEqual(validation.adapter_replay_count,1);
            testCase.verifyEqual(validation.native_module_count,7);
            testCase.verifyEqual(validation.modules(1).execution_mode,"adapter_replay");
            testCase.verifyEqual(validation.modules(1).implementation,"step1.examples.rfDevice");
            testCase.verifyEqual(validation.decision_mismatches,0);
            % The adapter cannot conceal broken cumulative composition.
            changed = result;
            changed.trace.ground_forward_cumulative_delay_ms(1) = ...
                changed.trace.ground_forward_cumulative_delay_ms(1)+2;
            testCase.verifyError(@() step1.runDesignSimulink(cfg,changed,testCase.Folder), ...
                'step1:design:SimulinkDecisionMismatch');
        end

        function rejectsReplacementWithWrongPortSemantics(testCase)
            [cfg,result] = localShortTrace(testCase,4);
            template = step1.buildMacroModuleTemplate(testCase.Folder,GainDb=0,ExtraDelayMs=0);
            [~,library] = fileparts(template.library_path);
            load_system(template.library_path);
            cleanup = onCleanup(@() localClose(library)); %#ok<NASGU>
            set_param(library,'Lock','off');
            set_param(template.block_path+"/valid_in",'Name','wrong_valid_semantics');
            save_system(library);
            cfg.design.simulink_overrides.handset_uplink = template;
            testCase.verifyError(@() step1.runDesignSimulink(cfg,result,testCase.Folder), ...
                'step1:design:SimulinkModulePorts');
            testCase.verifyTrue(bdIsLoaded(library));
        end

        function capsLongRunsAndReportsPrefixCoverage(testCase)
            cfg = testCase.Config;
            cfg.design.frames_per_replicate = 20000;
            cfg.design.trace_points = 20000;
            validation = step1.runDesignSimulink(cfg, testCase.Results, testCase.Folder);
            testCase.verifyEqual(validation.samples, 22500);
            testCase.verifyEqual(validation.simulation_steps, 1500);
            testCase.verifyEqual(validation.frames_per_replicate, 20000);
            testCase.verifyFalse(validation.full_first_replicate_covered);
            testCase.verifyTrue(validation.all_configured_cases_covered);
        end

        function keepsTheUsersOpenAndUnsavedModelUntouched(testCase)
            [~, tag] = fileparts(tempname());
            model = ['user_work_' regexprep(tag, '[^A-Za-z0-9_]', '')];
            new_system(model);
            cleanup = onCleanup(@() localClose(model)); %#ok<NASGU>
            add_block('simulink/Sources/Constant', [model '/Existing work'], 'Value', '317');
            beforeDirty = get_param(model, 'Dirty');
            beforeHandle = get_param(model, 'Handle');
            [cfg, result] = localShortTrace(testCase, 4);
            step1.runDesignSimulink(cfg, result, testCase.Folder);
            testCase.verifyTrue(bdIsLoaded(model));
            testCase.verifyEqual(get_param(model, 'Handle'), beforeHandle);
            testCase.verifyEqual(get_param(model, 'Dirty'), beforeDirty);
            testCase.verifyEqual(get_param([model '/Existing work'], 'Value'), '317');
        end

        function redirectsGeneratedCachesAndRestoresCallerSettings(testCase)
            [cfg,result] = localShortTrace(testCase,4);
            beforeCache = string(Simulink.fileGenControl('get','CacheFolder'));
            beforeCodegen = string(Simulink.fileGenControl('get','CodeGenFolder'));
            paths = step1.defaultPaths();
            sourceDirs = [string(paths.rootDir),string(paths.matlabDir), ...
                string(fullfile(paths.matlabDir,'tests'))];
            beforeFiles = localGeneratedFiles(sourceDirs);
            validation = step1.runDesignSimulink(cfg,result,testCase.Folder);
            testCase.verifyEqual(string(Simulink.fileGenControl('get','CacheFolder')),beforeCache);
            testCase.verifyEqual(string(Simulink.fileGenControl('get','CodeGenFolder')),beforeCodegen);
            testCase.verifyEqual(localGeneratedFiles(sourceDirs),beforeFiles);
            [~,model] = fileparts(validation.model_path);
            testCase.verifyTrue(isfile(fullfile(validation.cache_paths.cache_folder,model+".slxc")));
            testCase.verifyTrue(endsWith(replace(validation.cache_paths.root,'\','/'), ...
                '/artifacts/cache/simulink'));
            if ispc
                digest = char(step1.io.sha256Text(paths.rootDir));
                launcherAlias = fullfile(tempdir,['step1_link_matlab_' digest(1:12)]);
                if all(double(char(paths.rootDir))<=127) || isfolder(launcherAlias)
                    testCase.verifyTrue(validation.cache_paths.ascii_path);
                end
            end
            changed = result;
            changed.trace.end_to_end_closed(1) = ~changed.trace.end_to_end_closed(1);
            testCase.verifyError(@() step1.runDesignSimulink(cfg,changed,testCase.Folder), ...
                'step1:design:SimulinkDecisionMismatch');
            testCase.verifyEqual(string(Simulink.fileGenControl('get','CacheFolder')),beforeCache);
            testCase.verifyEqual(string(Simulink.fileGenControl('get','CodeGenFolder')),beforeCodegen);
            testCase.verifyEqual(localGeneratedFiles(sourceDirs),beforeFiles);
            previousExecutionRoot = getenv('STEP1_MATLAB_EXECUTION_ROOT');
            environmentCleanup = onCleanup(@() setenv('STEP1_MATLAB_EXECUTION_ROOT',previousExecutionRoot)); %#ok<NASGU>
            validExecutionRoot = fileparts(fileparts(fileparts(char(validation.cache_paths.root))));
            setenv('STEP1_MATLAB_EXECUTION_ROOT',validExecutionRoot);
            [explicitCleanup,explicitPaths] = step1.useSimulinkCache();
            testCase.verifyEqual(explicitPaths.root,validation.cache_paths.root);
            clear explicitCleanup
            setenv('STEP1_MATLAB_EXECUTION_ROOT',char(testCase.Folder));
            [staleCleanup,stalePaths] = step1.useSimulinkCache();
            testCase.verifyFalse(startsWith(stalePaths.root,testCase.Folder+filesep));
            clear staleCleanup
        end
    end
end

function [cfg, result] = localShortTrace(testCase, frames)
cfg = testCase.Config;
cfg.design.trace_points = frames;
result = testCase.Results;
result.trace = result.trace(result.trace.frame_index <= frames, :);
end

function localClose(model)
if bdIsLoaded(model), close_system(model, 0); end
end

function localReleaseCache(testCase)
testCase.CacheCleanup = [];
end

function files = localGeneratedFiles(folders)
files = strings(0,1);
for folder = folders
    entries = dir(fullfile(folder,'*.slxc'));
    files = [files; string(fullfile(folder,{entries.name})).']; %#ok<AGROW>
    if isfolder(fullfile(folder,'slprj'))
        files(end+1,1) = string(fullfile(folder,'slprj')); %#ok<AGROW>
    end
end
files = sort(files);
end


function stages = localStages()
stages = ["handset_uplink","satellite_forward","feeder_downlink","ground_forward", ...
    "ground_return","feeder_uplink","satellite_return","handset_downlink"];
end
