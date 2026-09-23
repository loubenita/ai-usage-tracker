import UsageDomain

/// The owner's table for the three-letter label in each ring. A session name, branch or
/// folder name that contains the keyword (any case) gets the label.
///
/// How a label is picked, first match wins:
/// 1. a ticket number in the session name or branch: "PROJ-60-Fixer" is F60;
/// 2. this table, tried on the session name, then the branch, then the folder name;
/// 3. the name you gave the session (`claude --name lead` is LEA);
/// 4. the branch's first word ("chore/architectureLint" is ARC);
/// 5. HOM for the home folder, otherwise the folder's first three letters.
///
/// Edit freely. Lines higher up win, so put the more specific keyword first
/// ("debug" before "bug", "hotfix" before "fix").
public enum LabelRules {
    public static let table: [LabelRule] = [
        // Media
        LabelRule("image", "IMG"),
        LabelRule("video", "VID"),
        LabelRule("audio", "AUD"),
        // Fixing things
        LabelRule("debug", "DEBG"),
        LabelRule("hotfix", "FIX"),
        LabelRule("bugfix", "BUG"),
        LabelRule("bug", "BUG"),
        LabelRule("crash", "BUG"),
        // Kinds of change
        LabelRule("refactor", "REF"),
        LabelRule("cleanup", "CLN"),
        LabelRule("migration", "MIG"),
        LabelRule("migrate", "MIG"),
        LabelRule("upgrade", "UPG"),
        LabelRule("perf", "PRF"),
        LabelRule("lint", "LINT"),
        LabelRule("test", "TEST"),
        LabelRule("docs", "DOCS"),
        LabelRule("readme", "DOCS"),
        LabelRule("release", "REL"),
        LabelRule("deploy", "DEP"),
        LabelRule("review", "REV"),
        LabelRule("research", "RES"),
        LabelRule("spike", "SPK"),
        LabelRule("prototype", "PRO"),
        // Product areas
        LabelRule("design", "DES"),
        LabelRule("onboarding", "ONB"),
        LabelRule("login", "AUTH"),
        LabelRule("auth", "AUTH"),
        LabelRule("payment", "PAY"),
        LabelRule("checkout", "PAY"),
        LabelRule("billing", "PAY"),
        LabelRule("search", "SRC"),
        LabelRule("notification", "NOT"),
        LabelRule("settings", "SET"),
        LabelRule("analytics", "ANL"),
        LabelRule("database", "DB"),
        LabelRule("infra", "INF"),
    ]
}
