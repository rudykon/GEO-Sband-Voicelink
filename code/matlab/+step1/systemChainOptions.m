function options = systemChainOptions(cfg)
%SYSTEMCHAINOPTIONS Shared engineering assumptions for chain and modules.
options = struct('downlink_margin_offset_db', 3, 'feeder_uplink_margin_db', 10, ...
    'feeder_downlink_margin_db', 10, 'satellite_frame_loss_probability', 0.0001, ...
    'ground_frame_loss_probability', 0.001, 'satellite_processing_ms', 10, ...
    'ground_network_ms', 30, 'gateway_slant_range_km', 40000, 'network_seed_offset', 7000003);
if isfield(cfg, 'design') && isfield(cfg.design, 'system_chain')
    overrides = cfg.design.system_chain;
    if ~isstruct(overrides) || ~isscalar(overrides)
        error("step1:DesignSystemChain", "design.system_chain must be a scalar struct.");
    end
    names = fieldnames(options);
    for index = 1:numel(names)
        if isfield(overrides, names{index}), options.(names{index}) = overrides.(names{index}); end
    end
end
names = fieldnames(options);
for index = 1:numel(names)
    value = options.(names{index});
    if ~isnumeric(value) || ~isreal(value) || ~isscalar(value) || ~isfinite(value)
        error("step1:DesignSystemChain", "design.system_chain.%s must be a finite scalar.", names{index});
    end
    options.(names{index}) = double(value);
end
for name = ["satellite_frame_loss_probability", "ground_frame_loss_probability"]
    if options.(name) < 0 || options.(name) > 1
        error("step1:DesignSystemChain", "design.system_chain.%s must lie in [0,1].", name);
    end
end
for name = ["satellite_processing_ms", "ground_network_ms"]
    if options.(name) < 0 || options.(name) > 600000
        error("step1:DesignSystemChain", "design.system_chain.%s must lie in [0,600000].", name);
    end
end
if options.gateway_slant_range_km <= 0 || options.gateway_slant_range_km > 100000
    error("step1:DesignSystemChain", "gateway_slant_range_km must lie in (0,100000].");
end
if options.network_seed_offset < 0 || options.network_seed_offset >= 2^32 ...
        || options.network_seed_offset ~= fix(options.network_seed_offset)
    error("step1:DesignSystemChain", "network_seed_offset must be an integer in [0,2^32).");
end
end
