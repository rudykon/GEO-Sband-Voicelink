// Only for launcher contract tests; this executable never runs MATLAB.
using System;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;

public static class FakeMatlab {
    static string JsonString(string value) { return "\"" + value.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\""; }
    public static int Main(string[] arguments) {
        string mode = Environment.GetEnvironmentVariable("STEP1_FAKE_MATLAB_MODE");
        if (mode == "nonzero") return 7;
        string command = string.Join(" ", arguments);
        string runId = Regex.Match(command, "RunId='([^']+)'", RegexOptions.IgnoreCase).Groups[1].Value;
        if (runId.Length == 0) return 12;
        string root = Environment.GetEnvironmentVariable("STEP1_CANONICAL_PROJECT_ROOT");
        string runDir = Path.Combine(root, "artifacts", "results", "step1_design", "runs", runId);
        Directory.CreateDirectory(runDir);
        string[] outputs = { "results/summary.csv", "results/link_budget.csv", "results/sensitivity.csv", "results/trace.csv",
            "results/assumptions.json", "results/end_to_end_summary.csv", "results/chain_stages.csv", "results/module_manifest.json", "figures/design_overview.png", "report/design_report.md" };
        foreach (string relative in outputs) {
            if (mode == "missing_output" && relative == "results/end_to_end_summary.csv") continue;
            string path = Path.Combine(runDir, "staging", relative); Directory.CreateDirectory(Path.GetDirectoryName(path));
            File.WriteAllText(path, "launcher test fixture; not a simulation output");
        }
        if (mode == "comparison" || mode == "comparison_missing") {
            File.WriteAllText(Path.Combine(runDir, "staging", "results", "baseline_end_to_end_summary.csv"), "comparison baseline fixture");
            if (mode == "comparison") File.WriteAllText(Path.Combine(runDir, "staging", "results", "module_comparison.csv"), "paired comparison fixture");
        }
        string status = mode == "incomplete" ? "running" : "completed";
        string statusId = mode == "wrong_run" ? "unrelated-stale-run" : runId;
        string simulink = "";
        if (mode == "simulink_unicode" || mode == "simulink_missing_model") {
            string modelPath = Path.Combine(runDir, "staging", "simulink", "\u5929\u901a\u6a21\u578b.slx");
            Directory.CreateDirectory(Path.GetDirectoryName(modelPath));
            if (mode == "simulink_unicode") File.WriteAllText(modelPath, "fixture for path validation; not a Simulink model");
            simulink = ",\"simulink\":{\"status\":\"completed\",\"model_path\":" + JsonString(modelPath) +
                ",\"all_configured_cases_covered\":true,\"coverage_count\":1,\"coverage\":[{\"scenario\":\"fixture\"}],\"decision_mismatches\":0}";
        }
        File.WriteAllText(Path.Combine(runDir, "run_status.json"), "{\"schema_version\":\"step1-design-run-v1\",\"profile\":\"design\",\"run_id\":\"" + statusId + "\",\"status\":\"" + status + "\"" + simulink + "}", new UTF8Encoding(false));
        return 0;
    }
}
