function writeTableAtomic(path, value)
%WRITETABLEATOMIC Write a table via a same-directory temporary file.

arguments
    path (1, 1) string
    value table
end

parent = fileparts(path);
if ~isfolder(parent)
    mkdir(parent);
end
temporary = string(tempname(parent)) + ".csv";
cleanup = onCleanup(@() localDeleteIfPresent(temporary));
writetable(value, temporary, Encoding="UTF-8");
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
