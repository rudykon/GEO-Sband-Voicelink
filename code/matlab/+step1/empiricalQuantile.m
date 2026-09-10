function q = empiricalQuantile(values, probability)
%EMPIRICALQUANTILE Deterministic linear empirical quantile without toolboxes.

values = sort(double(values(:)));
if isempty(values)
    error("step1:EmptySamples", "Cannot compute a quantile of empty samples.");
end
if ~isscalar(probability) || ~isfinite(probability) || probability < 0 || probability > 1
    error("step1:InvalidProbability", "Quantile probability must lie in [0,1].");
end
if numel(values) == 1
    q = values(1);
    return;
end
position = 1.0 + probability * (numel(values) - 1.0);
lowerIndex = floor(position);
upperIndex = ceil(position);
weight = position - lowerIndex;
q = values(lowerIndex) * (1.0 - weight) + values(upperIndex) * weight;
end
