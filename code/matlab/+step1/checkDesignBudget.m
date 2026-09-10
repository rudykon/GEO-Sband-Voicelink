function elapsed = checkDesignBudget(budget, runTimer, stage)
%CHECKDESIGNBUDGET Cooperative phase boundary; launcher owns hard watchdog.
elapsed = toc(runTimer);
if elapsed > budget.matlab_seconds
    error('step1:DesignTimeout', ...
        'Design exceeded its %.1f s MATLAB budget before %s (%.2f s elapsed).', ...
        budget.matlab_seconds, string(stage), elapsed);
end
end
