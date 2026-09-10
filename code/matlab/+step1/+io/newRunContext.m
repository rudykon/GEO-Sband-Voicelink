function context = newRunContext(projectRoot, profile, requestedRunId, outputConfig)
%NEWRUNCONTEXT Create one isolated macro run and its output directories.

arguments
    projectRoot (1, 1) string
    profile (1, 1) string
    requestedRunId (1, 1) string = ""
    outputConfig (1, 1) struct = struct()
end

if strcmpi(profile, 'full')
    error('step1:RetiredProfile', 'Profile full is not supported. Use design for the macro workflow.');
end
if ~any(strcmpi(profile, ["design", "quick"]))
    error('step1:UnknownProfile', 'Only the macro design profile is active.');
end
profile = "design";
projectRoot = string(java.io.File(char(projectRoot)).getCanonicalPath());
runsRelative = fullfile("artifacts", "results", "step1_design", "runs");
if isfield(outputConfig, "runs_relative_dir")
    runsRelative = string(outputConfig.runs_relative_dir);
end
runsRoot = localResolveInsideProject(projectRoot, runsRelative, ...
    "output.runs_relative_dir");
if ~isfolder(runsRoot)
    mkdir(runsRoot);
end

if strlength(requestedRunId) == 0
    stamp = string(datetime("now", "TimeZone", "UTC", ...
        "Format", "yyyyMMdd'T'HHmmssSSS'Z'"));
    randomPath = string(tempname(runsRoot));
    [~, randomName] = fileparts(randomPath);
    requestedRunId = stamp + "-" + profile + "-" + extractAfter(randomName, max(0, strlength(randomName) - 8));
end

runId = regexprep(requestedRunId, "[^A-Za-z0-9_.-]", "-");
if strlength(runId) == 0 || runId == "." || runId == ".."
    error("step1:io:InvalidRunId", "RunId must contain a safe filename character.");
end

runDir = fullfile(runsRoot, runId);
if isfolder(runDir) || isfile(runDir)
    error("step1:io:RunAlreadyExists", ...
        "Refusing to reuse an existing immutable run directory: %s", runDir);
end

stagingDir = fullfile(runDir, "staging");
resultDir = fullfile(stagingDir, "results");
figureDir = fullfile(stagingDir, "figures");
reportDir = fullfile(stagingDir, "report");
mkdir(resultDir);
mkdir(figureDir);
mkdir(reportDir);

context = struct();
context.schemaVersion = "step1-design-run-context-v1";
context.projectRoot = projectRoot;
context.profile = profile;
context.runId = runId;
context.runsRoot = string(runsRoot);
context.runDir = string(runDir);
context.stagingDir = string(stagingDir);
context.resultDir = string(resultDir);
context.figureDir = string(figureDir);
context.reportDir = string(reportDir);
context.statusPath = string(fullfile(runDir, "run_status.json"));
context.latestStatusPath = string(fullfile(fileparts(runsRoot), "latest_status.json"));
end

function resolved = localResolveInsideProject(projectRoot, relativePath, label)
relativePath = string(relativePath);
candidateFile = java.io.File(char(relativePath));
if candidateFile.isAbsolute()
    error("step1:io:OutputPathOutsideProject", ...
        "%s must be relative to the project root.", label);
end
resolved = string(java.io.File(char(fullfile(projectRoot, relativePath))).getCanonicalPath());
rootPrefix = projectRoot + filesep;
if ispc
    inside = startsWith(lower(resolved), lower(rootPrefix));
else
    inside = startsWith(resolved, rootPrefix);
end
if ~inside
    error("step1:io:OutputPathOutsideProject", ...
        "%s resolves outside the project root: %s", label, resolved);
end
end
