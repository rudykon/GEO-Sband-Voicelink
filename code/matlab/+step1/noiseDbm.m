function valueDbm = noiseDbm(bandwidthHz, noiseFigureDb, temperatureK)
%NOISEDBM Thermal-noise power in dBm.

if nargin < 2 || isempty(noiseFigureDb), noiseFigureDb = 0.0; end
if nargin < 3 || isempty(temperatureK), temperatureK = 290.0; end
if any(bandwidthHz <= 0, "all") || any(temperatureK <= 0, "all")
    error("step1:InvalidLink", "Bandwidth and temperature must be positive.");
end
valueDbm = -228.6 + 10.0 .* log10(double(temperatureK)) + ...
    10.0 .* log10(double(bandwidthHz)) + double(noiseFigureDb) + 30.0;
end
