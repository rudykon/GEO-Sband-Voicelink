function [out, state] = rfLink(in, params, context, state)
%RFLINK Replaceable macro RF stage, using the configured reference margin.
% [OUT,STATE] = step1.modules.rfLink(IN,PARAMS,CONTEXT,STATE)
% PARAMS: margin_gain_db (0), extra_delay_ms (0). Unknown fields are errors.
% Copying IN preserves upstream payload and arbitrary IN.signals fields.
params = step1.modules.defaultParameters(params, ...
    struct('margin_gain_db', 0, 'extra_delay_ms', 0));
if params.extra_delay_ms < 0
    error('step1:ModuleParameters', 'extra_delay_ms must be nonnegative.');
end
out = in;
out.margin_db = context.reference_margin_db + params.margin_gain_db;
out.local_success = out.margin_db >= 0;
out.valid = in.valid & out.local_success;
out.delay_ms = in.delay_ms + context.default_delay_ms + params.extra_delay_ms;
% STATE is intentionally unchanged. Custom replacements may implement a
% sequential recurrence over the time-ordered vector and return final state.
end
