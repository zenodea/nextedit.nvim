use serde::{Deserialize, Serialize};

/// One JSON object per line on stdin.
#[derive(Deserialize)]
pub struct Request {
    pub id: u64,
    pub params: PredictParams,
}

#[derive(Deserialize)]
pub struct PredictParams {
    pub path: String,
    pub filetype: String,
    /// 1-indexed cursor line in the buffer.
    pub cursor_line: usize,
    /// 0-indexed byte column within the cursor line.
    #[serde(default)]
    pub cursor_col: usize,
    /// Absolute 1-indexed line number of `excerpt_lines[0]`.
    pub excerpt_start: usize,
    pub excerpt_lines: Vec<String>,
    /// The user's recent edits, oldest first — possibly from other files.
    pub recent_edits: Vec<RecentEdit>,
    /// Error/warning diagnostics inside the excerpt, pre-formatted one per line.
    #[serde(default)]
    pub diagnostics: Vec<String>,
    /// Numbered definition lines outlining the whole file, pre-formatted.
    #[serde(default)]
    pub outline: Vec<String>,
    /// Extra editable regions elsewhere in the file (candidate sites for the
    /// next edit, found by scanning for identifiers the recent edits removed).
    #[serde(default)]
    pub extra_regions: Vec<Region>,
}

#[derive(Deserialize)]
pub struct Region {
    /// Absolute 1-indexed line number of `lines[0]`.
    pub start: usize,
    pub lines: Vec<String>,
}

#[derive(Deserialize)]
pub struct RecentEdit {
    /// Path of the file the edit happened in (not necessarily the current one).
    pub path: String,
    /// Unified diff of the edit.
    pub diff: String,
}

/// One JSON object per line on stdout.
#[derive(Serialize)]
pub struct Response {
    pub id: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Prediction>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Serialize)]
pub struct Prediction {
    pub has_edit: bool,
    /// Absolute 1-indexed range of lines to replace, inclusive.
    pub start_line: usize,
    pub end_line: usize,
    pub replacement: Vec<String>,
}

impl Prediction {
    pub fn none() -> Self {
        Prediction { has_edit: false, start_line: 0, end_line: 0, replacement: vec![] }
    }
}
