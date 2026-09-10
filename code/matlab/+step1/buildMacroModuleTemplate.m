function template = buildMacroModuleTemplate(outputDir, options)
%BUILDMACROMODULETEMPLATE Save a standalone RF improvement slot library.
%   T = step1.buildMacroModuleTemplate(DIR,GainDb=3,ExtraDelayMs=5);
%   cfg.design.simulink_overrides.handset_uplink = T;
%   Matching MATLAB slot parameters are margin_gain_db and extra_delay_ms.
%   Inputs: valid_in,reference_margin_db,random_draw,loss_probability,
%           base_local_delay_ms,cumulative_delay_in_ms.
%   Outputs: valid_out,local_success,cumulative_delay_out_ms,margin_db,local_delay_ms.
arguments
    outputDir (1,1) string
    options.GainDb (1,1) double = 3
    options.ExtraDelayMs (1,1) double = 5
end
if isempty(which('new_system')) || ~license('test', 'Simulink')
    error('step1:design:SimulinkUnavailable', 'Building a native template requires Simulink.');
end
if strlength(outputDir) == 0 || ~isfinite(options.GainDb) ...
        || ~isfinite(options.ExtraDelayMs) || options.ExtraDelayMs < 0
    error('step1:design:SimulinkModuleParameter', 'A directory, finite gain, and nonnegative extra delay are required.');
end
if ~isfolder(outputDir), mkdir(outputDir); end
[~, tag] = fileparts(tempname());
tag = regexprep(tag, '[^A-Za-z0-9_]', '');
model = ['step1_rf_template_' tag(1:min(24,numel(tag)))];
new_system(model, 'Library');
cleanup = onCleanup(@() closeOwnModel(model)); %#ok<NASGU>
block = string(model) + "/RF improvement";
step1.populateMacroSubsystem(block, Mode="rf", ...
    GainDb=options.GainDb, ExtraDelayMs=options.ExtraDelayMs);
set_param(block, 'Position', [100 100 480 350]);
annotation = Simulink.Annotation(model, sprintf([ ...
    'Replaceable macro RF device: gain %.3g dB; extra delay %.3g ms\n' ...
    'Six input and five output ports are fixed. Edit the interior algorithm, keep port names/numbers.'], ...
    options.GainDb, options.ExtraDelayMs));
annotation.Position = [70 390 850 450];
path = fullfile(outputDir, string(model) + ".slx");
save_system(model, char(path));
template = struct('library_path', string(path), 'block_path', block);
end

function closeOwnModel(model)
if bdIsLoaded(model), close_system(model, 0); end
end
