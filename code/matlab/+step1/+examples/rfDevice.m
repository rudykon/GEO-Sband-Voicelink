function [out, state] = rfDevice(in, parameters, context, state)
%RFDEVICE Example replacement: reuse the RF contract and add device metadata.
% Copy this named .m function into your own package and change its internals.
% Parameters are the same as step1.modules.rfLink: margin_gain_db and
% extra_delay_ms. The frame envelope remains compatible with downstream slots.
[out, state] = step1.modules.rfLink(in, parameters, context, state);
out.signals.device_model = "illustrative_custom_RF_device";
out.signals.device_margin_db = out.margin_db;
end
