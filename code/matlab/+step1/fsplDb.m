function lossDb = fsplDb(distanceKm, frequencyMHz)
%FSPLDB Free-space path loss in dB for distance in km and frequency in MHz.

if any(distanceKm <= 0, "all") || any(frequencyMHz <= 0, "all")
    error("step1:InvalidLink", "Distance and frequency must be positive.");
end
lossDb = 32.44 + 20.0 .* log10(double(distanceKm)) + 20.0 .* log10(double(frequencyMHz));
end
