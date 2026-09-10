function comparison = compareDesignResults(baseline, candidate)
%COMPARE DESIGN RESULTS Pair every simulated frame, never the sampled trace.
% Baseline/candidate must share the same scenario, sample and seed context.
% Deltas are candidate minus baseline; availability is in percentage points.
arguments
    baseline (1,1) struct
    candidate (1,1) struct
end
required = {'comparison_samples','end_to_end_summary','assumptions'};
if ~all(isfield(baseline,required)) || ~all(isfield(candidate,required))
    error('step1:ComparisonContract','Complete frame samples and assumptions are required.');
end
if isfield(baseline,'comparison_context') && isfield(candidate,'comparison_context')
    if ~isequaln(baseline.comparison_context,candidate.comparison_context)
        error('step1:ComparisonContext','Paired runs must use identical channel and sampling inputs.');
    end
else
    error('step1:ComparisonContext','Paired runs require a comparison_context fingerprint.');
end
base = baseline.comparison_samples;
cand = candidate.comparison_samples;
if isempty(base) || numel(base) ~= numel(cand)
    error('step1:ComparisonCases','Baseline and candidate case counts differ.');
end
rows = cell(numel(base),1);
seen = strings(numel(base),1);
for index = 1:numel(base)
    b = base(index);
    key = string(b.scenario_key) + "/" + string(b.voice_rate_bps);
    if any(seen == key), error('step1:ComparisonCases','Duplicate case %s.',key); end
    seen(index) = key;
    match = find(string({cand.scenario_key}) == string(b.scenario_key) ...
        & [cand.voice_rate_bps] == b.voice_rate_bps);
    if numel(match) ~= 1, error('step1:ComparisonCases','Missing or duplicate candidate %s.',key); end
    c = cand(match);
    fields = {'end_to_end_closed','forward_delay_ms','return_delay_ms'};
    if ~all(isfield(b,fields)) || ~all(isfield(c,fields)) ...
            || b.frame_duration_ms ~= c.frame_duration_ms
        error('step1:ComparisonContract','Invalid paired frame contract for %s.',key);
    end
    for field = string(fields)
        if ~isequal(size(b.(field)),size(c.(field))) || isempty(b.(field)) ...
                || any(~isfinite(b.(field)),'all') || any(~isfinite(c.(field)),'all')
            error('step1:ComparisonContract','Frame shape/values differ for %s.',key);
        end
    end
    if ~islogical(b.end_to_end_closed) || ~islogical(c.end_to_end_closed)
        error('step1:ComparisonContract','End-to-end decisions must be logical.');
    end
    improved = sum(~b.end_to_end_closed & c.end_to_end_closed,'all');
    regressed = sum(b.end_to_end_closed & ~c.end_to_end_closed,'all');
    total = numel(b.end_to_end_closed);
    bi = find(string(baseline.end_to_end_summary.scenario_key) == string(b.scenario_key) ...
        & baseline.end_to_end_summary.voice_rate_bps == b.voice_rate_bps);
    ci = find(string(candidate.end_to_end_summary.scenario_key) == string(b.scenario_key) ...
        & candidate.end_to_end_summary.voice_rate_bps == b.voice_rate_bps);
    if numel(bi) ~= 1 || numel(ci) ~= 1
        error('step1:ComparisonCases','Summary case lookup is not unique.');
    end
    bAvailability = mean(b.end_to_end_closed,'all');
    cAvailability = mean(c.end_to_end_closed,'all');
    row = struct('scenario_key',string(b.scenario_key),'voice_rate_bps',b.voice_rate_bps, ...
        'baseline_availability',bAvailability,'candidate_availability',cAvailability, ...
        'availability_delta_pp',100*(cAvailability-bAvailability), ...
        'improved_frames',improved,'regressed_frames',regressed, ...
        'unchanged_frames',total-improved-regressed,'paired_frames',total, ...
        'baseline_forward_delay_ms',mean(b.forward_delay_ms,'all'), ...
        'candidate_forward_delay_ms',mean(c.forward_delay_ms,'all'), ...
        'forward_delay_delta_ms',mean(c.forward_delay_ms-b.forward_delay_ms,'all'), ...
        'baseline_return_delay_ms',mean(b.return_delay_ms,'all'), ...
        'candidate_return_delay_ms',mean(c.return_delay_ms,'all'), ...
        'return_delay_delta_ms',mean(c.return_delay_ms-b.return_delay_ms,'all'), ...
        'baseline_max_outage_ms',baseline.end_to_end_summary.max_outage_ms(bi), ...
        'candidate_max_outage_ms',candidate.end_to_end_summary.max_outage_ms(ci), ...
        'scope',"paired_all_frames_all_replicates_model_outputs");
    rows{index} = struct2table(row);
end
comparison = vertcat(rows{:});
end
