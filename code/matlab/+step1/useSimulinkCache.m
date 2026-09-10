function [cleanup, locations] = useSimulinkCache(cacheRoot)
%USESIMULINKCACHE Keep generated Simulink files outside source directories.
% Keep CLEANUP alive for the simulation scope; releasing it restores the
% caller's complete file-generation configuration, including on errors.
% MATLAB may resolve loaded sources through a Windows junction. Reuse only
% an existing, verified launcher alias to preserve ASCII compiler paths.
arguments
    cacheRoot (1,1) string = ""
end
if strlength(cacheRoot) == 0
    packageDir = fileparts(mfilename('fullpath'));
    executionRoot = fileparts(fileparts(fileparts(packageDir)));
    executionRoot = localExecutionRoot(executionRoot);
    cacheRoot = fullfile(executionRoot,'artifacts','cache','simulink');
elseif ~java.io.File(char(cacheRoot)).isAbsolute()
    cacheRoot = fullfile(pwd,cacheRoot);
end
locations = struct('root',string(cacheRoot), ...
    'cache_folder',string(fullfile(cacheRoot,'cache')), ...
    'codegen_folder',string(fullfile(cacheRoot,'codegen')), ...
    'ascii_path',all(double(char(cacheRoot))<=127));
for name = ["cache_folder","codegen_folder"]
    if ~isfolder(locations.(name)), mkdir(locations.(name)); end
end
original = Simulink.fileGenControl('getConfig');
cleanup = onCleanup(@() Simulink.fileGenControl('setConfig','config',original));
Simulink.fileGenControl('set', ...
    'CacheFolder',char(locations.cache_folder), ...
    'CodeGenFolder',char(locations.codegen_folder));
end

function executionRoot = localExecutionRoot(sourceRoot)
executionRoot = sourceRoot;
if ~ispc, return; end
candidates = [string(getenv('STEP1_MATLAB_EXECUTION_ROOT')), ...
    string(getenv('STEP1_MATLAB_ALIAS_ROOT'))];
if any(double(char(sourceRoot))>127)
    digest = char(step1.io.sha256Text(sourceRoot));
    candidates(end+1) = string(fullfile(tempdir,['step1_link_matlab_' digest(1:12)]));
end
for candidate = candidates
    if strlength(candidate)==0 || any(double(char(candidate))>127) || ~isfolder(candidate)
        continue;
    end
    % getCanonicalPath alone does not resolve Windows directory junctions.
    % Files.isSameFile compares their actual filesystem identity instead.
    if java.nio.file.Files.isSameFile(java.io.File(char(candidate)).toPath(), ...
            java.io.File(char(sourceRoot)).toPath())
        executionRoot = char(candidate);
        return;
    end
end
end
