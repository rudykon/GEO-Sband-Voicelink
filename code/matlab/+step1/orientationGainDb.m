function gainDb = orientationGainDb(thetaDeg, cfg)
%ORIENTATIONGAINDB Handset posture-gain proxy with configured clipping.

if nargin < 2 || isempty(cfg)
    cfg = step1.loadConfig("", "quick");
end
thetaDeg = min(max(double(thetaDeg), 0.0), 90.0);
gainLinear = cosd(thetaDeg) .^ double(cfg.link.posture_exponent);
gainDb = double(cfg.link.g_peak_dbi) + 10.0 .* log10(max(gainLinear, 1e-12));
gainDb = max(gainDb, double(cfg.link.g_min_dbi));
end
