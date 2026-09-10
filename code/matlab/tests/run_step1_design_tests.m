function results = run_step1_design_tests(options)
%RUN_STEP1_DESIGN_TESTS Reproduce the complete fast-chain regression suite.
% Writes each class result immediately so long connector calls cannot hide
% completed tests for the macro workflow and its replaceable module interfaces.
arguments
    options.IncludeSimulink (1,1) logical = true
    options.EvidencePath (1,1) string = ""
end
testsDir = fileparts(mfilename('fullpath'));
addpath(fileparts(testsDir));
paths = step1.defaultPaths();
if options.EvidencePath == ""
    options.EvidencePath = fullfile(paths.rootDir, 'artifacts/logs/design_fast_tests_latest.json');
end
classes = ["TestStep1DesignBudget", "TestStep1DesignScreening", ...
    "TestStep1DesignSystemChain", "TestStep1MacroConfig", "TestStep1MacroRunner", ...
    "TestStep1ModuleContracts", "TestStep1ModuleComparison", "TestMatlabSourceShare"];
if options.IncludeSimulink
    classes(end+1) = "TestStep1DesignSimulink";
end
timer = tic;
results = matlab.unittest.TestResult.empty();
evidence = struct('schema_version', 'step1-fast-chain-tests-v1', ...
    'status', 'running', 'include_simulink', options.IncludeSimulink, ...
    'classes', classes, 'completed_classes', strings(0,1), ...
    'current_class', "", 'passed', 0, 'failed', 0, 'incomplete', 0);
for name = classes
    evidence.current_class = name;
    step1.io.writeJsonAtomic(options.EvidencePath, evidence);
    classResults = runtests(fullfile(testsDir, name + ".m"));
    results = [results, classResults]; %#ok<AGROW>
    evidence.completed_classes(end+1) = name;
    evidence.passed = sum([results.Passed]);
    evidence.failed = sum([results.Failed]);
    evidence.incomplete = sum([results.Incomplete]);
    evidence.names = string({results.Name});
    evidence.passed_each = [results.Passed];
    evidence.failed_each = [results.Failed];
    evidence.elapsed_seconds = toc(timer);
    step1.io.writeJsonAtomic(options.EvidencePath, evidence);
end
evidence.current_class = "";
evidence.status = "passed";
if evidence.failed > 0 || evidence.incomplete > 0, evidence.status = "failed"; end
step1.io.writeJsonAtomic(options.EvidencePath, evidence);
assertSuccess(results);
end
