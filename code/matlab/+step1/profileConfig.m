function cfg = profileConfig(cfg, profileName)
%PROFILECONFIG Resolve the single macro profile and its quick alias.
if nargin < 2 || strlength(string(profileName)) == 0
    profileName = "design";
    if isfield(cfg, 'default_profile'), profileName = string(cfg.default_profile); end
end
profileName = lower(strtrim(string(profileName)));
if ~isscalar(profileName)
    error('step1:UnknownProfile', 'Profile must be one name.');
end
if profileName == "full"
    error('step1:RetiredProfile', 'Profile full is not supported. Use design for the macro workflow.');
end
if ~any(profileName == ["design", "quick"])
    error('step1:UnknownProfile', 'Profile must be design or quick; both run the macro workflow.');
end
cfg.default_profile = 'design';
cfg.runtime = struct('profile', 'design', 'requested_profile', char(profileName));
end
