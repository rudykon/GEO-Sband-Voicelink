function stats = correlatedAvailabilityStats(success, scenario, confidence)
%CORRELATEDAVAILABILITYSTATS Temporal uncertainty with replicate clusters.
%
% A vector is one contiguous temporal trajectory. A cell vector or a
% numeric/logical matrix (one replicate per column) is a collection of
% independent trajectory restarts. Within-trajectory uncertainty uses
% nonoverlapping batch means. With multiple replicates, the reported
% standard error is the larger of the independent-cluster standard error
% and the propagated within-replicate batch-means standard error.
% Outage bursts are never joined across independent replicate boundaries.

if nargin < 3
    confidence = 0.95;
end
replicates = localReplicates(success);
if ~isstruct(scenario) || ~isscalar(scenario) ...
        || ~all(isfield(scenario, {'p_ll', 'p_nn', 'shadow_rho'}))
    error("step1:TemporalAvailabilityScenario", ...
        "Scenario must contain p_ll, p_nn, and shadow_rho.");
end
if ~isscalar(confidence) || ~isfinite(confidence) ...
        || confidence <= 0 || confidence >= 1
    error("step1:TemporalAvailabilityConfidence", ...
        "Confidence must lie strictly between zero and one.");
end

replicateCount = numel(replicates);
single = localSingle(replicates{1}, scenario, confidence);
single(replicateCount, 1) = single(1);
for replicateIndex = 2:replicateCount
    single(replicateIndex) = localSingle( ...
        replicates{replicateIndex}, scenario, confidence);
end
if replicateCount == 1
    stats = single;
    stats.replicate_count = 1;
    stats.frames_per_replicate = stats.samples;
    stats.replicate_availability = stats.availability;
    stats.replicate_standard_error = stats.standard_error;
    stats.cluster_standard_error = NaN;
    stats.within_replicate_standard_error = stats.standard_error;
    stats.burst_boundary_policy = "single_contiguous_trajectory";
    stats = rmfield(stats, "burst_lengths");
    return;
end

replicateFrames = arrayfun(@(value) value.samples, single).';
if any(replicateFrames ~= replicateFrames(1))
    error("step1:TemporalReplicateLength", ...
        "Independent temporal replicates must contain equal frame counts.");
end
replicateAvailability = arrayfun(@(value) value.availability, single).';
replicateStandardError = arrayfun(@(value) value.standard_error, single).';
clusterStandardError = std(replicateAvailability, 0) ...
    / sqrt(replicateCount);
withinStandardError = sqrt(sum(replicateStandardError .^ 2)) ...
    / replicateCount;
standardError = max([clusterStandardError, withinStandardError, eps]);

samples = sum(replicateFrames);
successfulFrames = sum(arrayfun(@(value) value.successful_frames, single));
frameErrors = samples - successfulFrames;
availability = successfulFrames / samples;
z = step1.norminvLocal(0.5 + double(confidence) / 2.0);
if availability > 0 && availability < 1
    effectiveSamples = min(double(samples), max(1.0, ...
        availability * (1.0 - availability) / standardError ^ 2));
else
    effectiveSamples = sum(arrayfun( ...
        @(value) value.effective_samples, single));
end

burstLengths = vertcat(single.burst_lengths);
if isempty(burstLengths)
    meanBurstFrames = 0.0;
    p95BurstFrames = 0.0;
    maxBurstFrames = 0.0;
else
    meanBurstFrames = mean(burstLengths);
    p95BurstFrames = step1.empiricalQuantile(burstLengths, 0.95);
    maxBurstFrames = max(burstLengths);
end

stats = struct();
stats.samples = samples;
stats.successful_frames = successfulFrames;
stats.frame_errors = frameErrors;
stats.availability = availability;
stats.standard_error = standardError;
stats.ci_low = max(0.0, availability - z * standardError);
stats.ci_high = min(1.0, availability + z * standardError);
stats.method = "independent_replicate_cluster_means_temporal_frames";
stats.block_frames = single(1).block_frames;
stats.batches = sum(arrayfun(@(value) value.batches, single));
stats.used_frames = sum(arrayfun(@(value) value.used_frames, single));
stats.discarded_tail_frames = sum(arrayfun( ...
    @(value) value.discarded_tail_frames, single));
stats.effective_samples = effectiveSamples;
stats.correlation_inflation = max(arrayfun( ...
    @(value) value.correlation_inflation, single));
stats.burst_count = numel(burstLengths);
stats.mean_burst_frames = meanBurstFrames;
stats.p95_burst_frames = p95BurstFrames;
stats.max_burst_frames = maxBurstFrames;
stats.replicate_count = replicateCount;
stats.frames_per_replicate = replicateFrames(1);
stats.replicate_availability = replicateAvailability;
stats.replicate_standard_error = replicateStandardError;
stats.cluster_standard_error = clusterStandardError;
stats.within_replicate_standard_error = withinStandardError;
stats.burst_boundary_policy = ...
    "independent_replicate_boundaries_not_joined";
end

function replicates = localReplicates(success)
if iscell(success)
    if isempty(success) || ~isvector(success)
        error("step1:TemporalAvailabilitySamples", ...
            "Replicate input must be a nonempty cell vector.");
    end
    replicates = success(:);
elseif isnumeric(success) || islogical(success)
    if isempty(success) || ndims(success) > 2
        error("step1:TemporalAvailabilitySamples", ...
            "Temporal success input must be a nonempty vector or matrix.");
    end
    if isvector(success)
        replicates = {success(:)};
    else
        replicates = arrayfun(@(column) success(:, column), ...
            1:size(success, 2), UniformOutput=false).';
    end
else
    error("step1:TemporalAvailabilitySamples", ...
        "Temporal success input must be numeric, logical, or a cell vector.");
end
for replicateIndex = 1:numel(replicates)
    values = replicates{replicateIndex};
    if ~isnumeric(values) && ~islogical(values)
        error("step1:TemporalAvailabilitySamples", ...
            "Every temporal replicate must be numeric or logical.");
    end
    values = double(values(:));
    if numel(values) < 4 || any(~isfinite(values)) ...
            || any(~ismember(values, [0, 1]))
        error("step1:TemporalAvailabilitySamples", ...
            "Every temporal replicate requires at least four binary frames.");
    end
    replicates{replicateIndex} = logical(values);
end
end

function stats = localSingle(success, scenario, confidence)
success = logical(success(:));
n = numel(success);
pLL = double(scenario.p_ll);
pNN = double(scenario.p_nn);
rho = double(scenario.shadow_rho);
if any(~isfinite([pLL, pNN, rho])) ...
        || any([pLL, pNN, rho] < 0) || any([pLL, pNN, rho] >= 1)
    error("step1:TemporalAvailabilityScenario", ...
        "p_ll, p_nn, and shadow_rho must lie in [0,1).");
end

losDwellFrames = 1.0 / max(1.0 - pLL, eps);
nlosDwellFrames = 1.0 / max(1.0 - pNN, eps);
shadowCorrelationFrames = 1.0 / max(1.0 - rho, eps);
desiredBlockFrames = ceil(5.0 * max( ...
    [losDwellFrames, nlosDwellFrames, shadowCorrelationFrames]));
blockFrames = max(20, min(desiredBlockFrames, max(20, floor(n / 8))));
batches = floor(n / blockFrames);
if batches < 4
    blockFrames = max(1, floor(n / 4));
    batches = floor(n / blockFrames);
end
usedFrames = blockFrames * batches;
batchMeans = mean(reshape(double(success(1:usedFrames)), ...
    blockFrames, batches), 1);
standardError = std(batchMeans, 0, 2) / sqrt(batches);
% Boundary regularizer only: temporal dependence is estimated by the
% observed batch variance and is not replaced by an IID frame formula.
standardError = max(standardError, 0.5 / sqrt(double(n)));

markovLambda = pLL + pNN - 1.0;
markovInflation = (1.0 + abs(markovLambda)) ...
    / max(1.0 - abs(markovLambda), eps);
shadowInflation = (1.0 + rho) / max(1.0 - rho, eps);
correlationInflation = max([1.0, markovInflation, shadowInflation]);
availability = mean(success);
if availability > 0 && availability < 1
    effectiveSamples = min(double(n), max(1.0, ...
        availability * (1.0 - availability) / standardError ^ 2));
else
    effectiveSamples = min(double(n), 1.0 / (4.0 * standardError ^ 2));
end
z = step1.norminvLocal(0.5 + double(confidence) / 2.0);

frameError = ~success;
edges = diff([false; frameError; false]);
starts = find(edges == 1);
stops = find(edges == -1) - 1;
burstLengths = double(stops - starts + 1);
if isempty(burstLengths)
    meanBurstFrames = 0.0;
    p95BurstFrames = 0.0;
    maxBurstFrames = 0.0;
else
    meanBurstFrames = mean(burstLengths);
    p95BurstFrames = step1.empiricalQuantile(burstLengths, 0.95);
    maxBurstFrames = max(burstLengths);
end

stats = struct();
stats.samples = n;
stats.successful_frames = sum(success);
stats.frame_errors = sum(frameError);
stats.availability = availability;
stats.standard_error = standardError;
stats.ci_low = max(0.0, availability - z * standardError);
stats.ci_high = min(1.0, availability + z * standardError);
stats.method = "nonoverlapping_batch_means_temporal_frames";
stats.block_frames = blockFrames;
stats.batches = batches;
stats.used_frames = usedFrames;
stats.discarded_tail_frames = n - usedFrames;
stats.effective_samples = effectiveSamples;
stats.correlation_inflation = correlationInflation;
stats.burst_count = numel(burstLengths);
stats.mean_burst_frames = meanBurstFrames;
stats.p95_burst_frames = p95BurstFrames;
stats.max_burst_frames = maxBurstFrames;
stats.burst_lengths = burstLengths(:);
end
