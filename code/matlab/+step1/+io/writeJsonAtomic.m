function writeJsonAtomic(path, value)
%WRITEJSONATOMIC JSON-encode a value and replace the destination atomically.

arguments
    path (1, 1) string
    value
end

try
    encoded = jsonencode(value, PrettyPrint=true);
catch
    encoded = jsonencode(value);
end
step1.io.writeTextAtomic(path, encoded);
end
