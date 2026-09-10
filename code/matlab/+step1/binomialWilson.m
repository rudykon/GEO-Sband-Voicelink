function [low, high] = binomialWilson(successes, trials, confidence)
%BINOMIALWILSON Wilson confidence interval for a binomial proportion.

if nargin < 3 || isempty(confidence), confidence = 0.95; end
if ~isscalar(trials) || trials <= 0 || trials ~= round(trials) || ...
        ~isscalar(successes) || successes < 0 || successes > trials
    error("step1:BinomialCounts", "Binomial counts must satisfy 0 <= successes <= trials.");
end
if ~isscalar(confidence) || confidence <= 0 || confidence >= 1
    error("step1:BinomialConfidence", "Confidence must lie in (0,1).");
end
z = step1.norminvLocal(0.5 + confidence / 2.0);
p = double(successes) / double(trials);
denominator = 1.0 + z ^ 2 / trials;
center = (p + z ^ 2 / (2.0 * trials)) / denominator;
half = z * sqrt(p * (1.0 - p) / trials + z ^ 2 / (4.0 * trials ^ 2)) / denominator;
low = max(0.0, center - half);
high = min(1.0, center + half);
end
