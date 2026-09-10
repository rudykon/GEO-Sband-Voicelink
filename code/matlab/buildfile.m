function plan = buildfile
%BUILDFILE Buildtool tasks for the bounded modular macro chain.
plan = buildplan(localfunctions);
plan.DefaultTasks = "design";
end

function designTask(~)
run_step1_all(Profile="design");
end

function quickTask(~)
% Alias for the same macro workflow.
run_step1_all(Profile="design");
end

function fullTask(~)
error('step1:RetiredProfile', 'Task full is not supported. Run buildtool design for the macro workflow.');
end

function testTask(~)
testsDir = fullfile(fileparts(mfilename('fullpath')), 'tests');
addpath(testsDir);
run_step1_design_tests(IncludeSimulink=true);
end

function auditTask(~)
step1.auditSourceShare('WriteReport', true, 'WriteMachineReports', true);
end
