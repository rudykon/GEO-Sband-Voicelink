function hex = sha256File(filePath)
%SHA256FILE Stream a file into the shared lowercase SHA-256 implementation.

filePath = char(string(filePath));
if ~isfile(filePath)
    error("step1:FileNotFound", "Cannot hash missing file: %s", filePath);
end

fid = fopen(filePath, "rb");
if fid < 0
    error("step1:FileOpen", "Cannot open file for hashing: %s", filePath);
end
cleanup = onCleanup(@() fclose(fid)); %#ok<NASGU>
digest = java.security.MessageDigest.getInstance("SHA-256");
if fseek(fid, 0, 'eof') ~= 0
    error("step1:FileRead", "Could not measure file for hashing: %s", filePath);
end
remaining = ftell(fid);
if fseek(fid, 0, 'bof') ~= 0
    error("step1:FileRead", "Could not rewind file for hashing: %s", filePath);
end
while remaining > 0
    requested = min(remaining, 1024 * 1024);
    [bytes, count] = fread(fid, requested, "*uint8");
    if count ~= requested
        error("step1:FileRead", "Incomplete file read while hashing: %s", filePath);
    end
    digest.update(typecast(bytes, "int8"));
    remaining = remaining - count;
end
raw = typecast(int8(digest.digest()), "uint8");
hex = lower(reshape(dec2hex(raw, 2).', 1, []));
end
