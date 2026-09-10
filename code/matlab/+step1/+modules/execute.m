function [out, state] = execute(spec, in, context, state)
%EXECUTE Call one configured implementation with a checked stream contract.
% A direction is a pipeline: OUT (including signals/payload/delay/valid) is
% the next stage's IN. Invalid upstream frames can never be resurrected.
% Global RAND calls inside a module use its isolated context.stream; both
% successful and throwing callbacks restore the caller's global RNG object.
localBase(in, numel(in.frame_index), 'input');
previousStream = RandStream.getGlobalStream;
cleanup = onCleanup(@() RandStream.setGlobalStream(previousStream)); %#ok<NASGU>
RandStream.setGlobalStream(context.stream);
[out, state] = spec.callable(in, spec.parameters, context, state);
if ~isstruct(out) || ~isscalar(out) || ~all(isfield(out, fieldnames(in))) ...
        || ~all(isfield(out, {'local_success', 'margin_db'}))
    error('step1:ModuleContract', 'Module %s must retain all input fields and return local_success and margin_db.', context.stage_id);
end
n = numel(in.frame_index);
localBase(out, n, 'output');
if ~islogical(out.local_success) || ~isequal(size(out.local_success), [n 1])
    error('step1:ModuleContract', 'Module %s local_success must be an N-by-1 logical vector.', context.stage_id);
end
localFiniteColumn(out.margin_db, n, 'margin_db');
if ~isequal(out.frame_index, in.frame_index) || ~isequal(out.time_s, in.time_s)
    error('step1:ModuleContract', 'Module %s changed frame_index or time_s.', context.stage_id);
end
if ~isequal(out.valid, in.valid & out.local_success)
    error('step1:ModuleContract', 'Module %s valid must equal input.valid AND local_success; earlier failures cannot revive.', context.stage_id);
end
if any(out.delay_ms < in.delay_ms)
    error('step1:ModuleContract', 'Module %s decreased cumulative delay.', context.stage_id);
end
end

function localBase(value, n, label)
required = {'frame_index', 'time_s', 'valid', 'delay_ms', 'payload_bits', 'signals'};
if ~isstruct(value) || ~isscalar(value) || ~all(isfield(value, required))
    error('step1:ModuleContract', 'Module %s must contain the six frame-contract fields.', label);
end
for name = ["frame_index", "time_s", "delay_ms", "payload_bits"]
    localFiniteColumn(value.(name), n, name);
end
if ~islogical(value.valid) || ~isequal(size(value.valid), [n 1]) ...
        || ~isstruct(value.signals) || ~isscalar(value.signals) ...
        || any(value.delay_ms < 0) || any(value.payload_bits < 0)
    error('step1:ModuleContract', 'Module %s requires logical valid, scalar signals, and nonnegative delays/payload bits.', label);
end
end

function localFiniteColumn(value, n, name)
if ~isnumeric(value) || ~isreal(value) || ~isequal(size(value), [n 1]) || any(~isfinite(value))
    error('step1:ModuleContract', 'Module field %s must be a finite real N-by-1 numeric vector.', name);
end
end
