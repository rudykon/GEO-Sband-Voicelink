function rows = linkBudget(cfg, orientationDeg, bandwidthHz, rateBps)
%LINKBUDGET Deterministic GEO S-band carrier and Eb/N0 budget table.

if nargin < 1 || isempty(cfg), cfg = step1.loadConfig("", "quick"); end
if nargin < 2 || isempty(orientationDeg), orientationDeg = 15.0; end
if nargin < 3 || isempty(bandwidthHz), bandwidthHz = cfg.link.bandwidth_hz; end
if nargin < 4 || isempty(rateBps), rateBps = cfg.voice.rate_bps; end

orientationDeg = double(orientationDeg(:));
bandwidthHz = double(bandwidthHz(:));
rateBps = double(rateBps(:));
if any(~isfinite(orientationDeg)) || any(~isfinite(bandwidthHz)) || any(~isfinite(rateBps)) || ...
        any(bandwidthHz <= 0) || any(rateBps <= 0)
    error("step1:InvalidLink", "Orientations must be finite and bandwidth/rate values positive.");
end

n = numel(orientationDeg) * numel(bandwidthHz) * numel(rateBps);
uplinkMHz = repmat(double(cfg.link.uplink_mhz), n, 1);
downlinkMHz = repmat(double(cfg.link.downlink_mhz), n, 1);
distanceKm = repmat(double(cfg.link.distance_km), n, 1);
orientation = zeros(n, 1);
bandwidth = zeros(n, 1);
rate = zeros(n, 1);
handsetGain = zeros(n, 1);
pathLoss = zeros(n, 1);
receivedPower = zeros(n, 1);
noisePower = zeros(n, 1);
snr = zeros(n, 1);
ebn0 = zeros(n, 1);

pathLossValue = step1.fsplDb(cfg.link.distance_km, cfg.link.uplink_mhz);
row = 0;
for i = 1:numel(orientationDeg)
    gain = step1.orientationGainDb(orientationDeg(i), cfg);
    for j = 1:numel(bandwidthHz)
        noise = step1.noiseDbm(bandwidthHz(j), cfg.link.nf_db, cfg.link.temperature_k);
        pr = cfg.link.pt_dbm + gain + cfg.link.sat_gr_dbi - pathLossValue ...
            - cfg.link.pol_loss_db - cfg.link.extra_loss_db;
        snrValue = pr - noise;
        for k = 1:numel(rateBps)
            row = row + 1;
            orientation(row) = orientationDeg(i);
            bandwidth(row) = bandwidthHz(j);
            rate(row) = rateBps(k);
            handsetGain(row) = gain;
            pathLoss(row) = pathLossValue;
            receivedPower(row) = pr;
            noisePower(row) = noise;
            snr(row) = snrValue;
            ebn0(row) = snrValue + 10.0 * log10(bandwidthHz(j) / rateBps(k));
        end
    end
end

rows = table(uplinkMHz, downlinkMHz, distanceKm, orientation, bandwidth, rate, ...
    handsetGain, pathLoss, receivedPower, noisePower, snr, ebn0, ...
    'VariableNames', {'uplink_mhz', 'downlink_mhz', 'distance_km', 'orientation_deg', ...
    'bandwidth_hz', 'voice_rate_bps', 'handset_gain_dbi', 'fspl_db', ...
    'received_power_dbm', 'noise_power_dbm', 'snr_db', 'ebn0_db'});
end
