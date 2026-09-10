function writeTextAtomic(path, text)
%WRITETEXTATOMIC Replace a text file through a same-directory temporary.

arguments
    path (1, 1) string
    text {mustBeTextScalar}
end

parent = fileparts(path);
if ~isfolder(parent)
    mkdir(parent);
end
temporary = string(tempname(parent)) + ".tmp";
cleanup = onCleanup(@() localDeleteIfPresent(temporary));

payload = char(string(text));
if ~endsWith(string(text), newline)
    payload = [payload newline]; %#ok<AGROW>
end
fid = fopen(temporary, "wb", "n", "UTF-8");
if fid < 0
    error("step1:io:OpenFailed", "Could not open temporary file: %s", temporary);
end
try
    payloadBytes = unicode2native(payload, "UTF-8");
    bytesWritten = fwrite(fid, payloadBytes, "uint8");
    [streamMessage, streamError] = ferror(fid);
    expectedBytes = numel(payloadBytes);
    if streamError ~= 0 || bytesWritten ~= expectedBytes
        error("step1:io:WriteFailed", ...
            "Incomplete UTF-8 write to %s: wrote %d of %d bytes; ferror='%s'.", ...
            temporary, bytesWritten, expectedBytes, string(streamMessage));
    end
    closeStatus = fclose(fid);
    if closeStatus ~= 0
        error("step1:io:CloseFailed", ...
            "Could not close temporary file after writing: %s", temporary);
    end
catch writeException
    if fid >= 0
        try
            fclose(fid);
        catch
        end
    end
    rethrow(writeException);
end
step1.io.forceFile(temporary);
try
    step1.io.atomicMove(temporary, path, true);
catch moveException
    failure = MException("step1:io:AtomicReplaceFailed", ...
        "Could not atomically replace %s.", path);
    failure = addCause(failure, moveException);
    throw(failure);
end
step1.io.forceFile(path);
delete(cleanup);
end

function localDeleteIfPresent(path)
if isfile(path)
    delete(path);
end
end
