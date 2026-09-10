function [out, state] = deviceCurve(in, parameters, context, state)
%DEVICECURVE Example adapter for a measured/externally calibrated device curve.
% Replace the example curve with your own success probability versus margin.
% The example values are illustrative, not measurements of a real device.
defaults = struct('margin_db',[-8 -4 0 4 8], ...
    'success_probability',[0.01 0.12 0.5 0.9 0.999], ...
    'margin_gain_db',0,'extra_delay_ms',2);
if ~isstruct(parameters) || ~isscalar(parameters) ...
        || ~all(ismember(fieldnames(parameters),fieldnames(defaults)))
    error('step1:ExampleParameters','Unknown deviceCurve parameter.');
end
for name = string(fieldnames(parameters)).'
    defaults.(name) = parameters.(name);
end
p = defaults;
x = p.margin_db; y = p.success_probability;
if ~isnumeric(x) || ~isnumeric(y) || ~isreal(x) || ~isreal(y) ...
        || ~isvector(x) || ~isvector(y) || numel(x) < 2 || numel(x) > 10000 ...
        || numel(x) ~= numel(y) || any(~isfinite(x)) || any(~isfinite(y)) ...
        || any(diff(x) <= 0) || any(diff(y) < 0) || any(y < 0 | y > 1)
    error('step1:ExampleParameters','Device curve requires ascending margins and monotone probabilities in [0,1].');
end
for name = ["margin_gain_db","extra_delay_ms"]
    if ~isnumeric(p.(name)) || ~isreal(p.(name)) || ~isscalar(p.(name)) || ~isfinite(p.(name))
        error('step1:ExampleParameters','Gain and delay must be finite real scalars.');
    end
end
if p.extra_delay_ms < 0
    error('step1:ExampleParameters','Processing delay cannot be negative.');
end
out = in;
out.margin_db = context.reference_margin_db + p.margin_gain_db;
query = min(max(out.margin_db,min(x)),max(x));
probability = interp1(x(:),y(:),query,'linear');
draw = rand(context.stream,size(in.valid));
out.local_success = draw >= 1-probability;
out.valid = in.valid & out.local_success;
out.delay_ms = in.delay_ms + context.default_delay_ms + p.extra_delay_ms;
out.signals.device_success_probability = probability;
state = struct('frames_processed',numel(in.valid));
end
