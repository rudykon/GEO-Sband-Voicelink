classdef TestStep1MacroConfig < matlab.unittest.TestCase
    % Configuration contracts for the active, extensible macro workflow.
    methods (TestClassSetup)
        function addPaths(~)
            addpath(fileparts(fileparts(mfilename('fullpath'))));
        end
    end
    methods (Test)
        function defaultsContainOnlyMacroFields(testCase)
            cfg = step1.loadConfig();
            testCase.verifyEqual(string(cfg.schema_version), "step1-macro-chain-v1");
            testCase.verifyEqual(string(cfg.runtime.profile), "design");
            testCase.verifyFalse(any(isfield(cfg, {'phy','profiles','extensions','outage','synchronization','session'})));
            testCase.verifyFalse(isfield(cfg.output, 'canonical_files'));
            testCase.verifyNumElements(fieldnames(cfg.design.modules), 8);
            testCase.verifyTrue(endsWith(string(cfg.configPath), "step1_macro_chain.json"));
        end
        function quickAliasIsTheSameMacroProfile(testCase)
            cfg = step1.loadConfig('', 'quick');
            testCase.verifyEqual(string(cfg.runtime.profile), "design");
            testCase.verifyEqual(string(cfg.runtime.requested_profile), "quick");
            testCase.verifyEqual(cfg.design.frames_per_replicate, 1500);
        end
        function unsupportedProfileFailsBeforeReadingConfig(testCase)
            testCase.verifyError(@() step1.loadConfig('file_that_does_not_exist.json', 'full'), 'step1:RetiredProfile');
            testCase.verifyError(@() step1.profileConfig(struct(), 'full'), 'step1:RetiredProfile');
        end
        function arbitraryScenarioAndRateSetsAreAccepted(testCase)
            cfg = localRaw();
            cfg.scenarios = cfg.scenarios(1:2);
            cfg.scenarios(2).scenario_key = 'new_location';
            cfg.scenarios = rmfield(cfg.scenarios, 'step1_key');
            cfg.voice.rate_bps = [1600, 3200];
            cfg.voice.main_rate_bps = 1600;
            cfg.design.threshold_ebn0_db = [-0.5, 1.2];
            cfg = step1.validateConfig(cfg);
            testCase.verifyEqual(cfg.voice.rate_bps, [1600, 3200]);
            testCase.verifyEqual(string(cfg.scenarios(2).step1_key), "new_location");
            budget = step1.designBudget(cfg);
            testCase.verifyEqual(budget.case_count, 4);
        end
        function scenarioStatisticsFollowStationaryInputs(testCase)
            cfg = step1.loadConfig();
            for index = 1:numel(cfg.scenarios)
                sc = cfg.scenarios(index);
                stationary = (1 - sc.p_nn) / (2 - sc.p_ll - sc.p_nn);
                testCase.verifyEqual(stationary, sc.p_los, 'AbsTol', 1e-12);
                expectedRho = exp(-sc.speed_mps * cfg.channel.frame_duration_ms / 1000 / sc.shadow_decorrelation_m);
                testCase.verifyEqual(sc.shadow_rho, expectedRho, 'AbsTol', 1e-12);
            end
        end
        function invalidThresholdAndScenarioInputsFail(testCase)
            cfg = localRaw();
            cfg.design.threshold_ebn0_db = [0,1];
            testCase.verifyError(@() step1.validateConfig(cfg), 'step1:InvalidConfig');
            cfg = localRaw(); cfg.scenarios(2).scenario_key = cfg.scenarios(1).scenario_key;
            testCase.verifyError(@() step1.validateConfig(cfg), 'step1:InvalidConfig');
            cfg = localRaw(); cfg.scenarios(1).p_los = 0.99; cfg.scenarios(1).mean_los_dwell_frames = 2;
            testCase.verifyError(@() step1.validateConfig(cfg), 'step1:InvalidConfig');
        end
        function numericalBudgetCannotBeExpanded(testCase)
            cfg = localRaw(); cfg.design.frames_per_replicate = 20000; cfg.design.replicates = 16;
            testCase.verifyError(@() step1.validateConfig(cfg), 'step1:DesignBudget');
        end
        function geometryAndBudgetRemainPhysical(testCase)
            cfg = localRaw(); cfg.geometry.mode = 'coordinates';
            cfg.geometry.terminal_lat_deg = 0; cfg.geometry.terminal_lon_deg = 0; cfg.geometry.geo_longitude_deg = 0;
            cfg = step1.validateConfig(cfg);
            testCase.verifyEqual(cfg.geometry.resolved_elevation_deg, 90, 'AbsTol', 1e-10);
            testCase.verifyEqual(cfg.link.distance_km, cfg.geometry.geo_orbit_radius_km - cfg.geometry.earth_radius_km, 'AbsTol', 1e-9);
            low = step1.linkBudget(cfg, 0, 31250, 1200);
            high = step1.linkBudget(cfg, 0, 31250, 2400);
            testCase.verifyEqual(low.ebn0_db - high.ebn0_db, 10*log10(2), 'AbsTol', 1e-12);
        end
        function customModuleParametersRemainAvailableToTheirImplementation(testCase)
            cfg = localRaw();
            cfg.design.modules.handset_uplink = struct('implementation', 'my_rf_model', ...
                'parameters', struct('experiment_setting', 17), 'label', 'My RF model');
            cfg = step1.validateConfig(cfg);
            testCase.verifyEqual(cfg.design.modules.handset_uplink.parameters.experiment_setting, 17);
        end

        function compactExamplesExpandToTheSameCompleteConfigurations(testCase)
            paths = step1.defaultPaths();
            folder = testCase.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            expected = localRaw();
            expected.design.modules = struct('handset_uplink',struct( ...
                'implementation','step1.examples.rfDevice', ...
                'label','Example RF device: +3 dB margin, +5 ms processing', ...
                'parameters',struct('margin_gain_db',3,'extra_delay_ms',5)));
            for name = ["rf_device_comparison","stress_comparison"]
                if name == "stress_comparison"
                    expected.design.frames_per_replicate = 10000;
                    expected.design.link_delta_db = -7:7;
                end
                expectedPath = localWriteConfig(folder.Folder,'expected.json',expected);
                full = step1.loadConfig(expectedPath);
                compactPath = fullfile(paths.configDir,'examples',name+".json");
                compact = step1.loadConfig(compactPath);
                testCase.verifyEqual(localComparable(compact),localComparable(full));
                testCase.verifyEqual(compact.description,expected.description);
                testCase.verifyEqual(compact.baseConfigSha256,step1.sha256File(paths.defaultConfig));
                testCase.verifyEqual(compact.configSha256,step1.sha256File(compactPath));
                testCase.verifyTrue(isfile(compact.baseConfigPath));
                testCase.verifyFalse(any(isfield(compact,{'base_config','overrides'})));
            end
        end

        function inheritanceResolvesRelativePathsAndReplacesArraysAndModuleMaps(testCase)
            folder = testCase.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            base = localRaw();
            base.scenarios = base.scenarios(1);
            base.scenarios.base_only_note = 'must not leak into replacement array';
            base.design.modules.handset_uplink.parameters = struct('old_device_setting',17);
            base.design.simulink_overrides = struct('handset_uplink',struct( ...
                'library_path','old.slx','block_path','old/slot'), ...
                'handset_downlink',struct('library_path','down.slx','block_path','down/slot'));
            basePath = localWriteConfig(folder.Folder,'base.json',base);
            original = localRaw();
            override = struct('description','Inherited test case','link',struct('pt_dbm',37), ...
                'scenarios',original.scenarios(2));
            override.design = struct('link_delta_db',0,'modules',struct('handset_uplink',struct( ...
                'implementation','new_device','parameters',struct('new_setting',4))), ...
                'simulink_overrides',struct('handset_downlink',struct( ...
                'library_path','new.slx','block_path','new/slot')));
            path = localWriteConfig(folder.Folder,fullfile('nested','example.json'), ...
                struct('base_config','../base.json','overrides',override));
            cfg = step1.loadConfig(path);
            testCase.verifyEqual(cfg.description,'Inherited test case');
            testCase.verifyEqual(cfg.link.pt_dbm,37);
            testCase.verifyEqual(cfg.link.bandwidth_hz,base.link.bandwidth_hz);
            testCase.verifyEqual(cfg.design.link_delta_db,0);
            testCase.verifyNumElements(cfg.scenarios,1);
            testCase.verifyEqual(cfg.scenarios.scenario_key,original.scenarios(2).scenario_key);
            testCase.verifyFalse(isfield(cfg.scenarios,'base_only_note'));
            testCase.verifyEqual(fieldnames(cfg.design.modules),{'handset_uplink'});
            testCase.verifyEqual(fieldnames(cfg.design.modules.handset_uplink.parameters),{'new_setting'});
            testCase.verifyFalse(isfield(cfg.design.modules.handset_uplink,'label'));
            testCase.verifyEqual(fieldnames(cfg.design.simulink_overrides),{'handset_downlink'});
            testCase.verifyEqual(cfg.design.simulink_overrides.handset_downlink.library_path,'new.slx');
            testCase.verifyEqual(cfg.baseConfigSha256,step1.sha256File(basePath));
        end

        function invalidInheritanceWrappersAndMissingBasesFailClearly(testCase)
            folder = testCase.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            localWriteConfig(folder.Folder,'base.json',localRaw());
            wrapper = struct('base_config','base.json','overrides',struct());
            bad = wrapper; bad.unknown_wrapper_field = 1;
            path = localWriteConfig(folder.Folder,'bad.json',bad);
            testCase.verifyError(@() step1.loadConfig(path),'step1:ConfigInheritance');
            bad = rmfield(wrapper,'base_config');
            path = localWriteConfig(folder.Folder,'bad.json',bad);
            testCase.verifyError(@() step1.loadConfig(path),'step1:ConfigInheritance');
            bad = wrapper; bad.base_config = 42;
            path = localWriteConfig(folder.Folder,'bad.json',bad);
            testCase.verifyError(@() step1.loadConfig(path),'step1:ConfigInheritance');
            bad = wrapper; bad.base_config = 'missing.json';
            path = localWriteConfig(folder.Folder,'bad.json',bad);
            testCase.verifyError(@() step1.loadConfig(path),'step1:ConfigBaseNotFound');
            for overrides = {[],7,struct('base_config','another.json'), ...
                    struct('design',struct('modules',[])), ...
                    struct('design',struct('simulink_overrides',[]))}
                bad = wrapper; bad.overrides = overrides{1};
                path = localWriteConfig(folder.Folder,'bad.json',bad);
                testCase.verifyError(@() step1.loadConfig(path),'step1:ConfigOverrides');
            end
        end

        function basesCannotInheritAgainAndTheirRawBytesAreHashed(testCase)
            folder = testCase.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            basePath = localWriteConfig(folder.Folder,'base.json',localRaw());
            path = localWriteConfig(folder.Folder,'example.json', ...
                struct('base_config','base.json','overrides',struct()));
            first = step1.loadConfig(path);
            fid = fopen(basePath,'a');
            cleanup = onCleanup(@() fclose(fid));
            fprintf(fid,'\n  \n');
            clear cleanup
            second = step1.loadConfig(path);
            testCase.verifyEqual(localComparable(first),localComparable(second));
            testCase.verifyEqual(first.configSha256,second.configSha256);
            testCase.verifyNotEqual(first.baseConfigSha256,second.baseConfigSha256);
            localWriteConfig(folder.Folder,'base.json', ...
                struct('base_config','other.json','overrides',struct()));
            testCase.verifyError(@() step1.loadConfig(path),'step1:ConfigInheritance');
        end
    end
end
function cfg = localRaw()
paths = step1.defaultPaths();
cfg = jsondecode(fileread(paths.defaultConfig));
end

function path = localWriteConfig(folder,name,cfg)
path = fullfile(folder,name);
step1.io.writeJsonAtomic(path,cfg);
end

function cfg = localComparable(cfg)
metadata = intersect(fieldnames(cfg), ...
    {'configPath';'configSha256';'baseConfigPath';'baseConfigSha256';'paths'});
cfg = rmfield(cfg,metadata);
end
