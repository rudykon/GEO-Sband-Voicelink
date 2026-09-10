function value = exceptionStruct(exception)
%EXCEPTIONSTRUCT Convert an MException into a JSON-safe diagnostic struct.

arguments
    exception (1, 1) MException
end

value = struct();
value.identifier = string(exception.identifier);
value.message = string(exception.message);
value.report = string(getReport(exception, "extended", "hyperlinks", "off"));

frames = exception.stack;
stack = repmat(struct("file", "", "name", "", "line", 0), numel(frames), 1);
for i = 1:numel(frames)
    stack(i).file = string(frames(i).file);
    stack(i).name = string(frames(i).name);
    stack(i).line = frames(i).line;
end
value.stack = stack;

if isempty(exception.cause)
    value.causes = struct.empty(0, 1);
else
    causes = repmat(struct("identifier", "", "message", ""), numel(exception.cause), 1);
    for i = 1:numel(exception.cause)
        causes(i).identifier = string(exception.cause{i}.identifier);
        causes(i).message = string(exception.cause{i}.message);
    end
    value.causes = causes;
end
end
