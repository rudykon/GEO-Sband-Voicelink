function populateMacroSubsystem(path, options)
%POPULATEMACROSUBSYSTEM Build the fixed six-input/five-output macro slot.
arguments
    path (1,1) string
    options.Mode (1,1) string = "rf"
    options.GainDb (1,1) double = 0
    options.ExtraDelayMs (1,1) double = 0
    options.ReplayVariables (1,1) struct = struct()
    options.FrameSeconds (1,1) double = 0.02
end
path = char(path);
add_block('simulink/Ports & Subsystems/Subsystem', path);
Simulink.SubSystem.deleteContents(path);
set_param(path, 'TreatAsAtomicUnit', 'on');
inputs = ["valid_in", "reference_margin_db", "random_draw", "loss_probability", ...
    "base_local_delay_ms", "cumulative_delay_in_ms"];
outputs = ["valid_out", "local_success", "cumulative_delay_out_ms", "margin_db", "local_delay_ms"];
for k = 1:numel(inputs)
    add_block('simulink/Ports & Subsystems/In1', [path '/' char(inputs(k))], ...
        'Port', num2str(k), 'Position', [25 40+65*k 55 54+65*k]);
end
for k = 1:numel(outputs)
    add_block('simulink/Ports & Subsystems/Out1', [path '/' char(outputs(k))], ...
        'Port', num2str(k), 'Position', [770 50+75*k 800 64+75*k]);
end
if options.Mode == "replay"
    names = ["local_success", "margin_db", "local_delay_ms"];
    for k = 1:numel(names)
        add_block('simulink/Sources/From Workspace', [path '/Replay ' char(names(k))], ...
            'VariableName', char(options.ReplayVariables.(names(k))), ...
            'SampleTime', number(options.FrameSeconds), 'Interpolate', 'off', ...
            'OutputAfterFinalValue', 'Holding final value', 'Position', [195 80+85*k 420 110+85*k]);
    end
    success = 'Replay local_success/1';
    margin = 'Replay margin_db/1';
    delay = 'Replay local_delay_ms/1';
else
    add_block('simulink/Sources/Constant', [path '/Extra processing ms'], ...
        'Value', number(options.ExtraDelayMs), 'Position', [175 475 270 505]);
    add_block('simulink/Math Operations/Sum', [path '/Local delay'], ...
        'Inputs', '++', 'Position', [350 405 375 445]);
    add_line(path, 'base_local_delay_ms/1', 'Local delay/1', 'autorouting', 'on');
    add_line(path, 'Extra processing ms/1', 'Local delay/2', 'autorouting', 'on');
    delay = 'Local delay/1';
    add_block('simulink/Math Operations/Sum', [path '/Margin'], ...
        'Inputs', '++', 'Position', [335 190 365 230]);
    if options.Mode == "rf"
        add_block('simulink/Sources/Constant', [path '/Device gain dB'], ...
            'Value', number(options.GainDb), 'Position', [170 280 270 310]);
        add_line(path, 'reference_margin_db/1', 'Margin/1', 'autorouting', 'on');
        add_line(path, 'Device gain dB/1', 'Margin/2', 'autorouting', 'on');
    elseif options.Mode == "transfer"
        set_param([path '/Margin'], 'Inputs', '+-');
        add_line(path, 'random_draw/1', 'Margin/1', 'autorouting', 'on');
        add_line(path, 'loss_probability/1', 'Margin/2', 'autorouting', 'on');
    else
        error('step1:design:SimulinkModuleMode', 'Unknown native macro mode: %s.', options.Mode);
    end
    add_block('simulink/Sources/Constant', [path '/Zero'], ...
        'Value', '0', 'Position', [400 275 430 295]);
    add_block('simulink/Logic and Bit Operations/Relational Operator', [path '/Local decision'], ...
        'Operator', '>=', 'Position', [475 190 525 235]);
    add_line(path, 'Margin/1', 'Local decision/1', 'autorouting', 'on');
    add_line(path, 'Zero/1', 'Local decision/2', 'autorouting', 'on');
    success = 'Local decision/1';
    margin = 'Margin/1';
    if options.Mode == "transfer"
        % The decision score draw-probability is dimensionless; RF margin
        % remains the reference diagnostic (zero means N/A for network slots).
        margin = 'reference_margin_db/1';
    end
end
if options.Mode == "rf"
    unused = ["random_draw","loss_probability"];
elseif options.Mode == "transfer"
    unused = strings(1,0);
else
    unused = ["reference_margin_db","random_draw","loss_probability","base_local_delay_ms"];
end
for k=1:numel(unused)
    target = "Unused "+unused(k);
    add_block('simulink/Sinks/Terminator',[path '/' char(target)], ...
        'Position',[110 565+40*k 130 585+40*k]);
    add_line(path,char(unused(k)+"/1"),char(target+"/1"),'autorouting','on');
end
add_block('simulink/Logic and Bit Operations/Logical Operator', [path '/Propagate validity'], ...
    'Operator', 'AND', 'Inputs', '2', 'Position', [595 100 635 145]);
add_line(path, 'valid_in/1', 'Propagate validity/1', 'autorouting', 'on');
add_line(path, success, 'Propagate validity/2', 'autorouting', 'on');
add_line(path, 'Propagate validity/1', 'valid_out/1', 'autorouting', 'on');
add_line(path, success, 'local_success/1', 'autorouting', 'on');
add_line(path, margin, 'margin_db/1', 'autorouting', 'on');
add_block('simulink/Math Operations/Sum', [path '/Accumulate delay'], ...
    'Inputs', '++', 'Position', [585 390 615 435]);
add_line(path, 'cumulative_delay_in_ms/1', 'Accumulate delay/1', 'autorouting', 'on');
add_line(path, delay, 'Accumulate delay/2', 'autorouting', 'on');
add_line(path, 'Accumulate delay/1', 'cumulative_delay_out_ms/1', 'autorouting', 'on');
add_line(path, delay, 'local_delay_ms/1', 'autorouting', 'on');
% Port names appear on each instance and define the replacement contract.
set_param(path, 'ShowPortLabels', 'FromPortIcon');
end

function text = number(value)
if ~isfinite(value), error('step1:design:SimulinkModuleParameter', 'Module constants must be finite.'); end
text = sprintf('%.17g', value);
end
