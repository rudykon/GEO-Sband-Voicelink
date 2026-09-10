classdef TestMatlabSourceShare < matlab.unittest.TestCase
    %TESTMATLABSOURCESHARE Verify source measurement and advisory policy.

    methods (Test)
        function auditReturnsMachineReadableBreakdown(testCase)
            result = step1.auditSourceShare( ...
                'WriteReport', false, 'WriteMachineReports', false);
            testCase.verifyEqual(result.metric_version, 'matlab-source-share-v1');
            testCase.verifyEqual(result.minimum_share, 0.60);
            testCase.verifyEqual(result.design_target, 0.60);
            testCase.verifyEqual(result.policy, 'advisory');
            testCase.verifyFalse(result.enforced);
            testCase.verifyGreaterThan(result.matlab_lines, 0);
            testCase.verifyGreaterThanOrEqual(result.python_lines, 0);
            testCase.verifyEqual(result.total_lines, ...
                result.matlab_lines + result.python_lines + result.other_lines);
            testCase.verifyGreaterThanOrEqual(result.matlab_share, 0);
            testCase.verifyLessThanOrEqual(result.matlab_share, 1);
            testCase.verifyGreaterThanOrEqual(result.production_matlab_share, 0);
            testCase.verifyLessThanOrEqual(result.production_matlab_share, 1);
            testCase.verifyEqual(result.passes, ...
                result.total_passes && result.production_passes);
            testCase.verifyClass(result.details, 'table');
            testCase.verifyTrue(any(string(result.include_rules) == "scripts/**/*.cs"));
            testCase.verifyFalse(any(contains(string(result.include_rules), ...
                ["code/extra", "external_sources", "unlisted.py"])));
        end

        function belowTargetRemainsInformationalWithEnforceOption(testCase)
            root = string(tempname);
            mkdir(fullfile(root, 'code', 'matlab'));
            mkdir(fullfile(root, 'code', 'python'));
            cleanup = onCleanup(@() rmdir(root, 's')); %#ok<NASGU>
            matlabPath = fullfile(root, 'code', 'matlab', 'sample.m');
            pythonPath = fullfile(root, 'code', 'python', 'sample.py');
            writelines('value = 1;', matlabPath);
            writelines(["value = 1"; "other = 2"; "result = value + other"], ...
                pythonPath);
            result = step1.auditSourceShare('ProjectRoot', root, ...
                'WriteReport', false, 'WriteMachineReports', false, ...
                'Enforce', true);
            testCase.verifyEqual(result.matlab_share, 0.25);
            testCase.verifyEqual(result.production_matlab_share, 0.25);
            testCase.verifyFalse(result.passes);
            testCase.verifyFalse(result.enforced);
            testCase.verifyTrue(isfile(pythonPath));
        end

        function defaultReportsUseSelectedProjectArtifacts(testCase)
            root = string(tempname);
            for directory = ["code/matlab", "code/python", "code/extra", ...
                    "external_sources", "scripts"]
                mkdir(fullfile(root, directory));
            end
            cleanup = onCleanup(@() rmdir(root, 's')); %#ok<NASGU>
            writelines("value = 1;", fullfile(root, 'code/matlab/sample.m'));
            writelines("value = 1", fullfile(root, 'code/python/sample.py'));
            writelines("value = 1", fullfile(root, 'unlisted.py'));
            writelines("value = 1", fullfile(root, 'code/extra/sample.py'));
            writelines("value = 1", fullfile(root, 'external_sources/sample.py'));
            writelines(["# comment"; "Write-Output 1"], fullfile(root, 'scripts/sample.ps1'));
            writelines(["// comment"; "/* block"; "comment */"; ...
                'string url = "https://example.test/#"; // comment'; ...
                "int value = 1; /* trailing block"; "comment */"], ...
                fullfile(root, 'scripts/sample.cs'));
            previousPath = path;
            result = step1.auditSourceShare('ProjectRoot', root);
            testCase.verifyEqual(path, previousPath);
            testCase.verifyEqual(result.matlab_lines, 1);
            testCase.verifyEqual(result.python_lines, 1);
            testCase.verifyEqual(result.other_lines, 3);
            testCase.verifyFalse(any(contains(result.details.file, ...
                ["code/extra", "external_sources", "unlisted.py"])));
            reportDir = fullfile(root, 'artifacts/logs/source_share');
            for extension = [".md", ".json", ".csv"]
                testCase.verifyTrue(isfile(fullfile(reportDir, ...
                    "matlab_source_share_report" + extension)));
            end
            testCase.verifyFalse(isfolder(fullfile(root, 'code/matlab/tests')));
        end
    end
end
