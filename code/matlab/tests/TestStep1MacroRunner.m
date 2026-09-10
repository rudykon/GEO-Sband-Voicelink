classdef TestStep1MacroRunner < matlab.unittest.TestCase
    % The public runner validates profiles and confines outputs to run folders.
    methods (TestClassSetup)
        function addPaths(~)
            addpath(fileparts(fileparts(mfilename('fullpath'))));
        end
    end
    methods (Test)
        function unsupportedProfileFailsBeforeConfigOrOutputs(testCase)
            testCase.verifyError(@() run_step1_all(Profile='full', ...
                ConfigPath='missing.json'), 'step1:RetiredProfile');
            testCase.verifyError(@() run_step1_all('missing.json', 'full'), 'step1:RetiredProfile');
        end
        function quickAliasRoutesToMacroConfig(testCase)
            testCase.verifyError(@() run_step1_all(Profile='quick', ...
                ConfigPath='missing.json'), 'step1:ConfigNotFound');
            testCase.verifyError(@() run_step1_all('missing.json', 'design'), 'step1:ConfigNotFound');
        end
        function macroOptionsAreAcceptedByThePublicRunner(testCase)
            testCase.verifyError(@() run_step1_all(ConfigPath='missing.json', ...
                Modules=struct(), CompareBaseline=true, SkipPlots=true, SkipReport=true), 'step1:ConfigNotFound');
        end
        function newContextIsIsolatedAndCannotBeReused(testCase)
            root = string(tempname); mkdir(root);
            cleanup = onCleanup(@() rmdir(root, 's')); %#ok<NASGU>
            context = step1.io.newRunContext(root, 'quick', 'macro-fixture');
            testCase.verifyEqual(context.profile, "design");
            testCase.verifyTrue(isfolder(context.resultDir));
            testCase.verifyFalse(isfield(context, 'canonicalDir'));
            testCase.verifyFalse(isfolder(fullfile(context.stagingDir, 'canonical')));
            testCase.verifyError(@() step1.io.newRunContext(root, 'design', 'macro-fixture'), 'step1:io:RunAlreadyExists');
        end
        function unsupportedAndEscapingContextsFailClosed(testCase)
            root = string(tempname); mkdir(root);
            cleanup = onCleanup(@() rmdir(root, 's')); %#ok<NASGU>
            testCase.verifyError(@() step1.io.newRunContext(root, 'full', 'bad'), 'step1:RetiredProfile');
            testCase.verifyError(@() step1.io.newRunContext(root, 'design', 'bad', ...
                struct('runs_relative_dir', '../outside')), 'step1:io:OutputPathOutsideProject');
            testCase.verifyEmpty(dir(fullfile(root, '*', 'bad')));
        end
        function atomicStatusPreservesUnicodeAndCompletion(testCase)
            root = string(tempname); mkdir(root);
            cleanup = onCleanup(@() rmdir(root, 's')); %#ok<NASGU>
            context = step1.io.newRunContext(root, 'design', 'unicode-status');
            label = string(char([hex2dec('5929'),hex2dec('901A')]));
            status = struct('status', 'completed', 'run_id', context.runId, 'label', label);
            step1.io.writeRunStatus(context, status);
            saved = jsondecode(fileread(context.statusPath));
            testCase.verifyEqual(string(saved.label), label);
            testCase.verifyEqual(string(saved.status), "completed");
            latest = jsondecode(fileread(context.latestStatusPath));
            testCase.verifyEqual(string(latest.run_id), context.runId);
        end
        function sharedHashMatchesEmptyAndChunkedReference(testCase)
            root = string(tempname); mkdir(root);
            cleanup = onCleanup(@() rmdir(root, 's')); %#ok<NASGU>
            file = fullfile(root, 'hash-input.bin');
            fid = fopen(file, 'wb'); fclose(fid);
            testCase.verifyEqual(step1.sha256File(file), ...
                'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
            fid = fopen(file, 'wb');
            fwrite(fid, repmat(uint8('a'), 1048593, 1), 'uint8'); fclose(fid);
            % Independent .NET SHA256 reference, larger than the read chunk.
            testCase.verifyEqual(step1.sha256File(file), ...
                'c26032d5154f96bd29c799447d715ab681d8d0aa308ecc6f321a35d98f0672da');
        end
    end
end
