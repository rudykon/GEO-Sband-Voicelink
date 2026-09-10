function result = auditSourceShare(varargin)
%AUDITSOURCESHARE Measure maintained source share without enforcing a quota.
%
% The audit counts logical source lines after removing blank and comment-only
% text. It includes executable code under code/matlab, code/python and scripts,
% excluding generated models, caches, and files outside these source roots.
%
% Name-value options:
%   ProjectRoot   Repository root (auto-detected by default).
%   MinimumShare Advisory MATLAB fraction (default 0.60).
%   WriteReport  Write a deterministic Markdown report (default true).
%   ReportPath   Markdown destination under artifacts/logs/source_share by default.
%   WriteMachineReports  Also write JSON and CSV reports (default true).
%   Enforce      Accepted but does not impose a language-share requirement.
%                Language share is descriptive, never an acceptance gate.

parser = inputParser;
parser.FunctionName = mfilename;
projectRoot = local_project_root();
defaultReport = '';
addParameter(parser, 'ProjectRoot', projectRoot, ...
    @(x) ischar(x) || (isstring(x) && isscalar(x)));
addParameter(parser, 'MinimumShare', 0.60, ...
    @(x) isnumeric(x) && isscalar(x) && x >= 0 && x <= 1);
addParameter(parser, 'WriteReport', true, ...
    @(x) islogical(x) && isscalar(x));
addParameter(parser, 'ReportPath', defaultReport, ...
    @(x) ischar(x) || (isstring(x) && isscalar(x)));
addParameter(parser, 'WriteMachineReports', true, ...
    @(x) islogical(x) && isscalar(x));
addParameter(parser, 'Enforce', false, ...
    @(x) islogical(x) && isscalar(x));
parse(parser, varargin{:});

projectRoot = char(string(parser.Results.ProjectRoot));
minimumShare = double(parser.Results.MinimumShare);

specifications = { ...
    'MATLAB', fullfile(projectRoot, 'code', 'matlab'), '.m'; ...
    'Python', fullfile(projectRoot, 'code', 'python'), '.py'; ...
    'Other', fullfile(projectRoot, 'scripts'), '.ps1'; ...
    'Other', fullfile(projectRoot, 'scripts'), '.cs'};

details = table('Size', [0 3], ...
    'VariableTypes', {'string', 'string', 'double'}, ...
    'VariableNames', {'language', 'file', 'logical_lines'});

for specificationIndex = 1:size(specifications, 1)
    language = string(specifications{specificationIndex, 1});
    searchRoot = specifications{specificationIndex, 2};
    selector = specifications{specificationIndex, 3};
    files = local_select_files(searchRoot, selector);
    for fileIndex = 1:numel(files)
        absolutePath = files{fileIndex};
        relativePath = local_relative_path(absolutePath, projectRoot);
        logicalLines = local_count_logical_lines(absolutePath, language);
        details = [details; {language, string(relativePath), logicalLines}]; %#ok<AGROW>
    end
end

if isempty(details)
    error('step1:audit:NoSourceFiles', ...
        'No maintained source files were found under %s.', projectRoot);
end

details = sortrows(details, {'language', 'file'});
matlabLines = sum(details.logical_lines(details.language == "MATLAB"));
pythonLines = sum(details.logical_lines(details.language == "Python"));
otherLines = sum(details.logical_lines(details.language == "Other"));
totalLines = matlabLines + pythonLines + otherLines;
if totalLines == 0
    matlabShare = 0;
else
    matlabShare = matlabLines / totalLines;
end
normalizedFiles = replace(details.file, "\", "/");
matlabTestMask = details.language == "MATLAB" ...
    & startsWith(normalizedFiles, "code/matlab/tests/");
matlabTestLines = sum(details.logical_lines(matlabTestMask));
productionMatlabLines = matlabLines - matlabTestLines;
productionTotalLines = productionMatlabLines + pythonLines + otherLines;
if productionTotalLines == 0
    productionMatlabShare = 0;
else
    productionMatlabShare = productionMatlabLines / productionTotalLines;
end

result = struct();
result.metric_version = 'matlab-source-share-v1';
result.project_root = projectRoot;
result.minimum_share = minimumShare;
result.design_target = 0.60;
result.policy = 'advisory';
result.enforced = false;
result.matlab_lines = matlabLines;
result.python_lines = pythonLines;
result.other_lines = otherLines;
result.total_lines = totalLines;
result.matlab_share = matlabShare;
result.matlab_test_lines = matlabTestLines;
result.production_matlab_lines = productionMatlabLines;
result.production_total_lines = productionTotalLines;
result.production_matlab_share = productionMatlabShare;
% The *_passes fields describe the soft target only; callers must not
% confuse them with scientific, simulation, or publication acceptance.
result.total_passes = matlabShare >= minimumShare;
result.production_passes = productionMatlabShare >= minimumShare;
result.passes = result.total_passes && result.production_passes;
result.details = details;
result.include_rules = { ...
    'code/matlab/**/*.m'; ...
    'code/python/**/*.py'; ...
    'scripts/**/*.ps1'; ...
    'scripts/**/*.cs'};
result.exclude_rules = { ...
    'blank and comment-only lines'; ...
    'code/matlab/**/slprj/**'; ...
    '*.slx and *.mlx binary files'; ...
    'paths outside code/matlab, code/python, and scripts'; ...
    'generated caches and virtual environments'};

if parser.Results.WriteReport
    reportPath = char(string(parser.Results.ReportPath));
    if isempty(reportPath)
        reportPath = fullfile(projectRoot, 'artifacts', 'logs', 'source_share', ...
            'matlab_source_share_report.md');
    end
    local_write_report(reportPath, result);
    if parser.Results.WriteMachineReports
        local_write_machine_reports(reportPath, result);
    end
end

end

function rootDir = local_project_root()
thisDir = fileparts(mfilename('fullpath'));
% +step1 is three directory levels below the repository root.
rootDir = fileparts(fileparts(fileparts(thisDir)));
end

function files = local_select_files(searchRoot, selector)
files = {};
if ~exist(searchRoot, 'dir')
    return;
end

listing = dir(fullfile(searchRoot, '**', ['*' selector]));
listing = listing(~[listing.isdir]);
for index = 1:numel(listing)
    candidate = fullfile(listing(index).folder, listing(index).name);
    normalized = strrep(candidate, '\', '/');
    if contains(normalized, '/slprj/') || contains(normalized, '/__pycache__/')
        continue;
    end
    files{end + 1, 1} = candidate; %#ok<AGROW>
end
end

function count = local_count_logical_lines(path, language)
text = fileread(path);
lines = regexp(text, '\r\n|\n|\r', 'split');
count = 0;
matlabBlockComment = false;
powerShellBlockComment = false;
csharpBlockComment = false;
[~, ~, extension] = fileparts(path);
isCsharp = strcmpi(extension, '.cs');

for lineIndex = 1:numel(lines)
    line = lines{lineIndex};
    trimmed = strtrim(line);
    if language == "MATLAB"
        if matlabBlockComment
            if startsWith(trimmed, '%}')
                matlabBlockComment = false;
            end
            continue;
        end
        if startsWith(trimmed, '%{')
            matlabBlockComment = true;
            continue;
        end
        code = local_strip_line_comment(line, '%');
    elseif language == "Python"
        code = local_strip_line_comment(line, '#');
    elseif isCsharp
        [code, csharpBlockComment] = local_strip_csharp_comments(line, csharpBlockComment);
    else
        if powerShellBlockComment
            if contains(trimmed, '#>')
                powerShellBlockComment = false;
            end
            continue;
        end
        if startsWith(trimmed, '<#')
            if ~contains(trimmed, '#>')
                powerShellBlockComment = true;
            end
            continue;
        end
        code = local_strip_line_comment(line, '#');
    end
    if ~isempty(strtrim(code))
        count = count + 1;
    end
end
end

function [code, inBlock] = local_strip_csharp_comments(line, inBlock)
% Strip both C# comment forms without stripping comment tokens in strings.
code = '';
quote = char(0);
verbatim = false;
index = 1;
while index <= numel(line)
    character = line(index);
    hasNext = index < numel(line);
    if inBlock
        if hasNext && character == '*' && line(index + 1) == '/'
            inBlock = false;
            index = index + 2;
        else
            index = index + 1;
        end
        continue;
    end
    if quote ~= char(0)
        code(end + 1) = character; %#ok<AGROW>
        if ~verbatim && character == '\' && hasNext
            code(end + 1) = line(index + 1); %#ok<AGROW>
            index = index + 2;
            continue;
        end
        if character == quote
            if verbatim && hasNext && line(index + 1) == quote
                code(end + 1) = line(index + 1); %#ok<AGROW>
                index = index + 2;
                continue;
            end
            quote = char(0);
        end
    elseif hasNext && character == '/' && line(index + 1) == '/'
        break;
    elseif hasNext && character == '/' && line(index + 1) == '*'
        inBlock = true;
        index = index + 2;
        continue;
    else
        code(end + 1) = character; %#ok<AGROW>
        if character == '''' || character == '"'
            quote = character;
            verbatim = character == '"' && index > 1 && line(index - 1) == '@';
        end
    end
    index = index + 1;
end
end

function code = local_strip_line_comment(line, marker)
inSingleQuote = false;
inDoubleQuote = false;
index = 1;
while index <= strlength(string(line))
    character = line(index);
    if character == '''' && ~inDoubleQuote
        if inSingleQuote && index < length(line) && line(index + 1) == ''''
            index = index + 2;
            continue;
        end
        inSingleQuote = ~inSingleQuote;
    elseif character == '"' && ~inSingleQuote
        if inDoubleQuote && index > 1 && line(index - 1) == '\'
            index = index + 1;
            continue;
        end
        inDoubleQuote = ~inDoubleQuote;
    elseif character == marker && ~inSingleQuote && ~inDoubleQuote
        code = line(1:index - 1);
        return;
    end
    index = index + 1;
end
code = line;
end

function relative = local_relative_path(absolute, rootDir)
absolute = strrep(char(java.io.File(absolute).getCanonicalPath()), '\', '/');
rootDir = strrep(char(java.io.File(rootDir).getCanonicalPath()), '\', '/');
prefix = [rootDir '/'];
if startsWith(lower(absolute), lower(prefix))
    relative = absolute(length(prefix) + 1:end);
else
    relative = absolute;
end
end

function local_write_report(reportPath, result)
reportDir = fileparts(reportPath);
if ~isempty(reportDir) && ~exist(reportDir, 'dir')
    mkdir(reportDir);
end
fid = fopen(reportPath, 'w');
if fid < 0
    error('step1:audit:ReportOpenFailed', ...
        'Could not open audit report for writing: %s', reportPath);
end
cleanup = onCleanup(@() fclose(fid));

fprintf(fid, '# MATLAB Source Share Audit\n\n');
fprintf(fid, '- Metric: `%s`\n', result.metric_version);
fprintf(fid, '- Advisory comparison share: `%.2f%%`\n', 100 * result.minimum_share);
fprintf(fid, '- Approximate design preference: `%.2f%%`\n', 100 * result.design_target);
fprintf(fid, '- Policy: advisory; language share never blocks simulation or release.\n');
fprintf(fid, '- Measured MATLAB share (production + tests): `%.2f%%`\n', 100 * result.matlab_share);
fprintf(fid, '- Measured MATLAB share (production only): `%.2f%%`\n', ...
    100 * result.production_matlab_share);
fprintf(fid, '- Soft-target comparison: **%s**\n\n', local_pass_label(result.passes));
fprintf(fid, '| Language | Logical source lines |\n');
fprintf(fid, '|---|---:|\n');
fprintf(fid, '| MATLAB | %d |\n', result.matlab_lines);
fprintf(fid, '| Python | %d |\n', result.python_lines);
fprintf(fid, '| Other first-party scripts | %d |\n', result.other_lines);
fprintf(fid, '| Total | %d |\n', result.total_lines);
fprintf(fid, '| MATLAB test code (included above) | %d |\n', result.matlab_test_lines);
fprintf(fid, '| MATLAB production code | %d |\n', result.production_matlab_lines);
fprintf(fid, '| Production denominator | %d |\n\n', result.production_total_lines);

fprintf(fid, '## Counting Contract\n\n');
fprintf(fid, 'Included first-party source roots:\n\n');
for index = 1:numel(result.include_rules)
    fprintf(fid, '- `%s`\n', result.include_rules{index});
end
fprintf(fid, '\nExcluded from the denominator:\n\n');
for index = 1:numel(result.exclude_rules)
    fprintf(fid, '- %s\n', result.exclude_rules{index});
end

fprintf(fid, '\n## Per-file Detail\n\n');
fprintf(fid, '| Language | File | Logical lines |\n');
fprintf(fid, '|---|---|---:|\n');
for row = 1:height(result.details)
    fprintf(fid, '| %s | `%s` | %d |\n', ...
        result.details.language(row), ...
        strrep(result.details.file(row), '|', '\|'), ...
        result.details.logical_lines(row));
end
clear cleanup;
end

function local_write_machine_reports(markdownPath, result)
[reportDir, reportName] = fileparts(markdownPath);
jsonPath = fullfile(reportDir, [reportName '.json']);
csvPath = fullfile(reportDir, [reportName '.csv']);

machine = rmfield(result, 'details');
machine.details = table2struct(result.details);
jsonText = jsonencode(machine, PrettyPrint=true);
jsonFid = fopen(jsonPath, 'w');
if jsonFid < 0
    error('step1:audit:JsonReportOpenFailed', ...
        'Could not open JSON audit report: %s', jsonPath);
end
jsonCleanup = onCleanup(@() fclose(jsonFid));
fprintf(jsonFid, '%s\n', jsonText);
clear jsonCleanup;

writetable(result.details, csvPath);
end

function label = local_pass_label(passes)
if passes
    label = 'AT OR ABOVE REFERENCE';
else
    label = 'BELOW REFERENCE (INFORMATIONAL)';
end
end
