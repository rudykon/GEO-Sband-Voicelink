function cfg = loadConfig(configPath, profileName)
%LOADCONFIG Load a complete config or a one-level base_config/overrides file.
% Ordinary objects merge recursively; arrays replace. Module and Simulink
% override maps replace wholesale, so inherited slot parameters never leak.

if nargin >= 2 && isscalar(string(profileName)) && strcmpi(strtrim(string(profileName)), 'full')
    error('step1:RetiredProfile', 'Profile full is not supported. Use design for the macro workflow.');
end

paths = step1.defaultPaths();
if nargin < 1 || strlength(string(configPath)) == 0
    configPath = paths.defaultConfig;
else
    configPath = char(string(configPath));
    if ~step1_is_absolute_path(configPath)
        configPath = fullfile(pwd, configPath);
    end
end
if nargin < 2
    profileName = "";
end
if ~isfile(configPath)
    error("step1:ConfigNotFound", "Step 1 configuration file does not exist: %s", configPath);
end
% The Windows launcher may enter through its validated ASCII junction. Store
% the real configuration path in run metadata for portable artifact links.
configPath = char(java.io.File(configPath).getCanonicalPath());

cfg = localReadJson(configPath);
baseConfigPath = "";
baseConfigSha256 = "";
if isstruct(cfg) && any(isfield(cfg, {'base_config','overrides'}))
    if ~isscalar(cfg) || ~all(isfield(cfg, {'base_config','overrides'})) ...
            || numel(fieldnames(cfg)) ~= 2 || ~localText(cfg.base_config)
        error('step1:ConfigInheritance', ...
            'An inherited config must contain only a nonempty base_config path and an overrides object.');
    end
    if ~isstruct(cfg.overrides) || ~isscalar(cfg.overrides) ...
            || any(isfield(cfg.overrides, {'base_config','overrides'}))
        error('step1:ConfigOverrides', 'overrides must be one object without inheritance wrapper fields.');
    end
    baseConfigPath = char(string(cfg.base_config));
    if ~step1_is_absolute_path(baseConfigPath)
        baseConfigPath = fullfile(fileparts(configPath), baseConfigPath);
    end
    if ~isfile(baseConfigPath)
        error('step1:ConfigBaseNotFound', 'Base configuration does not exist: %s', baseConfigPath);
    end
    baseConfigPath = char(java.io.File(baseConfigPath).getCanonicalPath());
    base = localReadJson(baseConfigPath);
    if ~isstruct(base) || ~isscalar(base) || any(isfield(base, {'base_config','overrides'}))
        error('step1:ConfigInheritance', 'The base must be a complete configuration without further inheritance.');
    end
    cfg = localMerge(base, cfg.overrides, "");
    baseConfigSha256 = step1.sha256File(baseConfigPath);
end

cfg = step1.validateConfig(cfg, configPath);
cfg = step1.profileConfig(cfg, profileName);
cfg.configPath = configPath;
cfg.configSha256 = step1.sha256File(configPath);
cfg.baseConfigPath = baseConfigPath;
cfg.baseConfigSha256 = baseConfigSha256;
paths.configPath = configPath;
cfg.paths = paths;
end

function value = localReadJson(path)
try
    value = jsondecode(fileread(path));
catch configError
    error('step1:ConfigJson', 'Invalid Step 1 JSON config %s: %s', path, configError.message);
end
end

function tf = localText(value)
tf = (ischar(value) && isrow(value) || isstring(value) && isscalar(value)) ...
    && strlength(strtrim(string(value))) > 0;
end

function result = localMerge(base, overrides, parent)
result = base;
for name = string(fieldnames(overrides)).'
    path = name;
    if parent ~= "", path = parent + "." + name; end
    value = overrides.(name);
    replaceMap = any(path == ["design.modules","design.simulink_overrides"]);
    if replaceMap && (~isstruct(value) || ~isscalar(value))
        error('step1:ConfigOverrides', '%s must be one object and replaces the whole module map.', path);
    end
    % JSON object arrays decode as structs; scenarios must replace even
    % when both the base and override scenario arrays have one element.
    if ~replaceMap && path ~= "scenarios" && isfield(base,name) ...
            && isstruct(base.(name)) && isscalar(base.(name)) ...
            && isstruct(value) && isscalar(value)
        result.(name) = localMerge(base.(name), value, path);
    else
        result.(name) = value;
    end
end
end

function tf = step1_is_absolute_path(pathValue)
if ispc
    tf = ~isempty(regexp(pathValue, '^[A-Za-z]:[\\/]|^\\\\', 'once'));
else
    tf = startsWith(pathValue, filesep);
end
end
