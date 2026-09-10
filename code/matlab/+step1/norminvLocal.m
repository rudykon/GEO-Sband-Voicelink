function value = norminvLocal(probability)
%NORMINVLOCAL Standard-normal inverse CDF using base MATLAB erfinv.

if any(~isfinite(probability), "all") || any(probability <= 0 | probability >= 1, "all")
    error("step1:InvalidProbability", "Normal inverse probabilities must lie in (0,1).");
end
value = sqrt(2.0) .* erfinv(2.0 .* probability - 1.0);
end
