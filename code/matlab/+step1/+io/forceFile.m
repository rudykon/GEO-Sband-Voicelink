function forceFile(path)
%FORCEFILE Force existing-file content and metadata through a JVM channel.
% The channel is opened with WRITE but without CREATE, so a deletion race
% fails closed instead of recreating an empty path.

arguments
    path (1, 1) string
end
try
    filePath = java.io.File(char(path)).toPath();
    writeOption = javaMethod( ...
        "valueOf", "java.nio.file.StandardOpenOption", "WRITE");
    options = javaArray("java.nio.file.OpenOption", 1);
    options(1) = writeOption;
    channel = javaMethod( ...
        "open", "java.nio.channels.FileChannel", filePath, options);
catch openException
    failure = MException("step1:io:ForceOpenFailed", ...
        "Could not open an existing file for forcing: %s", path);
    failure = addCause(failure, openException);
    throw(failure);
end
cleanup = onCleanup(@() localClose(channel)); %#ok<NASGU>
try
    channel.force(true);
catch forceException
    failure = MException("step1:io:ForceFailed", ...
        "Could not force file to stable storage: %s", path);
    failure = addCause(failure, forceException);
    throw(failure);
end
end

function localClose(channel)
try
    channel.close();
catch
end
end
