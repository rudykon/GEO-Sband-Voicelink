function paths = defaultPaths()
%DEFAULTPATHS Resolve active modular macro-chain paths.

packageDir = fileparts(mfilename("fullpath"));
matlabDir = fileparts(packageDir);
codeDir = fileparts(matlabDir);
rootDir = fileparts(codeDir);
canonicalRoot = strtrim(getenv("STEP1_CANONICAL_PROJECT_ROOT"));
if strlength(string(canonicalRoot)) > 0
    if ~isfolder(canonicalRoot)
        error("step1:CanonicalRoot", ...
            "STEP1_CANONICAL_PROJECT_ROOT does not name a directory: %s", canonicalRoot);
    end
    rootDir = char(canonicalRoot);
    codeDir = fullfile(rootDir, "code");
    matlabDir = fullfile(codeDir, "matlab");
end

paths = struct();
paths.rootDir = rootDir;
paths.codeDir = codeDir;
paths.matlabDir = matlabDir;
paths.configDir = fullfile(rootDir, "config");
paths.defaultConfig = fullfile(paths.configDir, "step1_macro_chain.json");
paths.resultsDir = fullfile(rootDir, "artifacts", "results");
paths.matlabResultsDir = fullfile(paths.resultsDir, "step1_design");
paths.designResultsDir = paths.matlabResultsDir;
end
