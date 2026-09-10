function hex = sha256Text(value)
%SHA256TEXT Return a lowercase SHA-256 digest of UTF-8 scalar text.

arguments
    value (1, 1) string
end

digest = java.security.MessageDigest.getInstance("SHA-256");
digest.update(typecast(unicode2native(char(value), "UTF-8"), "int8"));
signed = digest.digest();
unsigned = mod(double(signed), 256);
hex = lower(string(reshape(dec2hex(unsigned, 2).', 1, [])));
end
