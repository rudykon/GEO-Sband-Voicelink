function [out, state] = transfer(in, params, context, state)
%TRANSFER Replaceable satellite/ground stage with macro frame loss and delay.
% PARAMS: loss_probability (context default), extra_delay_ms (0).
params = step1.modules.defaultParameters(params, ...
    struct('loss_probability', context.default_loss_probability, 'extra_delay_ms', 0));
if params.loss_probability < 0 || params.loss_probability > 1 || params.extra_delay_ms < 0
    error('step1:ModuleParameters', 'loss_probability must be in [0,1] and extra_delay_ms must be nonnegative.');
end
out = in;
% A transfer probability score is dimensionless, not an RF margin in dB.
% Non-RF slots use the reference-margin placeholder (normally zero). The
% raw draw and probability remain separately available in the trace.
out.margin_db = context.reference_margin_db;
out.local_success = context.uniform_draw >= params.loss_probability;
out.valid = in.valid & out.local_success;
out.delay_ms = in.delay_ms + context.default_delay_ms + params.extra_delay_ms;
end
