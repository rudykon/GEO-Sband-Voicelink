function status = run_module_comparison(options)
%RUN_MODULE_COMPARISON Replace one RF component and compare every paired frame.
% addpath('code/matlab'); addpath('code/matlab/examples');
% status = run_module_comparison(UseSimulink=true);
% To use your own device curve, change implementation below to
% 'step1.examples.deviceCurve' and provide its curve parameters.
arguments
    options.UseSimulink (1,1) logical = false
    options.RunId (1,1) string = ""
end
addpath(fileparts(fileparts(mfilename('fullpath'))));
modules = struct();
modules.handset_uplink = struct( ...
    'implementation', 'step1.examples.rfDevice', ...
    'label', 'Example RF device: +3 dB and +5 ms', ...
    'parameters', struct('margin_gain_db',3,'extra_delay_ms',5));
status = run_step1_all(Modules=modules, CompareBaseline=true, ...
    UseSimulink=options.UseSimulink, RunId=options.RunId);
end
