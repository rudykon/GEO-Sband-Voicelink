function geometry = resolveGeometry(cfg)
%RESOLVEGEOMETRY Resolve fixed or coordinate-derived GEO geometry.

g = cfg.geometry;
mode = lower(string(g.mode));
if mode == "fixed"
    geometry = struct( ...
        "mode", "fixed", ...
        "elevation_deg", double(g.fixed_elevation_deg), ...
        "slant_range_km", double(g.fixed_slant_range_km), ...
        "central_angle_deg", NaN);
    return;
end
if mode ~= "coordinates"
    error("step1:GeometryMode", "Unknown geometry mode '%s'.", mode);
end

latitudeRad = deg2rad(double(g.terminal_lat_deg));
longitudeDifferenceRad = deg2rad(step1_wrap_longitude(double(g.geo_longitude_deg) - double(g.terminal_lon_deg)));
cosCentral = cos(latitudeRad) * cos(longitudeDifferenceRad);
cosCentral = min(max(cosCentral, -1.0), 1.0);
centralAngle = acos(cosCentral);
earthRadius = double(g.earth_radius_km);
orbitRadius = double(g.geo_orbit_radius_km);
slantRange = sqrt(orbitRadius ^ 2 + earthRadius ^ 2 - 2.0 * orbitRadius * earthRadius * cosCentral);
elevation = atan2d(orbitRadius * cosCentral - earthRadius, orbitRadius * sin(centralAngle));
if elevation <= 0
    error("step1:GeometryVisibility", "Configured GEO satellite is below the terminal horizon (%.3f deg).", elevation);
end
geometry = struct( ...
    "mode", "coordinates", ...
    "elevation_deg", elevation, ...
    "slant_range_km", slantRange, ...
    "central_angle_deg", rad2deg(centralAngle));
end

function longitude = step1_wrap_longitude(longitude)
longitude = mod(longitude + 180.0, 360.0) - 180.0;
end
