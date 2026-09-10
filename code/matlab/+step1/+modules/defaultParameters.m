function params = defaultParameters(params, defaults)
%DEFAULTPARAMETERS Strict scalar numeric parameters for the supplied modules.
% Custom implementations own their parameter schema and need not use this.
if ~isstruct(params) || ~isscalar(params)
    error('step1:ModuleParameters', 'Module parameters must be a scalar struct.');
end
unknown = setdiff(fieldnames(params), fieldnames(defaults));
if ~isempty(unknown)
    error('step1:ModuleParameters', 'Unknown module parameter: %s.', unknown{1});
end
for name = string(fieldnames(defaults)).'
    if ~isfield(params, name), params.(name) = defaults.(name); end
    value = params.(name);
    if ~isnumeric(value) || ~isreal(value) || ~isscalar(value) || ~isfinite(value)
        error('step1:ModuleParameters', 'Module parameter %s must be a finite numeric scalar.', name);
    end
    params.(name) = double(value);
end
end
