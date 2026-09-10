classdef TestStep1ModuleContracts < matlab.unittest.TestCase
    % Replace every module slot, exercise real data flow and reject bad APIs.
    methods (TestClassSetup)
        function addProjectAndNamedFixture(testCase)
            addpath(fileparts(fileparts(mfilename('fullpath'))));
            folder = testCase.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            fixturePath = fullfile(folder.Folder, 'step1_module_contract_probe.m');
            fid = fopen(fixturePath, 'w', 'n', 'UTF-8');
            assert(fid >= 0, 'Could not write the module fixture.');
            cleanup = onCleanup(@() fclose(fid));
            fprintf(fid, '%s', localFixtureText());
            clear cleanup;
            testCase.applyFixture(matlab.unittest.fixtures.PathFixture(folder.Folder));
        end
    end

    methods (Test)
        function eachOfEightSlotsCanReplaceItsActualStage(testCase)
            cfg = localConfig();
            stages = ["handset_uplink", "satellite_forward", "feeder_downlink", "ground_forward", ...
                "ground_return", "feeder_uplink", "satellite_return", "handset_downlink"];
            for index = 1:numel(stages)
                variant = cfg;
                variant.design.modules.(stages(index)) = localProbe('fail');
                chain = step1.designSystemChain(variant, ones(12, 2), 1);
                testCase.verifyFalse(any(chain.frames.end_to_end_closed, 'all'));
                testCase.verifyFalse(any(chain.frames.(stages(index) + "_closed"), 'all'));
                testCase.verifyEqual(chain.module_manifest.implementation(index), "step1_module_contract_probe");
                testCase.verifyEqual(chain.final_states{index, 1}.stage_id, stages(index));
            end
        end

        function downstreamReceivesSignalsPayloadValidityAndDelay(testCase)
            cfg = localConfig();
            reference = step1.designSystemChain(cfg, ones(12, 2), 1);
            cfg.design.modules.handset_uplink = localProbe('writer', 5);
            cfg.design.modules.satellite_forward = localProbe('reader', 11);
            chain = step1.designSystemChain(cfg, ones(12, 2), 1);
            accepted = repmat(mod((1:12).', 2) == 0, 1, 2);
            testCase.verifyEqual(chain.frames.end_to_end_closed, accepted);
            testCase.verifyTrue(all(chain.frames.satellite_forward_local_success, 'all'));
            testCase.verifyEqual(chain.frames.satellite_forward_input_valid, accepted);
            testCase.verifyEqual(chain.frames.satellite_forward_valid, accepted);
            testCase.verifyEqual(chain.frames.forward_payload_bits, reference.frames.forward_payload_bits + 7);
            testCase.verifyEqual(chain.forward_signals{1}.token, (1:12).' + 100);
            testCase.verifyEmpty(fieldnames(chain.return_signals{1}));
            testCase.verifyEqual(chain.frames.forward_delay_ms, reference.frames.forward_delay_ms + 16, 'AbsTol', 1e-10);
            testCase.verifyEqual(chain.frames.return_delay_ms, reference.frames.return_delay_ms, 'AbsTol', 1e-10);
        end

        function stateResetsForEveryIndependentReplicateAndCase(testCase)
            cfg = localConfig();
            cfg.design.modules.handset_uplink = localProbe('stateful');
            first = step1.designSystemChain(cfg, ones(12, 3), 1);
            second = step1.designSystemChain(cfg, ones(12, 3), 2);
            expected = repmat(mod((1:12).', 3) ~= 0, 1, 3);
            testCase.verifyEqual(first.frames.handset_uplink_closed, expected);
            testCase.verifyEqual(second.frames.handset_uplink_closed, expected);
            for replicate = 1:3
                testCase.verifyEqual(first.final_states{1, replicate}.count, 12);
                testCase.verifyEqual(first.final_states{1, replicate}.initial_count, 0);
                testCase.verifyEqual(first.final_states{1, replicate}.replicate_index, replicate);
            end
        end

        function callbackStreamsArePairedAndGlobalRngIsRestoredOnSuccessAndError(testCase)
            cfg = localConfig();
            cfg.design.modules.handset_uplink = localProbe('random');
            before = rng;
            first = step1.designSystemChain(cfg, ones(50, 2), 1, struct('voice_rate_bps', 1200));
            second = step1.designSystemChain(cfg, 4 * ones(50, 2), 1, struct('voice_rate_bps', 4000));
            testCase.verifyEqual(rng, before);
            testCase.verifyEqual(first.frames.handset_uplink_closed, second.frames.handset_uplink_closed);
            testCase.verifyEqual(first.forward_signals{1}.global_draw, second.forward_signals{1}.global_draw);
            testCase.verifyEqual(first.module_seeds, second.module_seeds);
            testCase.verifyNotEqual(first.module_seeds(:, 1), first.module_seeds(:, 2));
            testCase.verifyNotEqual(first.forward_signals{1}.global_draw, first.forward_signals{2}.global_draw);
            cfg.design.modules.handset_uplink = localProbe('throw');
            testCase.verifyError(@() step1.designSystemChain(cfg, ones(12, 2), 1), 'moduleTest:IntentionalFailure');
            testCase.verifyEqual(rng, before);
        end

        function rejectsMalformedOutputWithoutFallbackOrResurrectingFrames(testCase)
            cfg = localConfig();
            for behavior = ["bad_logical", "bad_shape", "bad_delay", "bad_margin", "bad_frame", "bad_time", "bad_signals", "bad_missing"]
                variant = cfg;
                variant.design.modules.handset_uplink = localProbe(behavior);
                testCase.verifyError(@() step1.designSystemChain(variant, ones(12, 2), 1), 'step1:ModuleContract');
            end
            cfg.design.modules.handset_uplink = localProbe('fail');
            cfg.design.modules.satellite_forward = localProbe('revive');
            testCase.verifyError(@() step1.designSystemChain(cfg, ones(12, 2), 1), 'step1:ModuleContract');
        end

        function defaultModulesRejectUnknownParametersAndUnresolvableImplementations(testCase)
            cfg = localConfig();
            cfg.design.modules.handset_uplink = struct('implementation', 'step1.modules.rfLink', ...
                'parameters', struct('misspelled_gain', 3));
            testCase.verifyError(@() step1.designSystemChain(cfg, ones(12, 2), 1), 'step1:ModuleParameters');
            cfg.design.modules.handset_uplink = struct('implementation', 'step1.modules.transfer', ...
                'parameters', struct('loss_probability', 1.01));
            testCase.verifyError(@() step1.designSystemChain(cfg, ones(12, 2), 1), 'step1:ModuleParameters');
            for implementation = ["missing_package.not_a_module", "@(x)x", "system('echo unsafe')"]
                cfg.design.modules.handset_uplink = struct('implementation', implementation, 'parameters', struct());
                testCase.verifyError(@() step1.designSystemChain(cfg, ones(12, 2), 1), 'step1:ModuleConfiguration');
            end
        end

        function defaultPipelineMatchesReferenceFrameDecisions(testCase)
            cfg = localConfig();
            cfg.design.system_chain.satellite_frame_loss_probability = 0.2;
            cfg.design.system_chain.ground_frame_loss_probability = 0.1;
            margins = reshape(linspace(-2, 2, 100), 50, 2);
            chain = step1.designSystemChain(cfg, margins, 2);
            expected = (margins >= 0) & (margins + cfg.design.system_chain.downlink_margin_offset_db >= 0) ...
                & (chain.frames.satellite_forward_draw >= 0.2) & (chain.frames.satellite_return_draw >= 0.2) ...
                & (chain.frames.ground_forward_draw >= 0.1) & (chain.frames.ground_return_draw >= 0.1);
            testCase.verifyEqual(chain.frames.end_to_end_closed, expected);
            testCase.verifyEqual(chain.frames.handset_uplink_margin_db, margins);
            testCase.verifyEqual(chain.frames.downlink_margin_db, margins + 3);
            testCase.verifyEqual(chain.frames.satellite_forward_input_valid, chain.frames.handset_uplink_valid);
            expectedDelay = (cfg.link.distance_km + cfg.design.system_chain.gateway_slant_range_km) ...
                / 299792.458 * 1000 + cfg.channel.frame_duration_ms ...
                + cfg.design.system_chain.satellite_processing_ms + cfg.design.system_chain.ground_network_ms;
            testCase.verifyEqual(chain.delays.one_way_ms, expectedDelay, 'AbsTol', 1e-10);
            testCase.verifyEqual(chain.delays.return_one_way_ms, expectedDelay, 'AbsTol', 1e-10);
        end

        function screeningUsesActualModuleSuccessAndReexecutesSensitivity(testCase)
            cfg = localConfig();
            cfg.design.modules.handset_uplink = localProbe('success_with_negative_diagnostic');
            result = step1.designScreening(cfg);
            testCase.verifyEqual(result.summary.availability, ones(height(result.summary), 1));
            testCase.verifyTrue(all(result.trace.link_closed));
            testCase.verifyTrue(all(result.trace.margin_db < 0));
            testCase.verifyEqual(result.sensitivity.availability, ones(height(result.sensitivity), 1));
            testCase.verifyEqual(result.trace.margin_db, result.trace.handset_uplink_margin_db);
            testCase.verifyNotEqual(result.trace.reference_uplink_margin_db, result.trace.margin_db);
        end

        function provenanceAndPairedContextIncludePhysicalInputsButExcludeModuleChoice(testCase)
            cfg = localConfig();
            cfg.design.link_delta_db = 0;
            baseline = step1.designScreening(cfg);
            cfg.design.modules.handset_uplink = localProbe('writer', 7);
            candidate = step1.designScreening(cfg);
            testCase.verifyEqual(candidate.comparison_context, baseline.comparison_context);
            testCase.verifyEqual(candidate.comparison_samples(1).module_random_seeds, ...
                baseline.comparison_samples(1).module_random_seeds);
            testCase.verifyEqual(candidate.comparison_samples(1).channel_random_seeds, ...
                baseline.comparison_samples(1).channel_random_seeds);
            testCase.verifySize(candidate.comparison_samples(1).end_to_end_closed, [100 2]);
            testCase.verifyEqual(height(candidate.module_manifest), 8);
            row = candidate.module_manifest(1, :);
            testCase.verifyEqual(row.implementation_sha256, string(step1.sha256File(row.implementation_path)));
            params = jsondecode(row.effective_parameters_json);
            testCase.verifyEqual(params.extra_delay_ms, 7);
            testCase.verifyEqual(string(params.behavior), "writer");
            testCase.verifyEqual(candidate.assumptions.modules(1).implementation_sha256, row.implementation_sha256);
            cfg.link.pt_dbm = cfg.link.pt_dbm + 1;
            changedPhysics = step1.designScreening(cfg);
            testCase.verifyNotEqual(changedPhysics.comparison_context.physical_config_sha256, ...
                candidate.comparison_context.physical_config_sha256);
        end
    end
end

function cfg = localConfig()
cfg = step1.loadConfig("", "design");
cfg.design.frames_per_replicate = 100;
cfg.design.replicates = 2;
cfg.design.trace_points = 10;
cfg.design.link_delta_db = [-3 0 3];
cfg.design.system_chain.satellite_frame_loss_probability = 0;
cfg.design.system_chain.ground_frame_loss_probability = 0;
end

function spec = localProbe(behavior, extraDelay)
if nargin < 2, extraDelay = 0; end
spec = struct('implementation', 'step1_module_contract_probe', ...
    'parameters', struct('behavior', char(behavior), 'extra_delay_ms', extraDelay), 'label', 'Contract test fixture');
end

function source = localFixtureText()
source = strjoin([ ...
"function [out,state] = step1_module_contract_probe(in,params,context,state)";
"if ~isempty(state), error('moduleTest:StateLeak','State was not reset.'); end";
"if ~isempty(setdiff(fieldnames(params),{'behavior';'extra_delay_ms'})), error('moduleTest:UnknownParameter','Unknown parameter.'); end";
"n=numel(in.frame_index); out=in; out.local_success=true(n,1); out.margin_db=ones(n,1);";
"out.delay_ms=in.delay_ms+context.default_delay_ms+params.extra_delay_ms;";
"state=struct('count',n,'initial_count',0,'stage_id',context.stage_id,'replicate_index',context.replicate_index);";
"switch string(params.behavior)";
"case 'fail', out.local_success=false(n,1);";
"case 'writer', out.signals.token=in.frame_index+100; out.payload_bits=in.payload_bits+7; out.local_success=mod(in.frame_index,2)==0;";
"case 'reader', if ~isfield(in.signals,'token'), error('moduleTest:MissingSignal','Upstream signal missing.'); end; out.local_success=(in.signals.token==in.frame_index+100)&(in.payload_bits==context.voice_rate_bps*context.frame_duration_ms/1000+7);";
"case 'stateful', state.count=0; for k=1:n, state.count=state.count+1; out.local_success(k)=mod(state.count,3)~=0; end";
"case 'random', out.local_success=rand(context.stream,n,1)>=0.3; out.signals.global_draw=rand(n,1);";
"case 'throw', rand(3,1); error('moduleTest:IntentionalFailure','Callback failure must propagate.');";
"case 'success_with_negative_diagnostic', out.margin_db=-1000*ones(n,1);";
"case 'bad_delay', out.delay_ms=in.delay_ms-1;";
"case 'bad_margin', out.margin_db(1)=NaN;";
"case 'bad_frame', out.frame_index=out.frame_index+1;";
"case 'bad_time', out.time_s=out.time_s+1;";
"case 'bad_signals', out.signals=[];";
"case 'bad_missing', out=rmfield(out,'payload_bits');";
"end";
"out.valid=in.valid & out.local_success;";
"switch string(params.behavior)";
"case 'bad_logical', out.local_success=double(out.local_success);";
"case 'bad_shape', out.margin_db=out.margin_db.';";
"case 'revive', out.valid=true(n,1);";
"end";
"end"], newline);
end
