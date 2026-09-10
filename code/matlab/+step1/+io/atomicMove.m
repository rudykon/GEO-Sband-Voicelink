function atomicMove(source, destination, replaceExisting)
%ATOMICMOVE Require one same-filesystem Java NIO atomic rename.
% No copy/delete fallback is permitted for run state or result replacement.
% Unsupported filesystems therefore fail closed.

arguments
    source (1, 1) string
    destination (1, 1) string
    replaceExisting (1, 1) logical = false
end

sourcePath = java.io.File(char(source)).toPath();
destinationPath = java.io.File(char(destination)).toPath();
atomicOption = javaMethod( ...
    "valueOf", "java.nio.file.StandardCopyOption", "ATOMIC_MOVE");
if replaceExisting
    replaceOption = javaMethod( ...
        "valueOf", "java.nio.file.StandardCopyOption", "REPLACE_EXISTING");
    options = javaArray("java.nio.file.CopyOption", 2);
    options(1) = atomicOption;
    options(2) = replaceOption;
else
    options = javaArray("java.nio.file.CopyOption", 1);
    options(1) = atomicOption;
end

try
    javaMethod("move", "java.nio.file.Files", ...
        sourcePath, destinationPath, options);
catch moveException
    failure = MException("step1:io:AtomicMoveFailed", ...
        "Required atomic move failed: %s -> %s", source, destination);
    failure = addCause(failure, moveException);
    throw(failure);
end
end
